//  AccessControl
//  Failure-only rate limiting, with an administered blocklist.
//
//  The dangerous part of this file is not the counting: it is deciding WHOSE failure it is.
//  Nearly every install sits behind Cloudflare, ngrok, or zrok, so the socket peer address
//  is the tunnel's egress, identical for every client. Counting against it means the first
//  brute-force attempt locks out the entire user base at once. That failure mode is worse
//  than the attack this defends against, so the resolution rules below are the point of the
//  file and the throttling is almost incidental:
//
//    - X-Forwarded-For is honored ONLY when the peer is a configured trusted proxy, and the
//      entry taken is the rightmost untrusted one: the leftmost is attacker-controlled.
//    - The active tunnel address is hard-allowlisted and can never be blocked, whatever the
//      counters say.
//    - When no per-client address can be established, we do NOT block. We fall back to
//      global throttling at a much higher threshold plus per-credential lockout: weaker
//      protection, but never a self-inflicted outage.
//
//  Successful requests are never counted. Some clients poll hard with valid credentials and
//  must never be throttled.
//
//  See `docs/AUTH.md`.

import BBCore
import BBDiagnostics
import Foundation
import Logging

// MARK: - Client identity

public enum ClientIdentity: Sendable, Hashable {
  /// A real client address we are willing to act on.
  case address(String)
  /// No usable per-client address. Blocking is off the table for this request.
  case unresolved
}

public struct ProxyTrustPolicy: Sendable {
  /// Peer addresses whose forwarding headers we believe. Literal addresses or CIDR blocks.
  /// Loopback by default: the bundled tunnels all run on this machine and connect over it.
  public var trustedProxies: Set<String>
  /// Addresses that can never be blocked regardless of failure count. The active tunnel
  /// egress is added here at connect time.
  public var permanentAllowlist: Set<String>
  public var honorForwardedFor: Bool

  public init(
    trustedProxies: Set<String> = ["127.0.0.1", "::1", "localhost"],
    permanentAllowlist: Set<String> = ["127.0.0.1", "::1"],
    honorForwardedFor: Bool = true
  ) {
    self.trustedProxies = trustedProxies
    self.permanentAllowlist = permanentAllowlist
    self.honorForwardedFor = honorForwardedFor
  }

  /// Resolves the address to hold responsible for a request.
  ///
  /// `forwardedFor` is the raw header, `client, proxy1, proxy2` in append order. The
  /// leftmost entry is whatever the client sent and is trivially spoofed, so we walk from
  /// the RIGHT and take the first entry that is not itself a trusted proxy. That is the
  /// nearest address we have any reason to believe.
  public func resolve(peerAddress: String?, forwardedFor: String?) -> ClientIdentity {
    guard let peerAddress, !peerAddress.isEmpty else { return .unresolved }

    let peer = Self.normalize(peerAddress)

    guard honorForwardedFor, isTrustedProxy(peer) else {
      // Direct connection, or a proxy we do not trust. Either way the peer is the
      // client as far as we are concerned.
      return .address(peer)
    }

    guard let forwardedFor, !forwardedFor.isEmpty else {
      // A trusted proxy that forwarded no header. We cannot attribute this to anyone,
      // and blaming the proxy is exactly the outage described above.
      return .unresolved
    }

    let hops =
      forwardedFor
      .split(separator: ",")
      .map { Self.normalize(String($0).trimmingCharacters(in: .whitespaces)) }
      .filter { !$0.isEmpty }

    for hop in hops.reversed() where !isTrustedProxy(hop) {
      return .address(hop)
    }

    // Every hop was a trusted proxy. No client to attribute to.
    return .unresolved
  }

  /// Whether an address is one of the configured proxies.
  ///
  /// Matched through CIDR rather than by set membership, so `10.0.0.0/8` covers a whole
  /// internal network. A reverse proxy behind a load balancer does not have one stable
  /// address, and requiring every possible one to be enumerated is how this setting gets
  /// misconfigured into uselessness.
  public func isTrustedProxy(_ address: String) -> Bool {
    let normalized = Self.normalize(address)
    if trustedProxies.contains(normalized) { return true }
    return trustedProxies.contains {
      $0.contains("/") && CIDR.matches(address: normalized, pattern: $0)
    }
  }

  /// Strips an IPv6 zone, unwraps brackets, and drops an IPv4-mapped IPv6 prefix, so
  /// `::ffff:1.2.3.4` and `1.2.3.4` are the same client rather than two.
  static func normalize(_ address: String) -> String {
    var value = address
    if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
      value = String(value[value.index(after: value.startIndex)..<close])
    }
    if let percent = value.firstIndex(of: "%") {
      value = String(value[value.startIndex..<percent])
    }
    if value.lowercased().hasPrefix("::ffff:") {
      let tail = String(value.dropFirst(7))
      if tail.contains(".") { value = tail }
    }
    return value.lowercased()
  }
}

// MARK: - Policy

public struct AccessControlPolicy: Sendable {
  /// Failures from one address before it is blocked. Generous: a client retrying a stale
  /// password after a change must recover the moment it is corrected, not be locked out.
  public var perClientThreshold: Int
  /// Failures across all unresolved clients before global throttling engages. Much higher,
  /// because it is shared by everyone behind an unattributable proxy.
  public var globalThreshold: Int
  /// Window over which failures accumulate.
  public var window: Duration
  /// First block duration. Repeat offences multiply it.
  public var baseLockout: Duration
  public var maximumLockout: Duration
  public var isEnabled: Bool
  /// Bounded history for the "recent failures" admin view. Bounded because an attacker
  /// controls how fast rows arrive.
  public var failureHistoryLimit: Int
  /// Upper bound on remembered addresses, per map.
  ///
  /// Every map keyed by client address is grown by whoever is attacking, and an IPv6
  /// attacker has an effectively unlimited supply of them, so each one needs a ceiling and
  /// not just a TTL. On the policy rather than a constant so a test can reach the ceiling
  /// without driving ten thousand addresses through the actor, which took fifteen seconds.
  public var addressMemoryLimit: Int

  public init(
    perClientThreshold: Int = 10,
    globalThreshold: Int = 200,
    window: Duration = .seconds(300),
    baseLockout: Duration = .seconds(900),
    maximumLockout: Duration = .seconds(86_400),
    isEnabled: Bool = true,
    failureHistoryLimit: Int = 500,
    addressMemoryLimit: Int = 10_000
  ) {
    self.perClientThreshold = perClientThreshold
    self.globalThreshold = globalThreshold
    self.window = window
    self.baseLockout = baseLockout
    self.maximumLockout = maximumLockout
    self.isEnabled = isEnabled
    self.failureHistoryLimit = failureHistoryLimit
    self.addressMemoryLimit = addressMemoryLimit
  }
}

// MARK: - Records

public struct BlockedClient: Sendable, Identifiable, Codable {
  public let id: UUID
  public let address: String
  public let reason: String
  public var failureCount: Int
  public let firstSeen: Date
  public var lastSeen: Date
  public var blockedAt: Date
  /// nil means permanent, which only an admin can set. Automatic blocks always expire, so
  /// the common false-positive case self-heals even if nobody looks at the Security page.
  public var expiresAt: Date?
  /// How many times this address has been blocked before. Drives lockout escalation.
  public var offenceCount: Int

  public var isPermanent: Bool { expiresAt == nil }

  public func isActive(at now: Date) -> Bool {
    guard let expiresAt else { return true }
    return expiresAt > now
  }
}

public struct AllowedClient: Sendable, Identifiable, Codable {
  public let id: UUID
  /// A literal address or a CIDR block.
  public let cidr: String
  public let note: String?
  public let createdAt: Date

  public init(id: UUID = UUID(), cidr: String, note: String? = nil, createdAt: Date) {
    self.id = id
    self.cidr = cidr
    self.note = note
    self.createdAt = createdAt
  }
}

public struct AuthFailureRecord: Sendable, Identifiable, Codable {
  public let id: UUID
  public let address: String?
  public let at: Date
  public let path: String
  public let reason: String
}

public enum AccessDecision: Sendable, Equatable {
  case allow
  /// Blocked until `until`. The caller returns 401 rather than 403: a 403 tells an
  /// attacker their guessing is being counted, and it is a status existing clients do not
  /// expect from the auth path.
  case blocked(until: Date?)
  /// Global throttling engaged because no client address could be resolved.
  case throttled
}

// MARK: - Persistence

/// Durable storage for the administered half of access control.
///
/// A protocol rather than a direct dependency so BBAuth does not have to know about GRDB:
/// the implementation lives with the rest of the app's storage. Both halves matter and for
/// different reasons: an allowlist an administrator curated must survive a restart or it is
/// worse than useless, and a blocklist that does not survive makes "restart the server" an
/// accidental unblock-everyone button.
public protocol AccessControlPersistence: Sendable {
  func loadAccessControl() async throws -> (blocked: [BlockedClient], allowlist: [AllowedClient])
  func saveBlocked(_ blocked: [BlockedClient]) async throws
  func saveAllowlist(_ allowlist: [AllowedClient]) async throws
}

// MARK: - The service

/// The administered state as one value: who is blocked, who is exempt, and who is failing
/// without yet being either. Read together because they describe one subject from three
/// angles, and read as one so a page cannot show a fresh list beside a stale one.
public struct AccessControlSnapshot: Sendable {
  public let blocked: [BlockedClient]
  public let allowed: [AllowedClient]
  public let failures: [AuthFailureRecord]

  public init(blocked: [BlockedClient], allowed: [AllowedClient], failures: [AuthFailureRecord]) {
    self.blocked = blocked
    self.allowed = allowed
    self.failures = failures
  }
}

public actor AccessControlService {

  private var policy: AccessControlPolicy
  private let clock: any BBClock
  private let alerts: (any AlertRaising)?
  private let persistence: (any AccessControlPersistence)?
  private let logger = Logger(label: "bluebubbles.access-control")

  private var blocked: [String: BlockedClient] = [:]
  private var allowlist: [AllowedClient] = []
  private var trust: ProxyTrustPolicy
  private var recentFailures: [AuthFailureRecord] = []

  /// Sliding failure timestamps per address, and one bucket for unresolved clients.
  private var failureTimes: [String: [Date]] = [:]
  private var unresolvedFailureTimes: [Date] = []

  /// Survives a block expiring, so a repeat offender escalates rather than restarting at
  /// the base lockout each time.
  private var offenceHistory: [String: Int] = [:]

  /// The address `setActiveTunnelAddress` last granted, so the grant can be WITHDRAWN when
  /// the tunnel moves. Without it each new tunnel egress adds a permanently trusted
  /// address that is never removed, and a stale one keeps both its unblockable status and
  /// (worse) its authority to set `X-Forwarded-For`, which is the header the whole
  /// client-attribution model rests on.
  private var tunnelGrant: String?

  /// Whoever is following the administered state; see `changes()`.
  private var observers: [UUID: AsyncStream<AccessControlSnapshot>.Continuation] = [:]
  /// Wakes at the earliest automatic expiry so a follower sees the block leave. Only ever
  /// scheduled while someone is following; nothing else needs the wake-up.
  private var expiryTask: Task<Void, Never>?

  /// The persistence lane: what still needs writing, and the one task doing the writing.
  ///
  /// FLAGS, not snapshots. Each write rewrites its whole table, so what a write should
  /// contain is "the state as it is when the write runs" — and taking it then, inside the
  /// actor, is what makes a stale snapshot unrepresentable rather than merely unlikely.
  private var blockedNeedsWrite = false
  private var allowlistNeedsWrite = false
  private var writer: Task<Void, Never>?

  public init(
    policy: AccessControlPolicy = AccessControlPolicy(),
    trust: ProxyTrustPolicy = ProxyTrustPolicy(),
    clock: any BBClock = SystemClock(),
    alerts: (any AlertRaising)? = nil,
    persistence: (any AccessControlPersistence)? = nil
  ) {
    self.policy = policy
    self.trust = trust
    self.clock = clock
    self.alerts = alerts
    self.persistence = persistence
  }

  /// Reads the durable state back in. Called once, at startup, before anything is served.
  public func loadPersistedState() async {
    guard let persistence else { return }
    do {
      let state = try await persistence.loadAccessControl()
      restore(blocked: state.blocked, allowlist: state.allowlist)
    } catch {
      // Not fatal, and deliberately so: a server that refuses to start because it
      // could not read its blocklist has turned a minor problem into an outage.
      logger.warning(
        "Could not restore access control state",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  /// Marks state as needing a write, and makes sure something is writing.
  ///
  /// Fire-and-forget from the caller's side: a failed write must never fail the request that
  /// triggered it. What it is NOT any more is unordered.
  ///
  /// **Two rapid changes used to race, and the older one could land last.** Each call
  /// snapshotted the state and started its own detached `Task`, so a block and the unblock
  /// that followed it produced two independent writes with nothing sequencing them. To a
  /// user that is "I unblocked that address, and after a restart it was blocked again":
  /// security state reverting on its own, which is the worst kind to get wrong.
  ///
  /// There is ONE writer now, and it re-reads the live state each pass, so the last write
  /// always carries the newest state. That also coalesces: ten blocks in a burst are one or
  /// two table rewrites rather than ten, which matters because each one is a
  /// `DELETE`-then-`INSERT` over the whole table.
  private func persist(blocked persistBlocked: Bool = false, allowlist persistAllow: Bool = false) {
    guard persistence != nil else { return }
    blockedNeedsWrite = blockedNeedsWrite || persistBlocked
    allowlistNeedsWrite = allowlistNeedsWrite || persistAllow
    guard writer == nil else { return }
    writer = Task { [weak self] in await self?.drainWrites() }
  }

  /// Writes whatever is outstanding, one pass at a time, until nothing is.
  ///
  /// Re-entrancy is the point rather than a hazard: the `await` on the store lets another
  /// request run and set the flags again, and the loop picks that up on its next pass with
  /// the state as it then is. The flags are cleared BEFORE the write so a change arriving
  /// during one is not mistaken for having been included in it.
  private func drainWrites() async {
    guard let persistence else { return }
    defer { writer = nil }
    while blockedNeedsWrite || allowlistNeedsWrite {
      let writeBlocked = blockedNeedsWrite
      let writeAllowlist = allowlistNeedsWrite
      blockedNeedsWrite = false
      allowlistNeedsWrite = false
      // Read here, inside the actor, immediately before the write.
      let blockedNow = Array(blocked.values)
      let allowlistNow = allowlist
      do {
        if writeBlocked { try await persistence.saveBlocked(blockedNow) }
        if writeAllowlist { try await persistence.saveAllowlist(allowlistNow) }
      } catch {
        // Logged and dropped, as before. The next change rewrites the whole table anyway,
        // so a failed write costs durability until the next one rather than consistency.
        logger.warning(
          "Could not persist access control state",
          metadata: [
            "error": .string(String(describing: error))
          ])
      }
    }
  }

  /// Waits until nothing is queued to be written.
  ///
  /// For tests, and for any caller that needs the durable state to be current before it
  /// looks at it. Loops rather than awaiting once: a write can enqueue another while it is
  /// running, and "settled" means no writer at all.
  public func flushPersistedState() async {
    // `drainWrites` clears `writer` on its way out, so the loop ends when the last one
    // does; a write that enqueued another is awaited on the next turn.
    while let writer { await writer.value }
  }

  // MARK: Configuration

  public func update(policy: AccessControlPolicy) {
    self.policy = policy
  }

  /// Replaces the trust rules, preserving the live tunnel grant.
  ///
  /// The grant is re-applied rather than carried over wholesale: an operator editing
  /// `trusted_proxies` must not silently revoke the running tunnel's privilege, and must
  /// not inherit a stale one either.
  public func update(trust newTrust: ProxyTrustPolicy) {
    let grant = tunnelGrant
    trust = newTrust
    tunnelGrant = nil
    if let grant { setActiveTunnelAddress(grant) }
  }

  /// Privileges a tunnel's EGRESS address: the address its traffic arrives FROM.
  ///
  /// **Nothing in the server calls this today, and the header note that used to call it
  /// "the guard that makes the whole feature safe to ship" was wrong.** What actually keeps
  /// a shared tunnel from being locked out is the default trust policy: every bundled
  /// connection method runs as a child process on this Mac and reaches the listener over
  /// loopback, and `127.0.0.1` is both permanently allowlisted and a trusted proxy by
  /// default, so the forwarding header is believed and failures land on the real client
  /// behind it rather than on the tunnel. `SocketAccessControlTests.tunnelIsNotBlocked`
  /// pins that end to end.
  ///
  /// It is kept, rather than wired or deleted, and the reason is worth stating because the
  /// obvious wiring is a trap. The proxy coordinator's `onAddressChanged` carries the
  /// PUBLIC URL clients connect TO (`https://…trycloudflare.com`, `http://192.168.50.112:1234`),
  /// and this set is compared against a peer address by `isAlwaysAllowed`. Passing one to
  /// the other inserts a URL into a set of IPs: it matches nothing, so the grant stays dead
  /// while looking connected, which is worse than leaving it visibly unused.
  ///
  /// The deployment it is for is a REMOTE reverse proxy in front of this server, where a
  /// single egress IP genuinely exists and must never be blocked. This server has no
  /// connection method with that shape; an operator in it configures `trusted_proxies`,
  /// which is the documented mechanism and reaches the same two sets through
  /// `update(trust:)`. Wire this the day a connection method learns a real egress address.
  public func setActiveTunnelAddress(_ address: String?) {
    let normalized = address.map(ProxyTrustPolicy.normalize)
    guard normalized != tunnelGrant else { return }

    // Withdraw the previous grant first. A tunnel address is only privileged for as long
    // as it IS the tunnel; leaving the last one in place accumulates trusted addresses
    // across every reconnect and every provider switch.
    if let previous = tunnelGrant {
      trust.permanentAllowlist.remove(previous)
      trust.trustedProxies.remove(previous)
    }
    tunnelGrant = nil

    guard let normalized, !normalized.isEmpty else { return }
    trust.permanentAllowlist.insert(normalized)
    trust.trustedProxies.insert(normalized)
    blocked.removeValue(forKey: normalized)
    tunnelGrant = normalized
  }

  /// The address currently privileged as the tunnel egress, if any.
  public var activeTunnelAddress: String? { tunnelGrant }

  /// The private ranges the "trust my local network" switch manages.
  ///
  /// **This is that switch's IDENTITY, and the note is only its label.** The Security page
  /// used to decide whether the switch was on by comparing each allowlist entry's `note`
  /// against its own copy of the words "Local network": a display string, written here and
  /// matched there, across a module boundary with nothing keeping the two in step. Rewording
  /// either side made the switch read OFF for a rule that was on, and flipping it then
  /// appended a second copy of every range. The project's rule is that identity is never a
  /// display string; this is the shared value that makes it true here.
  public static let localNetworkRanges: Set<String> = [
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
  ]

  /// What a person reads beside those ranges. A label, free to change.
  public static let localNetworkNote = "Local network"

  /// Whether an allowlist entry is one of the local-network ranges.
  ///
  /// Exposed so the UI asks rather than re-deriving it: a second implementation of this
  /// predicate is how the two came apart in the first place.
  public static func isLocalNetworkRange(_ cidr: String) -> Bool {
    localNetworkRanges.contains(cidr)
  }

  public func trustLocalNetwork(_ enabled: Bool) {
    // Private ranges are not trusted by default: a LAN is not automatically friendly.
    // But a LAN-only user gains little from blocking and loses a lot to a false
    // positive, so this is one toggle away.
    let ranges = Self.localNetworkRanges
    if enabled {
      let existing = Set(allowlist.map(\.cidr))
      for range in ranges where !existing.contains(range) {
        allowlist.append(
          AllowedClient(cidr: range, note: Self.localNetworkNote, createdAt: clock.now)
        )
      }
    } else {
      allowlist.removeAll { ranges.contains($0.cidr) }
    }
    persist(allowlist: true)
    publish()
  }

  public func restore(blocked: [BlockedClient], allowlist: [AllowedClient]) {
    for entry in blocked {
      self.blocked[entry.address] = entry
      offenceHistory[entry.address] = entry.offenceCount
    }
    self.allowlist = allowlist
    publish()
  }

  // MARK: Evaluation

  public func identity(peerAddress: String?, forwardedFor: String?) -> ClientIdentity {
    trust.resolve(peerAddress: peerAddress, forwardedFor: forwardedFor)
  }

  /// Called before authentication runs.
  ///
  /// `isEnabled` governs the AUTOMATIC half: counting failures, blocking on a threshold,
  /// and global throttling. It deliberately does not lift a block an administrator set by
  /// hand: turning off automatic rate limiting says "stop deciding this for me", not
  /// "unblock the address I explicitly blocked". Those two are silently the same switch
  /// otherwise, and the abusive client an operator banned comes straight back.
  public func evaluate(_ identity: ClientIdentity) -> AccessDecision {
    switch identity {
    case .unresolved:
      guard policy.isEnabled else { return .allow }
      prune()
      return unresolvedFailureTimes.count >= policy.globalThreshold ? .throttled : .allow

    case .address(let address):
      if isAlwaysAllowed(address) { return .allow }
      guard let entry = blocked[address] else { return .allow }
      guard entry.isActive(at: clock.now) else {
        blocked.removeValue(forKey: address)
        return .allow
      }
      // Automatic blocks expire and are the ones the toggle governs; a permanent block
      // is an administrator's standing decision and outlives it.
      guard policy.isEnabled || entry.isPermanent else { return .allow }
      return .blocked(until: entry.expiresAt)
    }
  }

  /// Called on an authentication failure that is genuinely the client's fault. A server
  /// misconfiguration must not reach here; see `AuthenticationFailure.countsAsAttempt`.
  @discardableResult
  public func recordFailure(
    _ identity: ClientIdentity,
    path: String,
    reason: String
  ) async -> AccessDecision {
    guard policy.isEnabled else { return .allow }
    let now = clock.now
    prune()
    // Every branch below appends to the history a follower shows, and one of them blocks.
    defer { publish() }

    switch identity {
    case .unresolved:
      unresolvedFailureTimes.append(now)
      appendHistory(address: nil, path: path, reason: reason, at: now)
      // Deliberately no block. There is nobody to block but the proxy.
      guard unresolvedFailureTimes.count >= policy.globalThreshold else { return .allow }
      await raiseThrottleAlert(failureCount: unresolvedFailureTimes.count)
      return .throttled

    case .address(let address):
      appendHistory(address: address, path: path, reason: reason, at: now)
      guard !isAlwaysAllowed(address) else { return .allow }

      failureTimes[address, default: []].append(now)
      let count = failureTimes[address]?.count ?? 0
      guard count >= policy.perClientThreshold else { return .allow }

      return await block(address: address, reason: reason, failureCount: count, at: now)
    }
  }

  /// Clears a client's counter. Called on success so an intermittently-wrong client that
  /// gets it right does not creep toward a block over hours.
  public func recordSuccess(_ identity: ClientIdentity) {
    guard case .address(let address) = identity else { return }
    failureTimes.removeValue(forKey: address)
  }

  /// Announced once per window, not once per request.
  ///
  /// Throttling means the server is under sustained attack from behind a proxy that gives
  /// us no way to tell clients apart, so there is no address to name and nothing to
  /// unblock, but the operator still needs to know it is happening. Deduped on a fixed key
  /// so an attack cannot turn the notification drawer into its own denial of service.
  private func raiseThrottleAlert(failureCount: Int) async {
    logger.warning(
      "Throttling failed logins from an unidentified source",
      metadata: ["failures": .stringConvertible(failureCount)])
    guard let alerts else { return }
    await alerts.raise(
      UserAlert(
        severity: .warning,
        title: "Throttling failed logins from an unidentified source",
        body: "\(failureCount) failed login attempts arrived through a proxy that "
          + "does not identify its clients, so none of them can be blocked "
          + "individually. If you run your own reverse proxy, add it under "
          + "Trusted Reverse Proxies so attempts can be attributed.",
        source: "access-control",
        diagnostics: Diagnostics(
          code: "access_control.throttled",
          domain: "AccessControl",
          context: ["failure_count": .int(failureCount)]
        ),
        actions: [.openSettings(.security)],
        dedupeKey: "access_control.throttled"
      )
    )
  }

  private func block(
    address: String,
    reason: String,
    failureCount: Int,
    at now: Date
  ) async -> AccessDecision {
    let offences = (offenceHistory[address] ?? 0) + 1
    offenceHistory[address] = offences

    // Doubling per offence, capped. Never permanent automatically.
    let multiplier = Double(1 << min(offences - 1, 10))
    let seconds = min(policy.baseLockout.seconds * multiplier, policy.maximumLockout.seconds)
    let expiry = now.addingTimeInterval(seconds)

    let existing = blocked[address]
    blocked[address] = BlockedClient(
      id: existing?.id ?? UUID(),
      address: address,
      reason: reason,
      failureCount: failureCount,
      firstSeen: existing?.firstSeen ?? now,
      lastSeen: now,
      blockedAt: now,
      expiresAt: expiry,
      offenceCount: offences
    )
    failureTimes.removeValue(forKey: address)
    // Enforced HERE as well as in `prune()`, because prune runs at the top of
    // `recordFailure` and this insert happens after it: without this the set settles one
    // above the ceiling forever, which is a small lie in exactly the place that justifies a
    // full-table rewrite on the set being bounded.
    capBlocked()
    persist(blocked: true)

    // What the alert says, for the log. The client is an IP and is named: it is what the
    // person unblocks.
    logger.warning(
      "Blocked a client after repeated failed logins",
      metadata: [
        "client": .string(address),
        "failures": .stringConvertible(failureCount),
        "offences": .stringConvertible(offences),
        "until": .string(Self.formatter.string(from: expiry)),
      ])

    // The alert carries the remedy: an .unblock action, so a false positive is one click
    // in the notification rather than a hunt through Settings.
    await alerts?.raise(
      UserAlert(
        severity: .warning,
        title: "Blocked a client after repeated failed logins",
        body: "\(address) failed to authenticate \(failureCount) times and is blocked "
          + "until \(Self.formatter.string(from: expiry)). If this is you, unblock it.",
        source: "access-control",
        diagnostics: Diagnostics(
          code: "access_control.blocked",
          domain: "AccessControl",
          context: [
            "address": .string(address),
            "failure_count": .int(failureCount),
            "offence_count": .int(offences),
          ]
        ),
        actions: [.unblock(address: address), .openSettings(.security)],
        dedupeKey: "access_control.blocked.\(address)"
      )
    )

    return .blocked(until: expiry)
  }

  // MARK: Observation

  /// The three lists as one value, as the Security page shows them.
  public func snapshot() -> AccessControlSnapshot {
    AccessControlSnapshot(
      blocked: blockedClients(), allowed: allowedClients(), failures: failures()
    )
  }

  /// Every change to the administered state, for a page that shows it.
  ///
  /// Yields on a block, an unblock, an allowlist edit, a recorded failure, and (the case
  /// nothing else covers) an automatic block EXPIRING. Expiry is a moment on the clock and
  /// not a call, so while anyone is following, a task sleeps until the earliest one and
  /// prunes; without this a page showed "expires in 4 minutes" until something else
  /// happened to touch the service, and offered Unblock on an entry that was already gone.
  /// Same shape as `ToolManager.stream()`.
  public func changes() -> AsyncStream<AccessControlSnapshot> {
    let id = UUID()
    let stream = AsyncStream<AccessControlSnapshot> { continuation in
      observers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeObserver(id) }
      }
    }
    scheduleExpiry()
    return stream
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
    if observers.isEmpty {
      expiryTask?.cancel()
      expiryTask = nil
    }
  }

  private func publish() {
    guard !observers.isEmpty else { return }
    let snapshot = snapshot()
    for continuation in observers.values { continuation.yield(snapshot) }
    scheduleExpiry()
  }

  /// Sleeps until the earliest automatic block lapses, then drops it and tells followers.
  ///
  /// Re-armed on every publish, because every publish may have changed which block is
  /// earliest. Measured against `clock.now` rather than the wall clock, so a test's manual
  /// clock and the real one agree on how long "until it expires" is.
  private func scheduleExpiry() {
    expiryTask?.cancel()
    expiryTask = nil
    guard !observers.isEmpty else { return }
    let now = clock.now
    guard let earliest = blocked.values.compactMap(\.expiresAt).filter({ $0 > now }).min()
    else { return }
    // A hair after, so `isActive` is false when the prune runs rather than equal.
    let delay = earliest.timeIntervalSince(now) + 0.05
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.expire()
    }
  }

  private func expire() {
    prune()
    publish()
  }

  // MARK: Administration

  public func blockedClients() -> [BlockedClient] {
    let now = clock.now
    return blocked.values.filter { $0.isActive(at: now) }.sorted { $0.blockedAt > $1.blockedAt }
  }

  public func allowedClients() -> [AllowedClient] { allowlist }

  public func failures(limit: Int = 100) -> [AuthFailureRecord] {
    Array(recentFailures.suffix(limit).reversed())
  }

  public func unblock(address: String) {
    let normalized = ProxyTrustPolicy.normalize(address)
    if blocked.removeValue(forKey: normalized) != nil {
      logger.info("Unblocked a client", metadata: ["client": .string(normalized)])
    }
    failureTimes.removeValue(forKey: normalized)
    persist(blocked: true)
    // The offence count is cleared too: an admin unblocking is saying this was a false
    // positive, so the next block should start from the base lockout rather than
    // escalating on top of a mistake.
    offenceHistory.removeValue(forKey: normalized)
    publish()
  }

  public func unblock(id: UUID) {
    guard let entry = blocked.values.first(where: { $0.id == id }) else { return }
    unblock(address: entry.address)
  }

  public func clearAllBlocks() {
    logger.info(
      "Cleared every block", metadata: ["blocked": .stringConvertible(blocked.count)])
    blocked.removeAll()
    failureTimes.removeAll()
    unresolvedFailureTimes.removeAll()
    offenceHistory.removeAll()
    persist(blocked: true)
    publish()
  }

  /// Adds an address or CIDR block to the allowlist, or refuses a pattern that can never
  /// match.
  ///
  /// **The validation is HERE, not at the call sites, and that is the fix.** `isValidPattern`
  /// was written for this and then called from exactly one of the two callers: the Security
  /// page checked, and `POST /api/v1/server/security/allow` did not, so a mistyped range sent
  /// over the API was appended, echoed back with a 201-looking body, and listed on the
  /// Security page looking active while `matches` never matched it. That is the precise bug
  /// `isValidPattern`'s own header says it exists to prevent, re-entering through the door
  /// nobody guarded. A rule enforced at one of two call sites is not enforced.
  ///
  /// - Returns: The stored entry, or nil when `cidr` is not an address or a CIDR block. Nil
  ///   rather than a throw because BBAuth has no error vocabulary the HTTP layer maps, and a
  ///   refusal the caller MUST unwrap is what the silent append lacked; the handler turns it
  ///   into a 400 and the page into the message beside the field.
  @discardableResult
  public func allow(cidr: String, note: String? = nil) -> AllowedClient? {
    let entry = cidr.trimmingCharacters(in: .whitespaces)
    guard CIDR.isValidPattern(entry) else {
      logger.warning(
        "Refused an allowlist entry that could never match",
        metadata: ["client": .string(entry)])
      return nil
    }
    let stored = AllowedClient(cidr: entry, note: note, createdAt: clock.now)
    allowlist.append(stored)
    logger.info("Allowlisted a client", metadata: ["client": .string(entry)])
    // Allowlisting implies unblocking, which is what "Unblock and allowlist" needs.
    if !entry.contains("/") { unblock(address: entry) }
    persist(allowlist: true)
    publish()
    return stored
  }

  public func disallow(id: UUID) {
    if let entry = allowlist.first(where: { $0.id == id }) {
      logger.info("Removed a client from the allowlist", metadata: ["client": .string(entry.cidr)])
    }
    allowlist.removeAll { $0.id == id }
    persist(allowlist: true)
    publish()
  }

  public func blockPermanently(address: String, reason: String) {
    let normalized = ProxyTrustPolicy.normalize(address)
    guard !isAlwaysAllowed(normalized) else { return }
    logger.info(
      "Blocked a client permanently",
      metadata: ["client": .string(normalized), "reason": .string(reason)])
    let now = clock.now
    let existing = blocked[normalized]
    blocked[normalized] = BlockedClient(
      id: existing?.id ?? UUID(),
      address: normalized,
      reason: reason,
      failureCount: existing?.failureCount ?? 0,
      firstSeen: existing?.firstSeen ?? now,
      lastSeen: now,
      blockedAt: now,
      expiresAt: nil,
      offenceCount: existing?.offenceCount ?? 1
    )
    persist(blocked: true)
    publish()
  }

  // MARK: Internals

  private func isAlwaysAllowed(_ address: String) -> Bool {
    if trust.permanentAllowlist.contains(address) { return true }
    return allowlist.contains { CIDR.matches(address: address, pattern: $0.cidr) }
  }

  private func prune() {
    let now = clock.now
    let cutoff = now.addingTimeInterval(-policy.window.seconds)
    for (address, times) in failureTimes {
      let kept = times.filter { $0 > cutoff }
      if kept.isEmpty {
        failureTimes.removeValue(forKey: address)
      } else {
        failureTimes[address] = kept
      }
    }
    unresolvedFailureTimes = unresolvedFailureTimes.filter { $0 > cutoff }

    // Expired automatic blocks were only ever dropped when that exact address was seen
    // again, so an attacker rotating addresses left one dead entry behind per attempt.
    for (address, entry) in blocked where !entry.isActive(at: now) {
      blocked.removeValue(forKey: address)
    }

    // `failureTimes` and `blocked` are capped too, and the ceiling above is why.
    //
    // The comment on `addressMemoryLimit` says every map keyed by client address needs one.
    // It was applied to `offenceHistory` alone: `failureTimes` was pruned only by TTL and
    // `blocked` only by expiry, so an attacker with a supply of IPv6 addresses grew both
    // without limit inside one window. Driving ten thousand distinct addresses through
    // `recordFailure` produced a blocked set ABOVE this limit, which is also what
    // `AccessControlStore.saveBlocked` justifies its full-table rewrite on the assumption
    // of being small.
    //
    // Evicting a block is a real loss, so the order matters: temporary before permanent,
    // oldest before newest, and a permanent block is never evicted at all. An attacker who
    // can push ten thousand addresses through the window can already force whatever they
    // like out of a bounded cache; what they must not be able to do is exhaust memory or
    // drop a manual ban.
    if failureTimes.count > policy.addressMemoryLimit {
      let excess = failureTimes.count - policy.addressMemoryLimit
      let oldestFirst =
        failureTimes
        .filter { blocked[$0.key] == nil }
        .sorted { ($0.value.max() ?? .distantPast) < ($1.value.max() ?? .distantPast) }
      for (address, _) in oldestFirst.prefix(excess) {
        failureTimes.removeValue(forKey: address)
      }
    }

    capBlocked()

    // The escalation history has no natural expiry (that is the point of it) so it is
    // capped instead. Oldest-blocked first, and never an address that is still blocked:
    // forgetting one of those would reset a live offender to the base lockout.
    if offenceHistory.count > policy.addressMemoryLimit {
      let evictable = offenceHistory.keys.filter { blocked[$0] == nil }
      let excess = offenceHistory.count - policy.addressMemoryLimit
      for address in evictable.prefix(excess) {
        offenceHistory.removeValue(forKey: address)
      }
    }
  }

  /// Holds `blocked` at the ceiling, evicting temporary blocks oldest-first.
  ///
  /// A permanent block is never evicted: it is a decision somebody made by hand, and an
  /// attacker who can push ten thousand addresses through the window must not be able to
  /// flush one out by making noise. If every remaining block is permanent the ceiling is
  /// reported rather than silently broken.
  private func capBlocked() {
    guard blocked.count > policy.addressMemoryLimit else { return }
    let evictable = blocked.filter { !$0.value.isPermanent }
      .sorted { $0.value.blockedAt < $1.value.blockedAt }
    for (address, _) in evictable.prefix(blocked.count - policy.addressMemoryLimit) {
      blocked.removeValue(forKey: address)
    }
    if blocked.count > policy.addressMemoryLimit {
      logger.warning(
        "More permanent blocks than the address memory limit; none were evicted",
        metadata: [
          "blocked": .stringConvertible(blocked.count),
          "limit": .stringConvertible(policy.addressMemoryLimit),
        ])
    }
  }

  private func appendHistory(address: String?, path: String, reason: String, at now: Date) {
    recentFailures.append(
      AuthFailureRecord(id: UUID(), address: address, at: now, path: path, reason: reason)
    )
    if recentFailures.count > policy.failureHistoryLimit {
      recentFailures.removeFirst(recentFailures.count - policy.failureHistoryLimit)
    }
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()
}

// MARK: - CIDR

/// Just enough CIDR to evaluate the allowlist. Deliberately not a general address library:
/// it parses IPv4 and IPv6 into their bit patterns and compares a prefix.
public enum CIDR {

  /// Whether this is a pattern `matches` could ever match.
  ///
  /// The Security page took whatever was typed, appended it to the allowlist and discarded
  /// the result, so a mistyped entry (`192.168.1.o/24`) appeared in the list looking active
  /// and protected nobody: `matches` simply never matched it, and the field was cleared as
  /// though it had worked. An allowlist entry that silently does nothing is worse than a
  /// refused one, because the person believes they are covered.
  ///
  /// Deliberately the SAME parse `matches` uses, so the two cannot disagree: anything this
  /// accepts, that will evaluate.
  public static func isValidPattern(_ pattern: String) -> Bool {
    let trimmed = pattern.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.contains("/") else {
      return bits(of: ProxyTrustPolicy.normalize(trimmed)) != nil
    }
    let parts = trimmed.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let prefixLength = Int(parts[1]),
      let networkBits = bits(of: ProxyTrustPolicy.normalize(String(parts[0]))),
      prefixLength >= 0, prefixLength <= networkBits.count * 8
    else { return false }
    return true
  }

  static func matches(address: String, pattern: String) -> Bool {
    let address = ProxyTrustPolicy.normalize(address)
    guard pattern.contains("/") else {
      return ProxyTrustPolicy.normalize(pattern) == address
    }

    let parts = pattern.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let prefixLength = Int(parts[1]) else { return false }
    let network = ProxyTrustPolicy.normalize(String(parts[0]))

    guard let addressBits = bits(of: address),
      let networkBits = bits(of: network),
      addressBits.count == networkBits.count,
      prefixLength >= 0, prefixLength <= addressBits.count * 8
    else { return false }

    var remaining = prefixLength
    for index in 0..<addressBits.count {
      if remaining >= 8 {
        if addressBits[index] != networkBits[index] { return false }
        remaining -= 8
      } else if remaining > 0 {
        let mask = UInt8(0xFF) << UInt8(8 - remaining)
        if (addressBits[index] & mask) != (networkBits[index] & mask) { return false }
        remaining = 0
      } else {
        break
      }
    }
    return true
  }

  static func bits(of address: String) -> [UInt8]? {
    if address.contains(".") && !address.contains(":") {
      // The COUNT is checked before the parse, and the parse fails the whole address rather
      // than dropping what it cannot read.
      //
      // `split(…).compactMap { UInt8($0) }` discarded an unparseable octet and then counted
      // what survived, so `10.0.0.x.0` came out as the four valid pieces — a well-formed
      // `10.0.0.0`, a DIFFERENT network from anything the operator typed. `isValidPattern`
      // shares this parse, which is what made it worse than a near miss: the Security page
      // accepted the typo and reported it valid, for a range nobody asked for.
      let parts = address.split(separator: ".")
      guard parts.count == 4 else { return nil }
      let octets = parts.compactMap { UInt8($0) }
      return octets.count == 4 ? octets : nil
    }
    guard address.contains(":") else { return nil }

    // Expand the `::` run, then parse 8 groups of 16 bits.
    let hasElision = address.contains("::")
    let sides = address.components(separatedBy: "::")
    guard sides.count <= 2 else { return nil }

    func groups(_ text: String) -> [UInt16]? {
      guard !text.isEmpty else { return [] }
      var result: [UInt16] = []
      for piece in text.split(separator: ":") {
        guard let value = UInt16(piece, radix: 16) else { return nil }
        result.append(value)
      }
      return result
    }

    guard let head = groups(sides[0]) else { return nil }
    let tail = sides.count == 2 ? groups(sides[1]) : []
    guard let tail else { return nil }

    var all: [UInt16]
    if hasElision {
      let fill = 8 - head.count - tail.count
      guard fill >= 0 else { return nil }
      all = head + Array(repeating: 0, count: fill) + tail
    } else {
      all = head
    }
    guard all.count == 8 else { return nil }

    return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
  }
}

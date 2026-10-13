//  AccessControl
//  Failure-only rate limiting, with an administered blocklist.
//
//  The dangerous part of access control is not the counting: it is deciding WHOSE failure it
//  is. Nearly every install sits behind Cloudflare, ngrok, or zrok, so the socket peer address
//  is the tunnel's egress, identical for every client. Counting against it means the first
//  brute-force attempt locks out the entire user base at once. That failure mode is worse
//  than the attack this defends against, so the resolution rules are the point and the
//  throttling is almost incidental:
//
//    - X-Forwarded-For is honored ONLY when the peer is a configured trusted proxy, and the
//      entry taken is the rightmost untrusted one: the leftmost is attacker-controlled. The
//      rules are `ProxyTrustPolicy`, in `ClientAddress.swift`.
//    - The active tunnel address is hard-allowlisted and can never be blocked, whatever the
//      counters say.
//    - When no per-client address can be established, we do NOT block, and we do not refuse
//      anyone either: `.throttled` raises an alert and counts, and a caller presenting a
//      correct credential is always let through. See `AccessDecision.refusesBeforeCredential`
//      for why that is the only answer available, and what it costs.
//
//  Successful requests are never counted. Some clients poll hard with valid credentials and
//  must never be throttled.
//
//  The durable half and the lane that writes it are `AccessControlPersistence.swift`; what
//  the operator is told is `AccessControlAlerts.swift`.
//
//  See `docs/AUTH.md`.

import BBCore
import BBDiagnostics
import Crypto
import Foundation
import Logging

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
  /// Distinct addresses that may FAIL behind one trusted proxy inside the window before we
  /// stop believing that proxy's forwarding header.
  ///
  /// The per-address counter is keyed on an address the peer DECLARED. Behind a trusted
  /// proxy that is a header, so anything that can reach the listener from a trusted peer —
  /// on the default policy, any local process, because the bundled tunnels connect over
  /// loopback and loopback is therefore trusted — gets a fresh bucket per request simply by
  /// varying `X-Forwarded-For`, and never reaches `perClientThreshold` at all.
  ///
  /// Raw failure volume cannot separate that from a password change storming twenty real
  /// clients. Distinct-address CHURN can: real clients are bounded by how many there are,
  /// and each stops counting once it blocks at ten. This is deliberately generous against
  /// the largest plausible install and still bounds an attacker to roughly
  /// `limit × perClientThreshold` guesses per window instead of unlimited.
  public var forwardedChurnLimit: Int

  public init(
    perClientThreshold: Int = 10,
    globalThreshold: Int = 200,
    window: Duration = .seconds(300),
    baseLockout: Duration = .seconds(900),
    maximumLockout: Duration = .seconds(86_400),
    isEnabled: Bool = true,
    failureHistoryLimit: Int = 500,
    addressMemoryLimit: Int = 10_000,
    forwardedChurnLimit: Int = 256
  ) {
    self.perClientThreshold = perClientThreshold
    self.globalThreshold = globalThreshold
    self.window = window
    self.baseLockout = baseLockout
    self.maximumLockout = maximumLockout
    self.isEnabled = isEnabled
    self.failureHistoryLimit = failureHistoryLimit
    self.addressMemoryLimit = addressMemoryLimit
    self.forwardedChurnLimit = forwardedChurnLimit
  }
}

// MARK: - Records

/// The identity of a blocklist or allowlist entry, derived from the one thing that makes the
/// entry unique: its address, or its range.
///
/// DERIVED rather than minted, because the id is what `DELETE security/blocklist/:id` and the
/// Security page act on, and it has to name the same entry after a reload. A random id per
/// load made an unblock with an id read before a restart match nothing, and the route
/// answered success for an unblock that had not happened. The tables are rewritten whole on
/// every save, so their row ids are no more stable; the address and the range are, and each
/// is unique in its table.
enum AccessControlEntryID {
  static func blocked(address: String) -> UUID { derive("blocked", address) }
  static func allowed(cidr: String) -> UUID { derive("allowed", cidr) }

  /// A name-based UUID: the first sixteen bytes of a SHA-256, with the version (5) and
  /// variant bits set so it reads as one. The kind is part of the name, so an address that
  /// is both blocked and allowlisted does not share an id across the two lists.
  private static func derive(_ kind: String, _ name: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data("\(kind):\(name)".utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}

public struct BlockedClient: Sendable, Identifiable, Codable {
  /// Derived from `address`; see `AccessControlEntryID`.
  public var id: UUID { AccessControlEntryID.blocked(address: address) }
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
  /// Derived from `cidr`; see `AccessControlEntryID`.
  public var id: UUID { AccessControlEntryID.allowed(cidr: cidr) }
  /// A literal address or a CIDR block.
  public let cidr: String
  public let note: String?
  public let createdAt: Date

  public init(cidr: String, note: String? = nil, createdAt: Date) {
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

  /// Whether this decision refuses a request BEFORE its credential is looked at.
  ///
  /// **`.throttled` does not, and that was a self-inflicted outage.** Every caller used to
  /// pattern-match `case .blocked, .throttled:` and refuse both, and the two are not the
  /// same kind of answer at all:
  ///
  ///   - `.blocked` names ONE client that has already failed ten times. Refusing it before
  ///     the password comparison is the whole point of the ordering: guessing costs nothing
  ///     to refuse once the block lands, and nobody else is affected.
  ///   - `.throttled` names NOBODY. It is returned only for `.unresolved`, which is every
  ///     client behind a proxy that does not identify them. Refusing on it meant 200 bad
  ///     guesses locked out **every client on the install, including ones sending the
  ///     correct password** — for a rolling five-minute window an attacker can hold open
  ///     indefinitely from anywhere.
  ///
  /// That is precisely the failure this file's header says the unresolved path exists to
  /// avoid ("never a self-inflicted outage"), and the promise was made in prose and broken
  /// in code. Availability wins here, deliberately and with a cost: an unattributable
  /// attacker is no longer capped at `globalThreshold` guesses per window. **That cap
  /// cannot be kept — you cannot both bound guessing and guarantee a correct password
  /// works when you cannot tell the two callers apart.** What replaces it is telling the
  /// operator: `raiseThrottleAlert` fires, names the condition, and points at
  /// `trusted_proxies`, which is the setting that restores per-client attribution and with
  /// it real blocking. Reaching `.unresolved` on the default policy also means the peer is
  /// loopback, so the caller already has code running on this Mac.
  ///
  /// A property rather than three `switch`es, so a new case has to answer this question
  /// once instead of being folded into whichever neighbour it was written next to.
  public var refusesBeforeCredential: Bool {
    switch self {
    case .blocked: true
    case .allow, .throttled: false
    }
  }
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

  // Internal rather than private where the persistence lane, in its own file, reads them.
  var policy: AccessControlPolicy
  private let clock: any BBClock
  private let alerts: (any AlertRaising)?
  let persistence: (any AccessControlPersistence)?
  /// Told about every block, unblock and allowlist edit. Optional for the reason `alerts` is:
  /// a test builds this with nothing behind it, and production wires the audit log.
  private let auditor: (any AccessControlAuditing)?
  let logger = Logger(label: "bluebubbles.access-control")

  var blocked: [String: BlockedClient] = [:]
  var allowlist: [AllowedClient] = []
  private var trust: ProxyTrustPolicy
  var recentFailures: [AuthFailureRecord] = []

  /// Sliding failure timestamps per address, and one bucket for unresolved clients.
  private var failureTimes: [String: [Date]] = [:]
  private var unresolvedFailureTimes: [Date] = []

  /// Per trusted-proxy peer: which forwarded addresses have FAILED, and when last.
  ///
  /// Recorded on failure rather than on every request, so a busy install with real traffic
  /// never accumulates anything here. See `AccessControlPolicy.forwardedChurnLimit`.
  private var forwardedChurn: [String: [String: Date]] = [:]
  /// Peers whose header we have stopped believing, and when that lapses.
  private var churnTripped: [String: Date] = [:]

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
  private let expiryTask = OwnedTask()

  /// What still needs writing, and the one task writing it. See `AccessControlWriteLane`.
  var lane = AccessControlWriteLane()

  public init(
    policy: AccessControlPolicy = AccessControlPolicy(),
    trust: ProxyTrustPolicy = ProxyTrustPolicy(),
    clock: any BBClock = SystemClock(),
    alerts: (any AlertRaising)? = nil,
    persistence: (any AccessControlPersistence)? = nil,
    auditor: (any AccessControlAuditing)? = nil
  ) {
    self.policy = policy
    self.trust = trust
    self.clock = clock
    self.alerts = alerts
    self.persistence = persistence
    self.auditor = auditor
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

  /// The address privileged as the tunnel egress, if any.
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

  public func restore(
    blocked: [BlockedClient], allowlist: [AllowedClient], failures: [AuthFailureRecord] = []
  ) {
    for entry in blocked {
      self.blocked[entry.address] = entry
      offenceHistory[entry.address] = entry.offenceCount
    }
    self.allowlist = allowlist
    // **EVIDENCE, not enforcement, and the distinction is the whole reason this is not just
    // another restored collection.** `failureTimes` is the sliding window that decides
    // whether an address is blocked, and it is deliberately NOT seeded from these rows.
    //
    // Feeding them back in would mean a server restart could block somebody on the strength
    // of failures from days ago: ten stale rows for one address are ten rows, not ten
    // failures inside the current window, and `perClientThreshold` cannot tell the
    // difference. An administrator restarting the server while investigating an attack is
    // the most likely moment for that to fire, which is the worst possible moment.
    //
    // Blocks themselves DO survive, because they carry their own expiry and were already
    // decided. These are what was seen; the blocklist is what was done about it.
    self.recentFailures = failures.suffix(policy.failureHistoryLimit)
    publish()
  }

  // MARK: Evaluation

  public func identity(peerAddress: String?, forwardedFor: String?) -> ClientIdentity {
    // A peer that has shown forwarded-address churn has its header IGNORED for the rest of
    // the window, which drops its traffic onto the `.unresolved` path.
    //
    // Deliberately a degrade to an existing route rather than new enforcement. `.unresolved`
    // is already the designed answer to "no way to tell these clients apart": global
    // throttling at a much higher threshold, and NO blocking, because the only address to
    // blame would be the proxy every client shares. So the attacker loses the fresh bucket
    // per request and lands under the global ceiling, while a real client behind that
    // tunnel is never blocked and — since success is never counted — is unaffected until
    // the global threshold is genuinely reached.
    if let peerAddress, !peerAddress.isEmpty {
      let peer = ProxyTrustPolicy.normalize(peerAddress)
      if let until = churnTripped[peer] {
        if until > clock.now { return .unresolved }
        churnTripped.removeValue(forKey: peer)
      }
    }
    return trust.resolve(peerAddress: peerAddress, forwardedFor: forwardedFor)
  }

  /// Records that `address`, reached through `peer`, has failed — and trips the peer when
  /// too many DISTINCT addresses behind it have.
  ///
  /// Only for an address we were told about by a trusted proxy. A direct peer cannot vary
  /// its own address without actually having those addresses, which is the thing this is
  /// not trying to defend against.
  private func noteForwardedFailure(peer: String?, address: String, at now: Date) async {
    guard let peer, !peer.isEmpty else { return }
    let normalizedPeer = ProxyTrustPolicy.normalize(peer)
    guard trust.isTrustedProxy(normalizedPeer), normalizedPeer != address else { return }

    forwardedChurn[normalizedPeer, default: [:]][address] = now
    let distinct = forwardedChurn[normalizedPeer]?.count ?? 0
    guard distinct >= policy.forwardedChurnLimit, churnTripped[normalizedPeer] == nil
    else { return }

    churnTripped[normalizedPeer] = now.addingTimeInterval(policy.window.seconds)
    forwardedChurn.removeValue(forKey: normalizedPeer)
    await raiseChurnAlert(peer: normalizedPeer, distinct: distinct)
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
    reason: String,
    peerAddress: String? = nil
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
      // BEFORE the allowlist check. An allowlisted address is never blocked, so counting
      // its churn is the only thing standing between "forge a header naming an allowlisted
      // address" and an unlimited budget — which is exactly what `trust_local_network`
      // used to hand out by default.
      await noteForwardedFailure(peer: peerAddress, address: address, at: now)
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
  /// Announced because it means someone local is forging forwarding headers, and that is
  /// not a condition an operator can infer from anything else the server shows.
  ///
  /// No address in the body or the log: the only one we have is the PEER, which on the
  /// default policy is loopback and names nothing, and the forwarded addresses are the
  /// attacker's invention. `Redaction` would pass a fabricated address through unchanged
  /// and it would read as a real accusation.
  private func raiseChurnAlert(peer: String, distinct: Int) async {
    logger.warning(
      "Ignoring forwarded client addresses from a proxy after excessive churn",
      metadata: ["addressCount": .stringConvertible(distinct)])
    await alerts?.raise(AccessControlAlert.forwardedChurn(distinctAddresses: distinct))
  }

  private func raiseThrottleAlert(failureCount: Int) async {
    logger.warning(
      "Throttling failed logins from an unidentified source",
      metadata: ["failures": .stringConvertible(failureCount)])
    auditor?.record(.loginsThrottled(failureCount: failureCount))
    await alerts?.raise(AccessControlAlert.throttled(failureCount: failureCount))
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
    auditor?.record(
      .clientBlocked(
        address: address, reason: reason, failureCount: failureCount, offenceCount: offences,
        expiresAt: expiry))

    // What the alert says, for the log. The client is an IP and is named: it is what the
    // person unblocks.
    logger.warning(
      "Blocked a client after repeated failed logins",
      metadata: [
        "client": .string(address),
        "failures": .stringConvertible(failureCount),
        "offences": .stringConvertible(offences),
        "until": .string(AccessControlAlert.formatter.string(from: expiry)),
      ])

    // The alert carries the remedy: an .unblock action, so a false positive is one click
    // in the notification rather than a hunt through Settings.
    await alerts?.raise(
      AccessControlAlert.blocked(
        address: address, failureCount: failureCount, offenceCount: offences, until: expiry))

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
    // The newest snapshot only: each one is the whole state, so a follower that fell behind
    // needs the last and nothing before it. The default buffer is unbounded, and kept every
    // snapshot a stalled follower had not read.
    let stream = AsyncStream<AccessControlSnapshot>(bufferingPolicy: .bufferingNewest(1)) {
      continuation in
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
    if observers.isEmpty { expiryTask.cancel() }
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
    expiryTask.cancel()
    guard !observers.isEmpty else { return }
    let now = clock.now
    guard let earliest = blocked.values.compactMap(\.expiresAt).filter({ $0 > now }).min()
    else { return }
    // A hair after, so `isActive` is false when the prune runs rather than equal.
    let delay = earliest.timeIntervalSince(now) + 0.05
    expiryTask.run { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
      // Only a block that existed: `allow` calls this for every literal address it
      // allowlists, and "unblocked" a client that was never blocked would be a record of
      // nothing.
      auditor?.record(.clientUnblocked(address: normalized))
    }
    failureTimes.removeValue(forKey: normalized)
    persist(blocked: true)
    // The offence count is cleared too: an admin unblocking is saying this was a false
    // positive, so the next block should start from the base lockout rather than
    // escalating on top of a mistake.
    offenceHistory.removeValue(forKey: normalized)
    publish()
  }

  /// - Returns: false when no blocked entry has `id`, so the caller can say so rather than
  ///   report an unblock that did not happen.
  @discardableResult
  public func unblock(id: UUID) -> Bool {
    guard let entry = blocked.values.first(where: { $0.id == id }) else { return false }
    unblock(address: entry.address)
    return true
  }

  public func clearAllBlocks() {
    logger.info(
      "Cleared every block", metadata: ["blocked": .stringConvertible(blocked.count)])
    auditor?.record(.blocksCleared(count: blocked.count))
    blocked.removeAll()
    failureTimes.removeAll()
    unresolvedFailureTimes.removeAll()
    forwardedChurn.removeAll()
    churnTripped.removeAll()
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
    // REPLACES an entry for the same range rather than adding a second: the range is the
    // entry's identity (`AccessControlEntryID`) and is unique in `allowed_client`, so a
    // duplicate would share an id and fail the whole table's next save.
    allowlist.removeAll { $0.cidr == entry }
    allowlist.append(stored)
    logger.info("Allowlisted a client", metadata: ["client": .string(entry)])
    auditor?.record(.clientAllowlisted(cidr: entry, note: note))
    // Allowlisting implies unblocking, which is what "Unblock and allowlist" needs.
    if !entry.contains("/") { unblock(address: entry) }
    persist(allowlist: true)
    publish()
    return stored
  }

  /// - Returns: false when no allowlist entry has `id`, for the reason `unblock(id:)` gives.
  @discardableResult
  public func disallow(id: UUID) -> Bool {
    guard let entry = allowlist.first(where: { $0.id == id }) else { return false }
    logger.info("Removed a client from the allowlist", metadata: ["client": .string(entry.cidr)])
    auditor?.record(.allowlistEntryRemoved(cidr: entry.cidr))
    allowlist.removeAll { $0.id == id }
    persist(allowlist: true)
    publish()
    return true
  }

  public func blockPermanently(address: String, reason: String) {
    let normalized = ProxyTrustPolicy.normalize(address)
    guard !isAlwaysAllowed(normalized) else { return }
    logger.info(
      "Blocked a client permanently",
      metadata: ["client": .string(normalized), "reason": .string(reason)])
    auditor?.record(.clientBlockedPermanently(address: normalized, reason: reason))
    let now = clock.now
    let existing = blocked[normalized]
    blocked[normalized] = BlockedClient(
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

    for (peer, addresses) in forwardedChurn {
      let kept = addresses.filter { $0.value > cutoff }
      if kept.isEmpty {
        forwardedChurn.removeValue(forKey: peer)
      } else {
        forwardedChurn[peer] = kept
      }
    }
    for (peer, until) in churnTripped where until <= now { churnTripped.removeValue(forKey: peer) }

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
    // Debounced, never a write per failure: the arrival rate here belongs to the attacker.
    // See `AccessControlWriteLane.failureWriteTask`.
    persistFailuresSoon()
  }
}

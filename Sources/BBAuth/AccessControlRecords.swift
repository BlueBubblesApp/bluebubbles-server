//  AccessControlRecords
//  The records access control keeps and answers with: `BlockedClient`, `AllowedClient`,
//  `AuthFailureRecord`, the derived `AccessControlEntryID` and the `AccessDecision` a request
//  is given.
//
//  Its own file so the shapes the `security/*` routes and the Security page read are opened
//  without the actor that produces them (`AccessControl.swift`). Their wire projection is
//  `AccessControlRecords+JSON.swift`, beside this one.

import Crypto
import Foundation

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

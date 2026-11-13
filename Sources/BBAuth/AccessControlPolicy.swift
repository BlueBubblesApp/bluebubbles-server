//  AccessControlPolicy
//  The thresholds and limits access control counts against.
//
//  Its own file so the knobs a setting or a test turns are read apart from the actor that
//  applies them (`AccessControl.swift`), whose rules about WHOSE failure a failure is are the
//  dangerous part. Every value here is a number with its reason beside it; nothing here
//  decides.

import Foundation

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

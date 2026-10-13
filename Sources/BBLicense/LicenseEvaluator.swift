//  LicenseEvaluator
//  Stored license state plus a clock, in; a status, out. No I/O, no network, no actor.
//
//  Everything expensive about getting licensing wrong is a wrong answer from this one pure
//  function: refusing a paying customer, or telling someone their subscription expired when
//  their router died. Being pure is what lets every window below be tested exhaustively
//  against `ManualClock` with no sleeping, no network, and no vendor account.
//
//  ORDER OF CHECKS IS THE DESIGN. Revocation, then the token, then machine, then the
//  SUBSCRIPTION's end, then the TOKEN's staleness. `subscriptionEndsAt` is consulted before
//  `expiresAt` on purpose: a
//  token that says the subscription ended lets us say so precisely, and reaching the staleness
//  check first would report a genuine expiry as "could not confirm" and send the customer to
//  check their internet connection instead of to the renew button.
//
//  FAILS CLOSED PAST `exp`, and that is only defensible because base functionality is never
//  gated. An unconfirmable entitlement is not an entitlement, and an offline Mac must not be a
//  way to hold paid features forever. What such a server loses is the extras; it keeps every
//  message, notification and socket it had before the subscription existed.

import BBCore
import Foundation

/// The canonical windows. One file, so there is no second opinion about them.
public enum LicenseWindows {

  /// How often a refresh is attempted. A single failure means nothing.
  public static let refreshInterval: TimeInterval = 24 * 60 * 60

  /// What the issuer should put in `exp` for a recurring subscription.
  ///
  /// Seven days is an operational margin, not a grace period: with daily refresh it takes
  /// seven CONSECUTIVE failures to exhaust. It absorbs a Mac asleep for a weekend, a rebooted
  /// router and a transient endpoint failure — none of which say anything about the
  /// subscription. Shorter turns ordinary infrastructure noise into support tickets; longer
  /// starts being a loophole.
  public static let subscriptionTokenLifetime: TimeInterval = 7 * 24 * 60 * 60

  /// What the issuer should put in `exp` for a perpetual ("lifetime") purchase.
  ///
  /// Ninety days, not seven, and not never. A lifetime license that stops working after a week
  /// offline is a support problem and a bad review; one that never checks in can never be
  /// revoked after a refund or a chargeback. Ninety days comfortably exceeds a typical refund
  /// window while still meaning "needs the internet a few times a year", which is defensible
  /// to someone who paid once.
  public static let perpetualTokenLifetime: TimeInterval = 90 * 24 * 60 * 60

  /// Days of consecutive refresh failure at which the user is warned.
  ///
  /// Load-bearing: failing closed is only acceptable because nobody discovers it by a feature
  /// silently vanishing. These fire well before anything stops.
  public static let warningThresholds: [TimeInterval] = [
    3 * 24 * 60 * 60,
    5 * 24 * 60 * 60,
  ]
}

/// What is persisted between runs. `LicenseStatus` is derived from this and never stored.
public struct LicenseState: Sendable, Equatable {

  /// The last token that verified, if any.
  public let token: EntitlementToken?

  /// When a refresh last succeeded. Drives the warnings, and the `since` a lapsed status
  /// reports.
  public let lastRefresh: Date?

  /// Set when the issuer reports the license disabled. A fact from outside; nothing about a
  /// token can imply it.
  public let isRevoked: Bool

  /// Whether a license key has been entered at all.
  ///
  /// Carried because the token alone cannot answer it, and the two cases it separates are
  /// opposite messages: somebody who has entered no key should be offered a subscription,
  /// and somebody who has entered one we have never managed to confirm should be told to
  /// check their connection. Without this, a customer who pasted a valid key on a Mac that
  /// could not reach the issuer was shown "this feature requires a subscription" and a Buy
  /// button, having just paid.
  ///
  /// Never the key itself: this type has no business holding one, and nothing needs it to.
  public let hasKey: Bool

  public init(
    token: EntitlementToken? = nil, lastRefresh: Date? = nil, isRevoked: Bool = false,
    hasKey: Bool = false
  ) {
    self.token = token
    self.lastRefresh = lastRefresh
    self.isRevoked = isRevoked
    self.hasKey = hasKey
  }

  /// Nothing has ever been entered.
  public static let unlicensed = LicenseState()
}

public struct LicenseEvaluator: Sendable {

  private let clock: any BBClock
  /// This machine's identifier, already hashed. Compared against the token's `machine`.
  private let machine: String

  public init(clock: any BBClock = SystemClock(), machine: String) {
    self.clock = clock
    self.machine = machine
  }

  public func status(of state: LicenseState) -> LicenseStatus {
    // REVOCATION FIRST, before even asking whether a token is cached. A license can be
    // revoked before this machine ever holds a token for it — someone enters a key that has
    // already been refunded — and checking the token first reports that as "no license",
    // which sends them to the subscribe button instead of to support. `clear()` resets the
    // flag, so a set flag always means a key was entered.
    if state.isRevoked { return .revoked }
    guard let token = state.token else {
      // A key with no token is NOT "no subscription". It is one we have never been able to
      // confirm — a first run behind a broken resolver, an issuer that was down when the key
      // was pasted — and the honest answer points at the connection rather than at the shop.
      return state.hasKey ? .unverifiable(since: state.lastRefresh) : .none
    }

    // Before any date question: a token for another Mac is not this server's entitlement,
    // however fresh it is.
    guard token.machine == machine else { return .machineMismatch }

    let now = clock.now

    // The subscription's own end, first. See the header for why this precedes staleness.
    if let ends = token.subscriptionEndsAt, ends <= now { return .expired(at: ends) }

    // Stale, and nothing has refreshed it. We do not know the license is bad.
    if token.expiresAt <= now { return .unverifiable(since: state.lastRefresh) }

    return .active(token)
  }

  /// How long refreshes have been failing, for the warning alerts. `nil` when nothing has
  /// succeeded yet, which is a different situation from a long-running failure.
  public func refreshFailureDuration(of state: LicenseState) -> TimeInterval? {
    guard let last = state.lastRefresh else { return nil }
    return max(0, clock.now.timeIntervalSince(last))
  }

  /// The highest warning threshold now crossed, or `nil` if none is. The caller alerts once
  /// per distinct value.
  public func warningThresholdCrossed(of state: LicenseState) -> TimeInterval? {
    guard let elapsed = refreshFailureDuration(of: state) else { return nil }
    return LicenseWindows.warningThresholds.last { elapsed >= $0 }
  }
}

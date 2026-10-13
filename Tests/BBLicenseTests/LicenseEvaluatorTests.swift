//  LicenseEvaluatorTests
//  The windows in `LicenseWindows`, driven by `ManualClock`. Nothing sleeps.
//
//  Two assertions here are the ones worth having: that six days of failed refresh is still
//  entitled and seven is not, and that a genuine expiry reports `license_expired` while a
//  failed refresh reports `validation_unavailable`. The first is the boundary a paying
//  customer sits on when their Mac sleeps over a holiday; the second is the difference between
//  telling someone to renew and telling them to check their internet.

import BBCore
import Foundation
import Testing

@testable import BBLicense

@Suite("LicenseEvaluator")
struct LicenseEvaluatorTests {

  static let machine = "abc123"
  static let start = Date(timeIntervalSince1970: 1_700_000_000)

  static func token(
    tier: SubscriptionTier = .pro,
    machine: String = machine,
    issued: Date = start,
    expires: Date,
    subscriptionEnds: Date?,
    perpetual: Bool = false
  ) -> EntitlementToken {
    EntitlementToken(
      version: 1, subject: "cus_1", tier: tier, features: [], machine: machine,
      issuedAt: issued, expiresAt: expires, subscriptionEndsAt: subscriptionEnds,
      identifier: "tok_1", isPerpetual: perpetual
    )
  }

  static func evaluator(_ clock: ManualClock) -> LicenseEvaluator {
    LicenseEvaluator(clock: clock, machine: machine)
  }

  @Test("No key entered is .none, not a failure")
  func unlicensed() {
    let clock = ManualClock(Self.start)
    #expect(Self.evaluator(clock).status(of: .unlicensed) == .none)
  }

  @Test("A fresh token is active")
  func fresh() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(LicenseWindows.subscriptionTokenLifetime),
        subscriptionEnds: Self.start.addingTimeInterval(30 * 86_400)),
      lastRefresh: Self.start
    )
    #expect(Self.evaluator(clock).status(of: state).tier == .pro)
  }

  /// The boundary. Six days of silence is still a paying customer; seven is not.
  @Test(
    "Six days of failed refresh still entitled, seven refuses",
    arguments: [
      (days: 1.0, entitled: true), (days: 6.0, entitled: true),
      (days: 6.9, entitled: true), (days: 7.0, entitled: false), (days: 30.0, entitled: false),
    ])
  func refreshMargin(days: Double, entitled: Bool) {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(LicenseWindows.subscriptionTokenLifetime),
        subscriptionEnds: nil),
      lastRefresh: Self.start
    )
    clock.advance(by: days * 86_400)
    let status = Self.evaluator(clock).status(of: state)
    #expect((status.tier != nil) == entitled)
    if !entitled {
      #expect(status.refusal(forRequired: .pro)?.reason == "validation_unavailable")
    }
  }

  /// The distinction the whole design exists to preserve.
  @Test("An ended subscription is not the same refusal as an unrefreshed token")
  func expiredIsNotUnverifiable() {
    let clock = ManualClock(Self.start)
    let ended = Self.start.addingTimeInterval(-86_400)
    let expired = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(86_400), subscriptionEnds: ended),
      lastRefresh: Self.start)
    let stale = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(-1), subscriptionEnds: nil),
      lastRefresh: Self.start.addingTimeInterval(-10 * 86_400))

    let evaluator = Self.evaluator(clock)
    #expect(evaluator.status(of: expired).refusal(forRequired: .pro)?.reason == "license_expired")
    #expect(
      evaluator.status(of: stale).refusal(forRequired: .pro)?.reason == "validation_unavailable")
  }

  /// A lifetime purchase: no subscription end, and a window wide enough that it is not a
  /// support burden.
  @Test("A perpetual token survives its longer window and still lapses past it")
  func perpetual() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(LicenseWindows.perpetualTokenLifetime),
        subscriptionEnds: nil, perpetual: true),
      lastRefresh: Self.start)
    #expect(state.token?.isPerpetual == true)

    clock.advance(by: 89 * 86_400)
    #expect(Self.evaluator(clock).status(of: state).tier == .pro)
    clock.advance(by: 2 * 86_400)
    #expect(Self.evaluator(clock).status(of: state).tier == nil)
  }

  @Test("A token for another Mac is refused before any date question")
  func machineMismatch() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        machine: "someone-else",
        expires: Self.start.addingTimeInterval(86_400), subscriptionEnds: nil),
      lastRefresh: Self.start)
    #expect(
      Self.evaluator(clock).status(of: state).refusal(forRequired: .pro)?.reason
        == "machine_mismatch")
  }

  @Test("Revocation outranks a perfectly good token")
  func revoked() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(86_400), subscriptionEnds: nil),
      lastRefresh: Self.start, isRevoked: true)
    #expect(
      Self.evaluator(clock).status(of: state).refusal(forRequired: .pro)?.reason
        == "license_revoked")
  }

  /// A clock that jumped backwards must not turn a lapsed license into a live one by accident,
  /// nor a live one into a lapsed one. Macs sleep and resync; this is not hypothetical.
  @Test("A backwards clock jump does not grant or revoke anything surprising")
  func clockWentBackwards() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(86_400), subscriptionEnds: nil),
      lastRefresh: Self.start)
    clock.advance(by: -365 * 86_400)
    #expect(Self.evaluator(clock).status(of: state).tier == .pro)
    #expect(Self.evaluator(clock).refreshFailureDuration(of: state) == 0)
  }

  @Test("Warnings fire before anything stops")
  func warnings() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(
      token: Self.token(
        expires: Self.start.addingTimeInterval(LicenseWindows.subscriptionTokenLifetime),
        subscriptionEnds: nil), lastRefresh: Self.start)
    let evaluator = Self.evaluator(clock)

    #expect(evaluator.warningThresholdCrossed(of: state) == nil)
    clock.advance(by: 3 * 86_400)
    #expect(evaluator.warningThresholdCrossed(of: state) == LicenseWindows.warningThresholds[0])
    clock.advance(by: 2 * 86_400)
    #expect(evaluator.warningThresholdCrossed(of: state) == LicenseWindows.warningThresholds[1])
    // Both warnings land inside the window, which is the point of having them.
    #expect(evaluator.status(of: state).tier == .pro)
  }
}

extension LicenseEvaluatorTests {

  /// Revocation can arrive before this machine has ever cached a token — someone enters a key
  /// that was already refunded. Checking the token first reported that as "no license", which
  /// points the user at the subscribe button rather than at support.
  @Test("A revoked license with no cached token still reports revoked")
  func revokedBeforeAnyToken() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(token: nil, lastRefresh: nil, isRevoked: true)
    let status = Self.evaluator(clock).status(of: state)
    #expect(status == .revoked)
    #expect(status.refusal(forRequired: .pro)?.reason == "license_revoked")
  }
}

extension LicenseEvaluatorTests {

  /// THE CASE THE REAL VENDOR PRODUCED, and the reason `isPerpetual` is a claim.
  ///
  /// Lemon Squeezy reports a license key's `expires_at` as null while the subscription is
  /// ACTIVE — the key has no expiry of its own, it simply lives as long as the subscription
  /// does, which is why the dashboard shows it as never expiring. Inferring "perpetual" from
  /// that absence told a healthy $3/month subscriber they had bought the software outright.
  @Test("An active subscription with no known renewal date is not perpetual")
  func activeSubscriptionIsNotPerpetual() {
    let clock = ManualClock(Self.start)
    let token = Self.token(
      expires: Self.start.addingTimeInterval(7 * 86_400), subscriptionEnds: nil)

    #expect(token.isPerpetual == false, "absence of an end date is not a purchase")
    #expect(
      Self.evaluator(clock).status(of: LicenseState(token: token, lastRefresh: Self.start))
        .tier == .pro)
  }

  @Test("A perpetual license says so explicitly")
  func perpetualIsStated() {
    let token = EntitlementToken(
      version: 1, subject: "cus_1", tier: .pro, features: [], machine: Self.machine,
      issuedAt: Self.start, expiresAt: Self.start.addingTimeInterval(90 * 86_400),
      subscriptionEndsAt: nil, identifier: "tok_1", isPerpetual: true)
    #expect(token.isPerpetual)
  }
}

extension LicenseEvaluatorTests {

  /// FOUND BY A BROKEN DNS RESOLVER, which is the most honest way to find it. A key was
  /// pasted, the issuer could not be reached, no token was ever obtained — and the server
  /// answered `no_license`, so a customer who had just paid was shown "this feature requires
  /// a subscription" and a Buy button.
  ///
  /// The token alone cannot tell those apart, which is why `hasKey` is carried.
  @Test("A key that has never been confirmed is unverifiable, not unlicensed")
  func keyEnteredButNeverConfirmed() {
    let clock = ManualClock(Self.start)
    let state = LicenseState(token: nil, lastRefresh: nil, isRevoked: false, hasKey: true)

    let status = Self.evaluator(clock).status(of: state)
    #expect(status == .unverifiable(since: nil))
    #expect(status.refusal(forRequired: .pro)?.reason == "validation_unavailable")
  }

  @Test("No key at all is still no license")
  func noKeyIsStillNone() {
    let clock = ManualClock(Self.start)
    #expect(Self.evaluator(clock).status(of: .unlicensed) == .none)
    #expect(
      Self.evaluator(clock).status(of: .unlicensed).refusal(forRequired: .pro)?.reason
        == "no_license")
  }

  /// And the two produce different sentences, which is the whole point of separating them.
  @Test("The two say opposite things to the person reading them")
  func theMessagesDiffer() {
    let clock = ManualClock(Self.start)
    let unlicensed = Self.evaluator(clock).status(of: .unlicensed)
      .refusal(forRequired: .pro)
    let unconfirmed = Self.evaluator(clock)
      .status(of: LicenseState(hasKey: true)).refusal(forRequired: .pro)

    #expect(unlicensed?.sentence != unconfirmed?.sentence)
    #expect(unconfirmed?.sentence.localizedCaseInsensitiveContains("internet") == true)
    #expect(unlicensed?.sentence.localizedCaseInsensitiveContains("requires") == true)
  }

  /// The blanket refusal is the per-floor refusal with the tier question taken out: the two
  /// agree on every status that refuses outright, and only an active status can differ.
  @Test("A blanket refusal agrees with the per-floor refusal wherever a status refuses outright")
  func blanketRefusalAgrees() {
    let ended = Self.start.addingTimeInterval(-1)
    let refusing: [LicenseStatus] = [
      .none, .expired(at: ended), .revoked, .machineMismatch, .unverifiable(since: nil),
    ]
    for status in refusing {
      #expect(status.blanketRefusal != nil, "\(status.name) grants nothing")
      #expect(status.blanketRefusal == status.refusal(forRequired: .pro))
    }

    let active = LicenseStatus.active(
      Self.token(expires: Self.start.addingTimeInterval(86_400), subscriptionEnds: nil))
    #expect(active.blanketRefusal == nil)
    #expect(active.refusal(forRequired: .pro) == nil)
    let higher = SubscriptionTier(id: "higher", rank: 9, displayName: "Higher")
    #expect(active.refusal(forRequired: higher) == .insufficientTier(required: higher, held: .pro))
  }
}

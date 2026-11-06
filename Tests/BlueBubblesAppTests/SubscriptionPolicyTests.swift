//  SubscriptionPolicyTests
//  The sentences somebody reads while deciding whether to pay, or working out why a feature
//  stopped.
//
//  The assertion that carries this file is that a subscription which ENDED and one that merely
//  could not be CONFIRMED say different things. They are the same outcome — paid features are
//  off — and telling a customer whose router has been down for a week that their subscription
//  expired is telling them something false about their own money. Both sentences read
//  perfectly reasonably in isolation, which is exactly why a test has to hold them apart.

import BBInterfaces
import BBLicense
import BBLicensing
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Subscription policy")
struct SubscriptionPolicyTests {

  static let now = Date(timeIntervalSince1970: 1_700_000_000)

  static func report(
    tier: SubscriptionTier? = nil, status: String, ends: Date? = nil,
    perpetual: Bool = false, failingSince: Date? = nil
  ) -> SubscriptionReport {
    SubscriptionReport(
      tier: tier, status: status, subscriptionEndsAt: ends, isPerpetual: perpetual,
      refreshFailingSince: failingSince, features: [],
      availableTiers: SubscriptionTier.shipped)
  }

  // MARK: - The distinction the whole design exists to preserve

  @Test("An ended subscription and an unconfirmable one do not say the same thing")
  func endedIsNotUnconfirmed() {
    let ended = SubscriptionPolicy.presentation(
      for: Self.report(status: "expired", ends: Self.now.addingTimeInterval(-86_400)),
      now: Self.now)
    let unconfirmed = SubscriptionPolicy.presentation(
      for: Self.report(status: "unverifiable", failingSince: Self.now.addingTimeInterval(-86_400)),
      now: Self.now)

    #expect(ended.headline != unconfirmed.headline)
    #expect(ended.headline.localizedCaseInsensitiveContains("ended"))
    #expect(unconfirmed.headline.localizedCaseInsensitiveContains("could not be confirmed"))

    // And the unconfirmed one must not tell somebody their subscription lapsed.
    for word in ["ended", "expired", "lapsed"] {
      #expect(!unconfirmed.headline.localizedCaseInsensitiveContains(word))
      #expect(!unconfirmed.detail.localizedCaseInsensitiveContains(word))
    }
    // It should say what it probably IS, because it usually is.
    #expect(unconfirmed.detail.localizedCaseInsensitiveContains("network"))
  }

  @Test("An unconfirmable subscription offers a retry, never a repurchase")
  func unconfirmedOffersRetry() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(status: "unverifiable"), now: Self.now)
    #expect(presentation.actions.contains(.checkNow))
    #expect(!presentation.actions.contains(.subscribe), "do not sell to a paying customer")
  }

  // MARK: - The ordinary states

  @Test("No license explains that the server works anyway")
  func none() {
    let presentation = SubscriptionPolicy.presentation(for: Self.report(status: "none"))
    #expect(presentation.tone == .informational)
    #expect(presentation.actions == [.subscribe])
    // The free server is fully functional and the page has to say so: somebody reading this
    // should not conclude the thing they already have is crippled.
    #expect(presentation.detail.localizedCaseInsensitiveContains("without one"))
  }

  @Test("An active subscription well before renewal is quiet")
  func activeAndQuiet() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(
        tier: .pro, status: "active", ends: Self.now.addingTimeInterval(45 * 86_400)),
      now: Self.now)
    #expect(presentation.tone == .good)
    #expect(presentation.headline.contains("Pro"))
    #expect(!presentation.actions.contains(.subscribe))
  }

  /// The one state where saying nothing costs somebody a feature they are still paying for.
  @Test("A renewal inside the notice window is called out", arguments: [0, 1, 3, 7])
  func renewalSoon(days: Int) {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(
        tier: .pro, status: "active",
        ends: Self.now.addingTimeInterval(Double(days) * 86_400)),
      now: Self.now)
    #expect(presentation.tone == .attention, "\(days) days out should be called out")
  }

  @Test("A renewal beyond the notice window is not")
  func renewalLater() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(
        tier: .pro, status: "active",
        ends: Self.now.addingTimeInterval(Double(SubscriptionPolicy.renewalNoticeDays + 1) * 86_400)
      ),
      now: Self.now)
    #expect(presentation.tone == .good)
  }

  @Test("A lifetime purchase is not described as renewing")
  func perpetual() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(tier: .pro, status: "active", perpetual: true), now: Self.now)
    #expect(presentation.tone == .good)
    #expect(!presentation.detail.localizedCaseInsensitiveContains("renews"))
    // It still checks in, and somebody who paid once deserves to know that up front rather
    // than discovering it when a feature stops on a disconnected Mac.
    #expect(presentation.detail.localizedCaseInsensitiveContains("internet"))
  }

  @Test("A revoked license sends the person to support rather than to checkout")
  func revoked() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(status: "revoked"), now: Self.now)
    #expect(presentation.tone == .problem)
    #expect(!presentation.actions.contains(.subscribe), "buying again is not the first answer")
    #expect(presentation.actions.contains(.remove))
  }

  @Test("A license for another Mac explains itself and offers both ways out")
  func machineMismatch() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(status: "machine_mismatch"), now: Self.now)
    #expect(presentation.actions.contains(.remove))
    // Re-exchanging IS the fix here: the key is good, the token was minted for another Mac,
    // and a fresh exchange activates this one. So the way out is the button, not an account
    // page — and the sentence has to name the button rather than a portal that does not exist.
    #expect(presentation.actions.contains(.checkNow))
    #expect(presentation.detail.localizedCaseInsensitiveContains("check now"))
    #expect(presentation.detail.localizedCaseInsensitiveContains("different key"))
  }

  @Test("Every state offers something to do")
  func everyStateIsActionable() {
    for status in ["none", "active", "expired", "revoked", "machine_mismatch", "unverifiable"] {
      let presentation = SubscriptionPolicy.presentation(
        for: Self.report(tier: status == "active" ? .pro : nil, status: status), now: Self.now)
      #expect(!presentation.actions.isEmpty, "\(status) is a dead end")
      #expect(!presentation.headline.isEmpty)
      #expect(!presentation.detail.isEmpty)
    }
  }

  // MARK: - What entering a key reports

  @Test("Success says nothing; every failure says something")
  func outcomeMessages() {
    #expect(SubscriptionPolicy.message(for: .refreshed(.pro)) == nil)
    // A token that grants nothing is not a success, and the message says why.
    let ended = Date(timeIntervalSince1970: 1_700_000_000)
    let notEntitled = SubscriptionPolicy.message(for: .notEntitled(.expired(at: ended)))
    #expect(notEntitled == "\(LicenseRefusal.expired(at: ended).sentence).")
    #expect(SubscriptionPolicy.message(for: .noKey) != nil)
    #expect(SubscriptionPolicy.message(for: .revoked) != nil)
    #expect(SubscriptionPolicy.message(for: .failed(reason: "boom")) != nil)
    // Never the raw reason: that is a Swift error description, not a sentence.
    #expect(SubscriptionPolicy.message(for: .failed(reason: "boom"))?.contains("boom") == false)
  }
}

extension SubscriptionPolicyTests {

  /// What a live $3/month subscriber actually saw before `perp` existed: "purchased outright,
  /// this Mac is licensed for good." They are paying monthly and one failed card away from
  /// losing it.
  @Test("An active subscription with no renewal date is not described as a purchase")
  func activeWithoutRenewalDateIsNotAPurchase() {
    let presentation = SubscriptionPolicy.presentation(
      for: Self.report(tier: .pro, status: "active", ends: nil, perpetual: false),
      now: Self.now)

    #expect(presentation.tone == .good)
    for phrase in ["outright", "licensed for good", "renews"] {
      #expect(
        !presentation.headline.localizedCaseInsensitiveContains(phrase)
          && !presentation.detail.localizedCaseInsensitiveContains(phrase),
        "must not claim \(phrase) with no end date known")
    }
    #expect(presentation.headline.localizedCaseInsensitiveContains("active"))
  }
}

/// What the page DRAWS, as opposed to what it says.
///
/// The bug this pins shipped: the body was an `else if` chain of four branches with no final
/// `else`, and the one state it did not name is the state every visit begins in — the server
/// running, the read not yet made. The page rendered nothing, and because a view with nothing
/// to draw has nothing to hang a modifier on, the `.task` that would have STARTED the read
/// never ran either. So it did not fill in a moment later: the Subscription tab was blank for
/// as long as it was open, on a working server with a valid license.
///
/// The `switch` that replaced the chain is exhaustive, so the compiler now refuses that shape
/// here. This suite is the other half: that each state maps to the branch a person should see,
/// including the one that was missing.
@Suite("Subscription page state")
struct SubscriptionPagePolicyTests {

  private static func report() -> SubscriptionReport {
    SubscriptionPolicyTests.report(tier: .pro, status: "active")
  }

  /// The regression, stated on its own. `idle` is `ScreenModel`'s starting state.
  @Test("A running server with the read not yet made is loading, not nothing")
  func idleWhileRunningIsLoading() {
    #expect(SubscriptionPolicy.page(isRunning: true, state: .idle) == .loading)
  }

  @Test("Every state the page can be in maps to something it can draw")
  func everyStateIsDrawable() {
    let states: [ScreenState<SubscriptionReport>] = [
      .idle, .loading, .loaded(Self.report()), .failed("nope"),
    ]
    for running in [true, false] {
      for state in states {
        // Total by construction; the value is asserted case by case below. This is the
        // floor: no combination is left without an answer.
        _ = SubscriptionPolicy.page(isRunning: running, state: state)
      }
    }
  }

  @Test("A loaded report is shown")
  func loadedIsShown() {
    #expect(
      SubscriptionPolicy.page(isRunning: true, state: .loaded(Self.report()))
        == .showing(Self.report()))
  }

  @Test("A failed read says so rather than showing nothing")
  func failedIsReported() {
    #expect(
      SubscriptionPolicy.page(isRunning: true, state: .failed("the server refused"))
        == .unreadable("the server refused"))
  }

  /// A stopped server outranks a value still in hand. `ScreenState` deliberately keeps the
  /// last value through a failed reload, and drawing it here would present the entitlement of
  /// a server that is not running as though it were live.
  @Test("A stopped server is stopped, even holding a report from when it ran")
  func stoppedOutranksAStaleReport() {
    #expect(SubscriptionPolicy.page(isRunning: false, state: .loaded(Self.report())) == .stopped)
    #expect(SubscriptionPolicy.page(isRunning: false, state: .idle) == .stopped)
  }
}

@Suite("Subscription states this app does not know")
struct UnknownSubscriptionStateTests {

  /// A status a newer server sends is not "No subscription": that told a paying customer
  /// they had none.
  @Test("An unknown status is not presented as no subscription")
  func unknownIsNotNone() {
    let report = SubscriptionReport(
      tier: nil, status: "paused", subscriptionEndsAt: nil, isPerpetual: false,
      refreshFailingSince: nil, features: [], availableTiers: [])
    let page = SubscriptionPolicy.presentation(for: report)
    #expect(!page.headline.contains("No subscription"))
    #expect(page.actions == [.checkNow])
  }

  @Test("Every known status has a name the report reads back")
  func everyKindRoundTrips() {
    for kind in LicenseStatus.Kind.allCases {
      #expect(LicenseStatus.Kind(rawValue: kind.rawValue) == kind)
    }
  }
}

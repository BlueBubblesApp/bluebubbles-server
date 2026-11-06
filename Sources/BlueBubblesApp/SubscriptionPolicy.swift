//  SubscriptionPolicy
//  What the subscription page says, decided off the view so it can be asserted.
//
//  Every sentence here is one somebody reads while deciding whether to pay, or while trying to
//  work out why something stopped. Getting the wording wrong is the failure: telling a customer
//  whose router has been down for a week that their subscription EXPIRED is telling them
//  something false about their own money, and it is the kind of mistake nobody notices in
//  review because both sentences look reasonable in isolation.
//
//  So the distinction `LicenseStatus` preserves is carried all the way to the screen, and
//  `SubscriptionPolicyTests` pins each one. Touching a SwiftUI `View` from a test process
//  traps, which is why a rule that deserves a test cannot live on the view that draws it.
//
//  It takes `now` as a parameter for the same reason `BlockedClientSummary` does: "ends in
//  three days" is a boundary a test can state rather than wait for.

import BBInterfaces
import BBLicense
import BBLicensing
import Foundation

enum SubscriptionPolicy {

  /// What the page offers to do about the current state.
  ///
  /// A LIST rather than one primary action, because two of these states genuinely offer two:
  /// a lapsed subscription can be renewed or removed, and a mismatch can be re-activated or
  /// removed.
  ///
  /// There is deliberately NO "manage subscription" action. Creem mints a billing portal link
  /// per customer, from a customer id the license response does not carry, so there is no URL
  /// a server could send somebody to — and hard-coding the vendor's own domain is what §1.6
  /// exists to avoid. Anyone needing to change a card or cancel does it from the receipt the
  /// vendor emailed them.
  enum Action: Sendable, Equatable {
    /// Open the purchase page.
    case subscribe
    /// Exchange the stored key for a fresh token now.
    case checkNow
    /// Forget the license on this Mac.
    case remove
  }

  struct Presentation: Sendable, Equatable {
    /// How the page presents itself. `.attention` is not an error: it is the state where
    /// something a person paid for is about to stop.
    let tone: StatusTone

    /// The page's leading symbol. Chosen for what a subscription in each state is, which is
    /// why it is this type's and not `StatusTone.symbol`.
    var symbol: String {
      switch tone {
      case .informational: "star.circle"
      case .good: "checkmark.seal"
      case .attention: "clock.badge.exclamationmark"
      case .problem: "exclamationmark.triangle"
      }
    }
    /// One line, the answer to "what is my subscription doing".
    let headline: String
    /// The sentence under it. Always says what, if anything, the person should do.
    let detail: String
    let actions: [Action]
  }

  static func presentation(for report: SubscriptionReport, now: Date = Date()) -> Presentation {
    switch report.kind {
    case .active?:
      return active(report, now: now)

    case .expired?:
      // Only ever reached from a token that SAYS the subscription ended, so naming the date
      // is safe here and is not safe in the `unverifiable` case below.
      return Presentation(
        tone: .problem,
        headline: "Your subscription has ended",
        detail: report.subscriptionEndsAt.map {
          "It ended on \(spell($0)). Paid features are switched off; everything else is "
            + "unaffected."
        } ?? "Paid features are switched off; everything else is unaffected.",
        actions: [.subscribe, .remove])

    case .revoked?:
      return Presentation(
        tone: .problem,
        headline: "This license is no longer active",
        detail: "It was cancelled or refunded. If that is unexpected, get in touch before "
          + "buying again.",
        actions: [.remove])

    case .machineMismatch?:
      return Presentation(
        tone: .problem,
        headline: "This license belongs to a different Mac",
        detail: "Licenses are tied to the Mac they were activated on. Check now to activate "
          + "this one, or remove it here and enter a different key.",
        actions: [.checkNow, .remove])

    case .unverifiable?:
      // The careful one. We do NOT know the subscription lapsed: we know we could not ask.
      // Saying "expired" here is the mistake this whole file exists to prevent.
      return Presentation(
        tone: .problem,
        headline: "Your subscription could not be confirmed",
        detail: report.refreshFailingSince.map {
          "This Mac has not reached the license service since \(spell($0)). Check its "
            + "internet connection. This is usually a network problem rather than a problem "
            + "with your subscription."
        } ?? "Check this Mac's internet connection. This is usually a network problem rather "
          + "than a problem with your subscription.",
        actions: [.checkNow])

    case nil:
      // A state a newer server reports and this app was not built to read. Not "no
      // subscription", which told a paying customer they had none.
      return Presentation(
        tone: .attention,
        headline: "This server reported a subscription state this app does not recognise",
        detail: "Paid features follow what the server decides. Check now to read it again, or "
          + "update the app.",
        actions: [.checkNow])

    case .none?:
      return Presentation(
        tone: .informational,
        headline: "No subscription on this Mac",
        detail: "The server works fully without one. A subscription adds the extra features "
          + "listed below.",
        actions: [.subscribe])
    }
  }

  /// Active splits three ways, and the split is what makes the page useful rather than
  /// decorative: a subscription ending next week is the one state where saying nothing costs
  /// somebody a feature they are still paying for.
  private static func active(_ report: SubscriptionReport, now: Date) -> Presentation {
    let name = report.tier?.displayName ?? "Subscription"

    if report.isPerpetual {
      return Presentation(
        tone: .good,
        headline: "\(name), purchased outright",
        detail: "This Mac is licensed for good. It checks in occasionally to confirm that, "
          + "so it needs the internet every few months.",
        actions: [.checkNow])
    }

    if let ends = report.subscriptionEndsAt {
      let days = Calendar.current.dateComponents([.day], from: now, to: ends).day ?? 0
      if days <= renewalNoticeDays {
        return Presentation(
          tone: .attention,
          headline:
            "\(name) renews \(days <= 0 ? "today" : "in \(days.counted("day"))")",
          detail: "Renews on \(spell(ends)). Nothing to do unless you want to change or "
            + "cancel it.",
          actions: [.checkNow])
      }
      return Presentation(
        tone: .good,
        headline: "\(name) is active",
        detail: "Renews on \(spell(ends)).",
        actions: [.checkNow])
    }

    return Presentation(
      tone: .good, headline: "\(name) is active",
      detail: "Paid features are switched on.", actions: [.checkNow])
  }

  /// How close to renewal counts as worth mentioning.
  ///
  /// Seven days, matching the refresh window in `LicenseWindows`: within a week is close
  /// enough that a card expiring is about to become this person's problem, and far enough
  /// that saying so is a notice rather than a nag.
  static let renewalNoticeDays = 7

  /// `Date.FormatStyle` rather than a `DateFormatter`, which is not `Sendable` and cannot be
  /// held as a shared constant.
  static func spell(_ date: Date) -> String {
    date.formatted(date: .long, time: .omitted)
  }

  /// What entering a key produced, as a sentence.
  ///
  /// The outcome is reported rather than swallowed: a key that is rejected has to say so, or
  /// the page silently goes on showing "no subscription" and the person concludes the feature
  /// is broken rather than that they mistyped.
  static func message(for outcome: RefreshOutcome) -> String? {
    switch outcome {
    case .refreshed: nil
    // The issuer answered and the person is still refused; the refusal's own sentence says
    // why ("Your subscription ended on …"), which is what they need to hear rather than a
    // confirmation over features that refuse.
    case .notEntitled(let refusal): "\(refusal.sentence)."
    case .noKey: "Enter a license key first."
    case .revoked: "That license is no longer active."
    case .refused(let reason): "The license service did not accept this key. \(reason)"
    case .failed:
      "Could not reach the license service. Check this Mac's internet connection and try again."
    }
  }
}

// MARK: - Which state the page is in

extension SubscriptionPolicy {

  /// What the page draws, as one value.
  ///
  /// Here rather than in a chain of `else if`s on the view, because that chain had no final
  /// `else` and the missing branch was the state EVERY visit to the page starts in: the
  /// server running and the read not yet made. Nothing matched, so `body` was `EmptyView` —
  /// and an `EmptyView` draws nothing to attach a modifier to, so the `.task` that would
  /// have started the read never ran. The page did not resolve a moment later; it stayed
  /// blank for as long as it was open.
  ///
  /// A `switch` over this is exhaustive, so the compiler now refuses the shape that caused
  /// it. `SubscriptionPagePolicyTests` pins the mapping, and the scan in
  /// `ScreenLoadingStatePolicyTests` keeps the other reading pages total.
  enum Page: Sendable, Equatable {
    /// No server, so nothing to report. Distinct from having nothing: the license lives in
    /// the running server's runtime.
    case stopped
    /// Asked and not yet answered. Covers `idle` as well as `loading`: before the first read
    /// the honest thing to show is the same spinner, not an empty page.
    case loading
    case showing(SubscriptionReport)
    case unreadable(String)
  }

  /// Total by construction: every `(isRunning, state)` pair maps to something drawable.
  ///
  /// `stopped` outranks a value that is still in hand. A stopped server keeps whatever was
  /// last read (`ScreenState` holds the value through a failed reload on purpose), and
  /// showing it would present a stale entitlement as the live one on a server that is not
  /// running to enforce it.
  static func page(isRunning: Bool, state: ScreenState<SubscriptionReport>) -> Page {
    guard isRunning else { return .stopped }
    if let report = state.value { return .showing(report) }
    if let failure = state.errorMessage { return .unreadable(failure) }
    return .loading
  }
}

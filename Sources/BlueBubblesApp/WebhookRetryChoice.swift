//  WebhookRetryChoice
//  A webhook's retry policy while it is being edited, and the sentence that explains it.
//
//  Off the view so the round trip and the schedule can be tested; see
//  `Sources/BlueBubblesApp/CLAUDE.md` on policy living off the view.
//
//  The switch and the count are separate on purpose. `WebhookRetryPolicy` says "off" with a
//  count of zero, and a stepper bound straight to that count would either let someone step
//  down to zero (off, with the switch still showing on) or forget the count they had chosen
//  the moment the switch went off. Here the count survives the switch.

import BBEvents
import Foundation

struct WebhookRetryChoice: Equatable, Sendable {

  var isEnabled: Bool
  /// Retries after the first attempt, while `isEnabled`.
  var retries: Int
  var initialDelaySeconds: Int

  /// From one retry up; zero is the switch, not the stepper.
  static let retryRange = 1...WebhookRetryPolicy.retryRange.upperBound

  /// The waits offered before the first retry.
  static let standardDelays = [5, 10, 30, 60, 300, 900]

  init(policy: WebhookRetryPolicy) {
    isEnabled = policy.isEnabled
    // A webhook with retries off opens with the standard count waiting behind the switch,
    // so turning it on starts somewhere sensible rather than at one.
    retries = policy.isEnabled ? policy.maxRetries : WebhookRetryPolicy.standard.maxRetries
    initialDelaySeconds = policy.initialDelaySeconds
  }

  /// What is saved.
  var policy: WebhookRetryPolicy {
    WebhookRetryPolicy(
      maxRetries: isEnabled ? retries : 0, initialDelaySeconds: initialDelaySeconds)
  }

  /// The waits on offer, including a stored one that is not among the standard set, so a
  /// value set some other way is shown rather than silently replaced on save.
  var delayOptions: [Int] {
    Self.standardDelays.contains(initialDelaySeconds)
      ? Self.standardDelays
      : (Self.standardDelays + [initialDelaySeconds]).sorted()
  }

  /// How a wait reads in the picker: "30 seconds", "5 minutes".
  static func label(seconds: Int) -> String {
    Duration.seconds(seconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
  }

  /// The waits between attempts, before jitter, one per retry.
  var delays: [Duration] {
    guard isEnabled, retries > 0 else { return [] }
    return (1...retries).map { policy.nominalDelay(afterFailures: $0) }
  }

  /// The whole schedule in one sentence, so the doubling is something a person can see
  /// rather than work out.
  var schedule: String {
    guard isEnabled else {
      return "A failed delivery is not tried again. The event is lost to this endpoint."
    }
    let waits = delays
      .map { $0.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) }
      .formatted(.list(type: .and))
    let total = delays.reduce(Duration.zero, +)
      .formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    return "Tried again after about \(waits), then given up on: roughly \(total) "
      + "after the first attempt."
  }
}

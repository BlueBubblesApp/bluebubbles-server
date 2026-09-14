//  WebhookDeliverySummary
//  What the Webhooks page says about an endpoint's last delivery.
//
//  Two rules, both on `WebhooksView` and neither tested. The matching rule is the one that
//  matters: a tracked outcome is claimed by a row only when the URL matches as well as the
//  id, because SQLite REUSES row ids after a delete and a previous endpoint's failure shown
//  against a newly added one is worse than showing nothing at all.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBEvents
import BBInterfaces
import Foundation

enum WebhookDeliverySummary {

  /// The tracked outcome for this row, if it belongs to it.
  ///
  /// Matched on the URL as well as the id, for the reason above. A row with no id has never
  /// been written and cannot own an outcome.
  static func delivery(
    for hook: Webhook, in deliveries: [Int64: WebhookDeliveryState]
  ) -> WebhookDeliveryState? {
    guard let id = hook.id, let state = deliveries[id], state.url == hook.url else {
      return nil
    }
    return state
  }

  /// One line describing that outcome.
  ///
  /// `now` is a parameter so the relative phrasing can be exercised at all; the wording
  /// itself belongs to `formatted` and the locale.
  static func describe(_ state: WebhookDeliveryState) -> String {
    let when = state.at.formatted(.relative(presentation: .numeric))
    switch state.outcome {
    case .delivered:
      return "Delivered \(when)"
    case .failed(let reason):
      // The streak is what separates "the endpoint blipped" from "this has been dead all
      // afternoon", and it is the same counter the alert fires on. Suppressed at one,
      // because "1 in a row" is not a streak and reads as a bug.
      let streak =
        state.consecutiveFailures > 1
        ? " · \(state.consecutiveFailures) in a row"
        : ""
      return "Failed \(when): \(reason)\(streak)"
    }
  }
}

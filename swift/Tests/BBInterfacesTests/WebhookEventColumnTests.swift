//  WebhookEventColumnTests
//  An `events` column that cannot be decoded is told apart from an empty one.
//
//  `subscribedEvents` answered `[]` for both, so a row whose stored list was damaged looked
//  like a webhook subscribed to nothing (a state `encode` never writes) and the endpoint
//  went quiet with no page saying why. `decodedEvents` is nil for the damaged row and the
//  webhooks page names it.

import Foundation
import Testing

@testable import BBInterfaces

@Suite("The webhook events column")
struct WebhookEventColumnTests {

  private func hook(events: String) -> Webhook {
    Webhook(id: 1, url: "https://example.invalid/hook", events: events, createdAt: Date())
  }

  @Test("A stored list decodes to itself")
  func decodes() {
    let stored = hook(events: Webhook.encode(events: ["new-message", "updated-message"]))
    #expect(stored.decodedEvents == ["new-message", "updated-message"])
    #expect(stored.subscribedEvents == ["new-message", "updated-message"])
  }

  @Test("No list is stored as everything, never as an empty list")
  func emptyMeansEverything() {
    #expect(Webhook.encode(events: []) == #"["*"]"#)
    #expect(hook(events: Webhook.encode(events: [])).decodedEvents == ["*"])
  }

  @Test("A damaged column is nil, and subscribes the endpoint to nothing")
  func damagedIsNil() {
    let damaged = hook(events: "not json at all")
    #expect(damaged.decodedEvents == nil)
    #expect(damaged.subscribedEvents.isEmpty)
  }
}

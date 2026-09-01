//  WebhookDirectory
//  Registered webhook endpoints: reading them for dispatch, and testing one on demand.
//
//  Two things that were methods on `AppContext` and are one cohesive job: the delivery path
//  needs the targets, and the settings page needs a "send a test" button that records its
//  outcome the same way a real delivery would.
//
//  It owns the delivery tracker, which is what made this worth a type rather than two loose
//  functions: the tracker must OUTLIVE the sink. `WebhookSink` is registered and unregistered
//  by a service, and a restart of that sink must not wipe the history the settings page is
//  showing — the page has no way to reach into the bus for it.

import BBDiagnostics
import BBEvents
import BBSerialization
import Foundation
import Logging

/// The registered webhooks, for dispatch and for the test button.
public struct WebhookDirectory: Sendable {

  private let repository: WebhookRepository
  private let codecs: CodecNegotiator
  private let logger: Logger

  /// What each webhook's last delivery did. Held here so it survives a sink restart.
  public let deliveries: WebhookDeliveryTracker

  public init(
    repository: WebhookRepository,
    codecs: CodecNegotiator,
    deliveries: WebhookDeliveryTracker,
    logger: Logger = Logger(label: "bluebubbles.webhooks")
  ) {
    self.repository = repository
    self.codecs = codecs
    self.deliveries = deliveries
    self.logger = logger
  }

  /// Webhook targets, with the events each is subscribed to.
  ///
  /// A failure gives back an empty list rather than propagating: the caller is the delivery
  /// path reacting to an event that has already happened, and there is nothing it can do
  /// about a database that would not read.
  public func targets() async -> [WebhookTarget] {
    do {
      return try await repository.targets()
    } catch {
      logger.warning(
        "Could not read webhook targets",
        metadata: ["error": .string(String(describing: error))])
      return []
    }
  }

  /// Delivers a test event to one registered webhook.
  ///
  /// Goes through `WebhookDelivery.send`, the same call real dispatch makes, and IGNORES the
  /// endpoint's subscription: this is a check of whether the URL answers, not of whether the
  /// filter is right, and refusing to test an endpoint subscribed to something narrow would
  /// make the button useless exactly where it is most wanted.
  ///
  /// The outcome is recorded like any other delivery, so the row updates the same way it
  /// would have if the event had arrived on its own.
  public func sendTest(id: Int64) async -> WebhookDeliveryState {
    guard let target = await targets().first(where: { $0.id == id }) else {
      return WebhookDeliveryState(
        outcome: .failed("That webhook is no longer registered"),
        at: Date(), consecutiveFailures: 0,
        event: EventName.helloWorld.rawValue, url: ""
      )
    }

    let event = WebhookDelivery.testEvent()
    do {
      try await WebhookDelivery.send(
        event, to: target, negotiator: codecs, transport: URLSessionPoster()
      )
      await deliveries.record(
        id: id, url: target.url, event: event.name.rawValue, outcome: .delivered
      )
    } catch {
      await deliveries.record(
        id: id, url: target.url, event: event.name.rawValue,
        outcome: .failed(WebhookDeliveryState.reason(for: error))
      )
    }

    return await deliveries.state(for: id)
      ?? WebhookDeliveryState(
        outcome: .delivered, at: Date(), consecutiveFailures: 0,
        event: event.name.rawValue, url: target.url
      )
  }
}

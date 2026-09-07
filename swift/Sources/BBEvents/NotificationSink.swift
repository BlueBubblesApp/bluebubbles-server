//  NotificationSink
//  One sink for every notification transport, and one place the routing policy is written.
//
//  Firebase and ntfy are the same KIND of thing: a way to reach a phone that is not currently
//  holding a socket open. They were two sinks, which meant two copies of the routing policy
//  and — because the copies drifted — two different answers to "which events do I get".
//  `PushSink` was `.push` routed; `NtfySink` was `.webhook` routed, so the same ntfy topic
//  received a different event set depending on whether it was configured as a webhook or
//  through its own settings. Only one of those can be right, and ntfy is a Firebase
//  replacement: someone configuring it is leaving Google, not subscribing a URL.
//
//  ## What belongs where
//
//  The SINK owns routing — which events reach notification transports at all. That is a
//  parity construct: `EventRouting.policy(for:)` transcribes the reference's per-event
//  `sendFcmMessage` argument, and it is not configurable, because it is a record of what the
//  reference does.
//
//  A PROVIDER owns everything about its own transport: encoding, credentials, retries, and
//  **its size limit**. Firebase's 4 KB is Google's number and lives in `FCMSender`; ntfy's is
//  whatever the operator configured; a webhook has none. A single number above this line was
//  wrong for all three, which is what it used to be.
//
//  See `docs/EVENTS.md`.

import Foundation
import Logging

/// Which events a provider is willing to receive.
///
/// Declared rather than inherited, for the reason `SinkRouting` has no default: silent
/// inheritance is the thing this design keeps replacing. A provider says what it wants.
public enum EventSubscription: Sendable, Equatable {
  /// Everything that reaches the sink.
  case all
  /// Everything except these. The shape a transport wants when it takes the general case
  /// and declines a few — Firebase's default is `.allExcept([.typingIndicator,
  /// .newFindMyLocation])`, and an event type invented later reaches it without anyone
  /// remembering to add it, which is how it behaves today.
  case allExcept(Set<EventName>)
  /// Only these. A `.only` list does NOT pick up a new event type, which is the point: a
  /// transport that enumerated what it wants should not silently start receiving more.
  case only(Set<EventName>)

  public func includes(_ name: EventName) -> Bool {
    switch self {
    case .all: true
    case .allExcept(let names): !names.contains(name)
    case .only(let names): names.contains(name)
    }
  }
}

/// One transport that can deliver a notification.
public protocol NotificationProvider: Sendable {
  /// For logs and for `unregister`. Distinct per transport.
  var providerID: String { get }
  /// What this transport wants. See `EventSubscription`.
  var subscription: EventSubscription { get }
  /// Whether it can send anything at all right now — configured, and with somewhere to send
  /// to. An unconfigured provider is an ordinary state, not a failure.
  var isReady: Bool { get async }
  /// Deliver, or throw. The sink logs and carries on: one dead transport must not stop the
  /// others, which is the whole reason they are behind one sink rather than chained.
  func send(_ event: ServerEvent) async throws
}

/// The sink the bus sees. Providers are attached as their services start.
public actor NotificationSink: EventSink {

  public nonisolated let id = SinkID.push
  public nonisolated let routing = SinkRouting.push
  /// The smaller CONTENT shape — participants included, no notion of size. Size is each
  /// provider's own business; see the header.
  public nonisolated let projection = PayloadProjection.notification

  private var providers: [String: any NotificationProvider] = [:]
  private let logger: Logger

  public init(logger: Logger = Logger(label: "bluebubbles.notifications")) {
    self.logger = logger
  }

  /// Attached rather than injected, because the services that own the transports start
  /// independently and at different times — Firebase after its credentials load, ntfy after
  /// its settings are read. Re-attaching replaces, so a restart does not double-send.
  public func attach(_ provider: any NotificationProvider) {
    providers[provider.providerID] = provider
    logger.debug(
      "Notification provider attached",
      metadata: ["provider": .string(provider.providerID)])
  }

  public func detach(providerID: String) {
    providers.removeValue(forKey: providerID)
  }

  public var attachedProviderIDs: Set<String> { Set(providers.keys) }

  public nonisolated func accepts(_ event: ServerEvent) async -> Bool {
    await hasReadyProvider(for: event)
  }

  private func hasReadyProvider(for event: ServerEvent) async -> Bool {
    for provider in providers.values where provider.subscription.includes(event.name) {
      if await provider.isReady { return true }
    }
    return false
  }

  public nonisolated func deliver(_ event: ServerEvent) async throws {
    try await fanOut(event)
  }

  private func fanOut(_ event: ServerEvent) async throws {
    for provider in providers.values.sorted(by: { $0.providerID < $1.providerID }) {
      guard provider.subscription.includes(event.name) else { continue }
      guard await provider.isReady else { continue }
      do {
        try await provider.send(event)
      } catch {
        // Logged, not rethrown. A provider that is down must not stop the others — the
        // bus would see one throw and the user would lose every notification transport
        // because one of them had an expired token.
        logger.warning(
          "A notification provider failed",
          metadata: [
            "provider": .string(provider.providerID),
            "event": .string(event.name.rawValue),
            "error": .string(String(describing: error)),
          ])
      }
    }
  }
}

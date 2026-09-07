//  PushSink
//  The adapter that makes push an event sink.
//
//  `PushService` knows how to send a notification and `EventBus` knows how to fan out an
//  event, and until this existed nothing joined them: the bus had exactly one sink registered
//  — the socket — so every FCM notification the server would have sent was simply never sent.
//  Nothing failed. Push was configured, `server/info` reported it active, and Android clients
//  received nothing unless they happened to hold a socket open.
//
//  Deliberately a separate type rather than making `PushService` conform to `EventSink`, for
//  the same reason `SocketSink` is separate: the service is usable on its own — setup sends a
//  test notification, the restart watcher publishes a URL — and dragging the sink protocol
//  into it would make every one of those callers depend on the event layer.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBEvents
import BBSerialization
import Foundation
import Logging

public struct FirebaseProvider: NotificationProvider {

  public let providerID = "firebase"
  public let subscription: EventSubscription

  /// What the reference sends over FCM: everything except two.
  ///
  /// Transcribed from `emitMessage(type, data, priority, sendFcmMessage: false)` at the two
  /// call sites that pass `false`:
  ///
  /// - `typing-indicator` — a typing indicator delivered through push would arrive after the
  ///   message it was announcing, which is worse than not sending it.
  /// - `new-findmy-location` — location updates arrive in bursts and would burn FCM quota.
  ///
  /// It lives here rather than in `EventRouting` because it is a fact about FIREBASE, not
  /// about notifications: the reference delivers both events to webhooks, and ntfy — a
  /// webhook under v1 — received them. Applied at the bus, it silently took them away from
  /// every other transport too.
  ///
  /// `.allExcept` and not `.only`, so an event type added later reaches FCM without anyone
  /// remembering to list it. That is how it behaves today.
  public static let referenceSubscription = EventSubscription.allExcept([
    .typingIndicator, .newFindMyLocation,
  ])

  private let service: PushService
  private let tokens: @Sendable () async -> [String]
  private let negotiator: CodecNegotiator
  private let logger: Logger

  public init(
    service: PushService,
    tokens: @escaping @Sendable () async -> [String],
    negotiator: CodecNegotiator = .legacyOnly(),
    subscription: EventSubscription = FirebaseProvider.referenceSubscription,
    logger: Logger = Logger(label: "bluebubbles.push.firebase")
  ) {
    self.subscription = subscription
    self.service = service
    self.tokens = tokens
    self.negotiator = negotiator
    self.logger = logger
  }

  /// Configured, with somewhere to send. Both are ordinary states — a socket-only install
  /// is a supported deployment, not a broken one.
  public var isReady: Bool {
    get async {
      guard await service.isConfigured else { return false }
      return await !tokens().isEmpty
    }
  }

  public func send(_ event: ServerEvent) async throws {
    let devices = await tokens()
    guard !devices.isEmpty else { return }

    // Every registered device is on `legacy-v1` unless it advertised otherwise, and the
    // negotiator resolves to the ceiling the operator set. Device-specific capabilities
    // would mean one send per capability group; that only becomes worth it when a
    // non-legacy codec is actually enabled, and this resolves to legacy until then.
    let codec = negotiator.resolve(for: .legacy)
    // `.notification` here rather than from a sink property: the codec is FIREBASE's
    // business — `legacy-v1`, `reference-v2` and `sealed-v2` describe what the BlueBubbles
    // client app can parse, which is nothing to do with ntfy or a webhook. It moved down
    // here with the size limit, for the same reason.
    let encoded = try await codec.encode(
      event, projection: .notification, capabilities: .legacy
    )

    // `{ type, data }`, with `data` a JSON STRING rather than an object.
    //
    // FCM data payloads are string-to-string maps, so the nesting has to be flattened
    // somewhere. The current server flattens it here — `{ type, data: JSON.stringify(d) }`
    // — and every shipped client parses that shape. Sending a structured payload would
    // be tidier and would break all of them.
    guard let serialized = String(data: try encoded.body.serialize(), encoding: .utf8) else {
      logger.warning(
        "Could not serialize a notification payload",
        metadata: [
          "event": .string(event.name.rawValue)
        ])
      return
    }

    await service.send(
      data: ["type": event.name.rawValue, "data": serialized],
      to: devices,
      priority: event.priority == .high ? .high : .normal
    )
  }
}

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

public struct PushSink: EventSink {

  public let id = SinkID.push
  /// The TRIMMED payload. The socket takes `.full`; FCM has a 4 KB limit and a full
  /// message body with its attachments will not fit. Mixing these up is the single most
  /// likely way to break clients while every test still passes.
  public let projection = PayloadProjection.notification

  private let service: PushService
  private let tokens: @Sendable () async -> [String]
  private let negotiator: CodecNegotiator
  private let logger: Logger

  public init(
    service: PushService,
    tokens: @escaping @Sendable () async -> [String],
    negotiator: CodecNegotiator = .legacyOnly(),
    logger: Logger = Logger(label: "bluebubbles.push.sink")
  ) {
    self.service = service
    self.tokens = tokens
    self.negotiator = negotiator
    self.logger = logger
  }

  public func accepts(_ event: ServerEvent) async -> Bool {
    // Suppression by event type is `EventRouting`'s job and is applied by the bus before
    // this is called. What is left is the only question this sink can answer: is push
    // configured, and is anything registered to receive it. Both are ordinary states —
    // a socket-only install is a supported deployment, not a broken one.
    guard await service.isConfigured else { return false }
    return await !tokens().isEmpty
  }

  public func deliver(_ event: ServerEvent) async throws {
    let devices = await tokens()
    guard !devices.isEmpty else { return }

    // Every registered device is on `legacy-v1` unless it advertised otherwise, and the
    // negotiator resolves to the ceiling the operator set. Device-specific capabilities
    // would mean one send per capability group; that only becomes worth it when a
    // non-legacy codec is actually enabled, and this resolves to legacy until then.
    let codec = negotiator.resolve(for: .legacy)
    let encoded = try await codec.encode(
      event, projection: projection, capabilities: .legacy
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

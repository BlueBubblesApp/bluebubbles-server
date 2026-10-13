//  RecordingSink
//  An event sink that keeps what the bus delivered to it.
//
//  Three copies existed, each keeping a different slice (the names, the payloads, the
//  events) under a different name, and one of them called its list of whole events by the
//  name another used for a list of event names. This keeps all three, so a test reads the
//  one it asserts on.

import BBCore
import BBEvents

public actor RecordingSink: EventSink {
  public nonisolated let id: SinkID
  public nonisolated let projection: PayloadProjection
  public nonisolated let routing: SinkRouting

  /// Every event delivered, in order.
  public private(set) var events: [ServerEvent] = []
  /// Each delivered event's payload, in this sink's projection, taken at delivery.
  public private(set) var payloads: [JSONValue] = []
  private var delay: Duration?

  /// The routing class defaults to the one the real sink of that name declares, so a double
  /// standing in for push is subject to push's suppressions. Pass it explicitly to test a
  /// sink whose class does not match its name.
  public init(
    id: SinkID,
    projection: PayloadProjection = .notification,
    routing: SinkRouting? = nil
  ) {
    self.id = id
    self.projection = projection
    self.routing = routing ?? Self.conventionalRouting(for: id)
  }

  private static func conventionalRouting(for id: SinkID) -> SinkRouting {
    switch id {
    case .socket: .socket
    case .push: .push
    default: .webhook
    }
  }

  public func accepts(_ event: ServerEvent) async -> Bool { true }

  public func deliver(_ event: ServerEvent) async throws {
    if let delay { try await Task.sleep(for: delay) }
    events.append(event)
    payloads.append(event.payload(for: projection))
  }

  /// Makes every later delivery take this long, to stand in for a slow subscriber.
  public func setDelay(_ duration: Duration?) { delay = duration }

  /// The names of the events delivered, in order.
  public func names() -> [EventName] { events.map(\.name) }
}

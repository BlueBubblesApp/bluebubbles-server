//  ServerAddressAnnouncer
//  Tells clients where this server now lives — once per actual change.
//
//  Two deliveries, and they are not interchangeable. The socket event reaches clients that
//  are connected RIGHT NOW; the Firebase document is what a client reads when it comes back
//  later and needs to know where this machine went. A tunnel that reconnects with a new URL
//  while every client is asleep is exactly the case where only the second one helps, and it
//  is the common case for ngrok.

import BBEvents
import Foundation
import Logging

public actor ServerAddressAnnouncer {

  private let events: EventBus
  private let logger: Logger
  private var lastAnnounced: String?

  public init(events: EventBus, logger: Logger) {
    self.events = events
    self.logger = logger
  }

  /// Announces `serverAddress` if it differs from the last one announced.
  ///
  /// Only on an actual change: `onAddressChanged` fires on every tunnel connect, including
  /// a reconnect to a reserved name or a custom domain that comes back on the SAME address,
  /// and a settings write broadcasts whether or not the value moved. Without this, a routine
  /// tunnel refresh tells every client the server moved somewhere it did not.
  ///
  /// - Parameter publish: The durable half — the Firebase document. Called after the socket
  ///   event, and only when there was a change to publish.
  /// - Returns: Whether anything was announced.
  @discardableResult
  public func announce(
    _ serverAddress: String,
    publish: @Sendable (String) async -> Void
  ) async -> Bool {
    let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty, address != lastAnnounced else { return false }
    lastAnnounced = address

    logger.info("Announcing a new server address")
    await events.emit(
      ServerEvent(
        name: .newServer,
        // A bare string, matching `emitMessage(NEW_SERVER, server_address, "high")`.
        // Wrapping it in an object would be tidier and would break every client that
        // reads the payload as the address itself.
        fullPayload: .string(address),
        priority: .high
      )
    )
    await publish(address)
    return true
  }
}

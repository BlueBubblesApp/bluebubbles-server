//  SocketTransport+Sending
//  Requests out: correlating each with its reply through `TransactionStore`, choosing the
//  ONE helper an action goes to, and writing the length-prefixed frame. Never a broadcast;
//  see `write`.
//
//  One slice of `SocketTransport`; the type, its stored state and the subscriber streams are
//  in `SocketTransport.swift`.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging
import NIOCore

extension SocketTransport {

  @discardableResult
  public func request(
    action: String,
    data: WireJSON,
    timeout: Duration
  ) async throws -> WireJSON? {
    try await request(action: action, data: data, timeout: timeout, process: nil)
  }

  @discardableResult
  public func request(
    action: String,
    data: WireJSON,
    timeout: Duration,
    process: String?
  ) async throws -> WireJSON? {
    let transactionId = UUID().uuidString
    // The first eight characters identify the attempt in a log without the whole UUID;
    // `data` is the payload and never appears: it carries the chat, the text, the paths.
    let tx = Logger.MetadataValue.string(String(transactionId.prefix(8)))
    logger.debug(
      "Private API request",
      metadata: [
        "action": .string(action),
        "tx": tx,
        "process": .string(process ?? "any"),
      ])
    let started = ContinuousClock.now
    defer { connections.finished(transactionId) }
    do {
      // The write is handed to the store so it happens AFTER the continuation is
      // registered. Sending first is a race the helper wins on any reply it can produce
      // immediately.
      let reply = try await transactions.await(
        id: transactionId, action: action, timeout: timeout
      ) { [weak self] in
        guard let self else { return }
        try await self.write(
          action: action, data: data, transactionId: transactionId, process: process
        )
      }
      logger.debug(
        "Private API reply",
        metadata: [
          "action": .string(action),
          "tx": tx,
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        ])
      return reply
    } catch let error as PrivateAPIError {
      if case .timedOut = error {
        // Warning, because the default is two minutes and a caller sat through all of it.
        logger.warning(
          "Private API request timed out",
          metadata: [
            "action": .string(action),
            "tx": tx,
            "timeoutS": .stringConvertible(Int(timeout.seconds)),
          ])
      } else {
        logger.debug(
          "Private API request failed",
          metadata: [
            "action": .string(action),
            "tx": tx,
            "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
            "error": .string(Redaction.identifiers(in: String(describing: error))),
          ])
      }
      throw error
    } catch {
      logger.debug(
        "Private API request failed",
        metadata: [
          "action": .string(action),
          "tx": tx,
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
          "error": .string(Redaction.identifiers(in: String(describing: error))),
        ])
      throw error
    }
  }

  public func send(action: String, data: WireJSON) async throws {
    try await write(action: action, data: data, transactionId: nil, process: nil)
  }

  /// Sends an action to exactly ONE helper.
  ///
  /// NEVER a broadcast to every connected client. The helper reconnects whenever the server
  /// restarts while Messages keeps running, so a second live connection from the SAME
  /// Messages process is the ordinary state: writing to all of them executes every action
  /// twice. Measured: three API calls produced six messages in chat.db, which means a real
  /// person received everything twice.
  ///
  /// The newest connection wins, because a reconnect means the older one is on its way out.
  /// A dead connection is dropped where it is found, through `drop`, rather than swept
  /// separately.
  ///
  /// `process` targets a SPECIFIC helper by the bundle id it registered with. A FaceTime
  /// action must reach the FaceTime helper, not whichever registered most recently: with
  /// both a Messages and a FaceTime helper on one socket, "most recent" is a coin toss.
  /// When a target is named but not connected, this fails rather than misrouting to the
  /// wrong helper, because silently sending a FaceTime action to Messages produces a
  /// confusing "unavailable" rather than an honest "the FaceTime helper is not connected."
  private func write(
    action: String, data: WireJSON, transactionId: String?, process: String?
  ) async throws {
    let payload = try JSONEncoder().encode(
      HelperRequest(action: action, data: data, transactionId: transactionId)
    )
    guard payload.count <= LengthPrefixedFrameHandler.maximumFrameBytes else {
      throw PrivateAPIError.rejectedByMessages(reason: "request exceeds the frame limit")
    }

    // Targeted: exactly the named helper, or a clear failure.
    if let process {
      guard let target = connections.connection(registeredAs: process) else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "the \(process) helper is not connected"
        )
      }
      guard await deliver(payload, to: target, transactionId: transactionId) else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "the \(process) helper connection dropped"
        )
      }
      return
    }

    // UNTARGETED. Every inherited action (sending, reactions, availability, chat edits)
    // belongs to the Messages helper; only the FaceTime routes name a process, and they
    // always do. Falling through to "most recently connected" would land those actions on
    // whichever helper registered last, so with both injected a plain
    // `check-facetime-availability` would come back as `unknown action` from the FaceTime
    // helper. Prefer Messages explicitly. The most-recent chain is the fallback for a helper
    // that has connected and not yet registered, and it never reaches a connection on
    // another app's socket: that helper cannot answer a Messages action.
    logger.debug(
      "Routing untargeted request",
      metadata: [
        "action": .string(action),
        "registered": .string(connections.processes.sorted().joined(separator: ",")),
        "clients": .stringConvertible(connections.count),
      ])
    if let messages = connections.connection(registeredAs: HelperHost.messages),
      await deliver(payload, to: messages, transactionId: transactionId)
    {
      return
    }

    // A dead connection is dropped by `deliver` and the next most recent tried rather than
    // failing: a helper mid-reconnect is a normal, recoverable state.
    while let newest = connections.newest(servingUntargeted: true) {
      if await deliver(payload, to: newest, transactionId: transactionId) {
        return
      }
    }
    throw PrivateAPIError.notConnected
  }

  /// Writes one length-prefixed frame to one connection, and answers whether it left.
  ///
  /// A write that fails means the connection is gone, so it is dropped here, through `drop`,
  /// and the caller decides only what to try next. The transaction is recorded against the
  /// connection BEFORE the bytes leave, so a reply fast enough to finish the request first
  /// cannot leave a stale id behind, and is taken back off if the write fails: the caller
  /// tries another connection or fails the transaction itself, and this one never carried
  /// it.
  private func deliver(
    _ payload: Data, to target: HelperConnections<any Channel>.Entry, transactionId: String?
  ) async -> Bool {
    let (key, channel) = (target.key, target.connection)
    var buffer = channel.allocator.buffer(capacity: payload.count + 4)
    buffer.writeInteger(UInt32(payload.count), endianness: .big)
    buffer.writeBytes(payload)
    if let transactionId { connections.carrying(transactionId, on: key) }
    do {
      try await channel.writeAndFlush(buffer).get()
      return true
    } catch {
      if let transactionId { connections.finished(transactionId) }
      logger.debug(
        "Dropping a dead helper connection",
        metadata: ["error": .string(Redaction.identifiers(in: String(describing: error)))])
      drop(key)
      return false
    }
  }
}

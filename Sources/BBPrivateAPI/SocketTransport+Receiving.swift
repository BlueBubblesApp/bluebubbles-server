//  SocketTransport+Receiving
//  Frames in: the length-prefixed framing on the event loop, the one lane that drains
//  frames in arrival order, and the decoding that resolves a reply or announces an event.
//
//  One slice of `SocketTransport`; the type, its stored state and the subscriber streams are
//  in `SocketTransport.swift`.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging
import NIOCore

extension SocketTransport {

  /// The frame lane, opened on first use. Idempotent: every connection shares one.
  func openFrameLane() -> AsyncStream<InboundFrame>.Continuation {
    if let frames { return frames }
    let (stream, continuation) = AsyncStream<InboundFrame>.makeStream(
      bufferingPolicy: .unbounded)
    frames = continuation
    frameDrain.run { [weak self] in
      for await frame in stream {
        await self?.handle(frame: frame.payload, from: frame.channel)
      }
    }
    return continuation
  }

  private func handle(frame: Data, from channel: any Channel) {
    guard let response = try? JSONDecoder().decode(HelperResponse.self, from: frame) else {
      undecodable(frame)
      return
    }

    if let transactionId = response.transactionId {
      if let failure = response.failure {
        Task { await transactions.fail(id: transactionId, with: failure) }
      } else {
        let result = response.result
        Task { await transactions.resolve(id: transactionId, with: result) }
      }
      return
    }

    guard let name = response.event else { return }
    if name == HelperEventName.ping.rawValue,
      let process = response.remainder[.process]?.stringValue, !process.isEmpty
    {
      if let socketServes = connections.register(process, on: ObjectIdentifier(channel)) {
        // The helper names a different app from the one its socket serves. Nothing is
        // registered, the registration is not announced, and the connection is closed:
        // routing on that name would hand it the other app's actions.
        logger.error(
          "Helper registered as a different app from the one its socket serves; closing it",
          metadata: ["process": .string(process), "socket": .string(socketServes)])
        channel.close(promise: nil)
        return
      }
      logger.info("Helper registered", metadata: ["process": .string(process)])
    }
    guard let event = HelperEventDecoder.decode(name: name, payload: response.remainder) else {
      logger.debug("Unhandled helper event", metadata: ["event": .string(name)])
      return
    }
    for continuation in subscribers.values {
      continuation.yield(event)
    }
  }

  /// A frame that did not decode. When it was a REPLY, its caller is failed now.
  ///
  /// Dropping it is the failure this prevents: the request it answered stays pending, and
  /// its caller waits out the whole timeout (two minutes by default) for a reply that has
  /// already arrived and been thrown away. When the transaction id can still be read, that
  /// request fails at once with `protocolMismatch`, which is what an unreadable reply from
  /// our own helper is: a server and a helper that do not agree on the protocol. Anything
  /// else (an event, or bytes with no id in them) has no caller to tell and is logged.
  fileprivate func undecodable(_ frame: Data) {
    guard let transactionId = Self.recoverTransactionId(from: frame) else {
      logger.warning(
        "Undecodable frame from helper", metadata: ["bytes": .stringConvertible(frame.count)])
      return
    }
    logger.warning(
      "Undecodable reply from helper; failing its request",
      metadata: [
        "tx": .string(String(transactionId.prefix(8))),
        "bytes": .stringConvertible(frame.count),
      ])
    let error = PrivateAPIError.protocolMismatch("the helper's reply could not be decoded")
    Task { await transactions.fail(id: transactionId, with: error) }
  }

  /// The transaction id in a frame that did not decode as a `HelperResponse`, or nil.
  ///
  /// Two attempts, because a frame fails to decode in two ways. Valid JSON whose values do
  /// not fit (`HelperResponse` decodes every value as `WireJSON`) still parses as an object,
  /// and the id is a key in it. A frame that is not JSON at all (cut short, or not UTF-8)
  /// still carries the id as written if the writer got that far, so its text is searched
  /// for the key and its string value.
  static func recoverTransactionId(from frame: Data) -> String? {
    let key = WireKey.transactionId.rawValue
    if let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] {
      guard let id = object[key] as? String, !id.isEmpty else { return nil }
      return id
    }
    let text = String(decoding: frame, as: UTF8.self)
    // `"<key>"`, a colon, then a quoted string with no escapes in it: a UUID's alphabet.
    let pattern =
      "\"" + NSRegularExpression.escapedPattern(for: key) + #""\s*:\s*"([^"\\]+)""#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}

/// 4-byte big-endian length, then that many bytes of JSON.
///
/// Chosen over newline framing because both ends are ours: there is no delimiter for a
/// payload to accidentally contain, the length is known before the body is read, and an
/// oversized frame is rejected before it is buffered rather than after.
final class LengthPrefixedFrameHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  static let maximumFrameBytes = 64 * 1024 * 1024

  private var buffer = Data()
  private let onFrame: @Sendable (Data, any Channel) -> Void
  private let onClose: @Sendable (any Channel) -> Void
  private let logger: Logger

  init(
    onFrame: @escaping @Sendable (Data, any Channel) -> Void,
    onClose: @escaping @Sendable (any Channel) -> Void,
    logger: Logger
  ) {
    self.onFrame = onFrame
    self.onClose = onClose
    self.logger = logger
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var incoming = unwrapInboundIn(data)
    buffer.append(contentsOf: incoming.readBytes(length: incoming.readableBytes) ?? [])

    while buffer.count >= 4 {
      let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard length <= Self.maximumFrameBytes else {
        logger.error(
          "Helper announced an oversized frame; closing the connection",
          metadata: [
            "bytes": .stringConvertible(length)
          ])
        context.close(promise: nil)
        return
      }
      let total = 4 + Int(length)
      guard buffer.count >= total else { return }

      let frame = buffer[
        buffer.index(
          buffer.startIndex, offsetBy: 4)..<buffer.index(buffer.startIndex, offsetBy: total)]
      buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: total))
      onFrame(Data(frame), context.channel)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    onClose(context.channel)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    logger.debug("Helper socket error", metadata: ["error": .string(Redaction.error(error))])
    context.close(promise: nil)
  }
}

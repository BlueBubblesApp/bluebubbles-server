//  FakeHelper
//  A stand-in for the injected dylib, speaking the legacy wire protocol over real TCP.
//
//  Real sockets rather than an in-memory double, because the things worth testing here are
//  exactly the ones a double would paper over: frames split across packet boundaries, several
//  frames arriving in one read, and a disconnect stranding outstanding transactions.

import Foundation
import NIOCore
import NIOPosix

/// A helper that connects to the bridge and answers whatever it is told to.
final class FakeHelper: @unchecked Sendable {

  private let group: any EventLoopGroup
  private var channel: (any Channel)?
  private let handler = Handler()

  init(group: any EventLoopGroup) {
    self.group = group
  }

  /// Frames received from the server, in order.
  var received: [[String: Any]] { handler.received }

  func connect(port: Int) async throws {
    let handler = handler
    channel = try await ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.pipeline.addHandler(handler)
      }
      .connect(host: "127.0.0.1", port: port)
      .get()
  }

  func disconnect() async throws {
    try await channel?.close().get()
    channel = nil
  }

  /// Writes raw bytes, so a test can split a frame wherever it likes.
  func writeRaw(_ bytes: [UInt8]) async throws {
    guard let channel else { return }
    var buffer = channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    try await channel.writeAndFlush(buffer).get()
  }

  func write(json: [String: Any], terminated: Bool = true) async throws {
    var data = try JSONSerialization.data(withJSONObject: json)
    if terminated { data.append(0x0A) }
    try await writeRaw([UInt8](data))
  }

  /// Waits for a frame carrying a transaction id and returns it.
  func awaitTransactionId(timeout: Duration = .seconds(5)) async throws -> String {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let id = handler.received.compactMap({ $0["transactionId"] as? String }).first {
        return id
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    struct NoTransaction: Error {}
    throw NoTransaction()
  }

  final class Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var storage: [[String: Any]] = []
    private var buffer = Data()

    var received: [[String: Any]] {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      var incoming = unwrapInboundIn(data)
      let bytes = incoming.readBytes(length: incoming.readableBytes) ?? []
      lock.lock()
      defer { lock.unlock() }
      buffer.append(contentsOf: bytes)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let frame = Data(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        if let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] {
          storage.append(object)
        }
      }
    }
  }
}

/// A port unlikely to collide with a running server or another test.
func ephemeralPort() -> Int { Int.random(in: 49_200...49_900) }

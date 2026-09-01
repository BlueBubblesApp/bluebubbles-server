//  SocketTransportTests
//  The Swift helper's transport: framing, and who is allowed to connect.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Darwin
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import BBPrivateAPI

/// A helper speaking the length-prefixed protocol over a Unix-domain socket.
private final class FakeSocketHelper: @unchecked Sendable {

  private let group: any EventLoopGroup
  private var channel: (any Channel)?
  let handler = Handler()

  init(group: any EventLoopGroup) { self.group = group }

  func connect(path: String) async throws {
    let handler = handler
    channel = try await ClientBootstrap(group: group)
      .channelInitializer { $0.pipeline.addHandler(handler) }
      .connect(unixDomainSocketPath: path)
      .get()
  }

  func disconnect() async throws {
    try await channel?.close().get()
    channel = nil
  }

  func write(json: [String: Any]) async throws {
    guard let channel else { return }
    let body = try JSONSerialization.data(withJSONObject: json)
    var buffer = channel.allocator.buffer(capacity: body.count + 4)
    buffer.writeInteger(UInt32(body.count), endianness: .big)
    buffer.writeBytes(body)
    try await channel.writeAndFlush(buffer).get()
  }

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

    var received: [[String: Any]] { lock.withLock { storage } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      var incoming = unwrapInboundIn(data)
      let bytes = incoming.readBytes(length: incoming.readableBytes) ?? []
      lock.withLock {
        buffer.append(contentsOf: bytes)
        while buffer.count >= 4 {
          let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
          guard buffer.count >= 4 + length else { return }
          let body = Data(
            buffer[
              buffer.index(
                buffer.startIndex, offsetBy: 4)..<buffer.index(
                  buffer.startIndex, offsetBy: 4 + length)])
          buffer.removeSubrange(
            buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: 4 + length))
          if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            storage.append(object)
          }
        }
      }
    }
  }
}

private func temporarySocketPath() -> String {
  NSTemporaryDirectory() + "bb-socket-\(UUID().uuidString.prefix(8)).sock"
}

@Suite("Socket transport", .serialized)
struct SocketTransportTests {

  /// The socket lives in a `0700` directory so reachability is settled by filesystem
  /// permission before any code-signature check is reached.
  @Test("The socket file is owner-only")
  func permissions() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let path = NSTemporaryDirectory() + "bb-perm-\(UUID().uuidString.prefix(8))/private-api.sock"
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    let directory = (path as NSString).deletingLastPathComponent
    let socketMode =
      try FileManager.default
      .attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber

    // The SOCKET is 0600. The directory deliberately is not touched: in the shipping
    // configuration it is Messages.app's own container, and chmod-ing a system app's
    // container to suit us would be overreach. The socket's own mode, plus the sandbox
    // rules that make the container reachable only from inside Messages, are what
    // protect it.
    #expect(socketMode?.int16Value == 0o600)

    await transport.stop()
    try? FileManager.default.removeItem(atPath: directory)
    try? await group.shutdownGracefully()
  }

  /// A socket file left behind by a crashed process makes `bind` fail with EADDRINUSE,
  /// which reads as "a server is already running" when none is.
  @Test("A stale socket file does not block startup")
  func staleSocketIsCleared() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let path = temporarySocketPath()
    FileManager.default.createFile(atPath: path, contents: Data())

    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    await #expect(throws: Never.self) { try await transport.start() }
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  @Test("A length-prefixed request and reply round-trip")
  func roundTrip() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    let helper = FakeSocketHelper(group: group)
    try await helper.connect(path: path)
    for _ in 0..<200 where await !transport.isConnected {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await transport.isConnected)

    let response = Task {
      try await transport.request(
        action: "get-account-info", data: .object([:]), timeout: .seconds(5)
      )
    }
    let id = try await helper.awaitTransactionId()
    try await helper.write(json: ["transactionId": id, "appleId": "someone@example.com"])

    let result = try await response.value
    #expect(result?["appleId"]?.stringValue == "someone@example.com")

    try await helper.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// The security property. A peer that cannot satisfy the requirement is closed before it
  /// has sent a single frame — the test binary is ad-hoc signed, so it cannot satisfy
  /// `anchor apple`, which makes it a genuine rejection rather than a simulated one.
  @Test("A peer that fails the code requirement is refused")
  func untrustedPeerIsRefused() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path,
      validator: CodeSignaturePeerValidator(requirement: "anchor apple"),
      group: group
    )
    try await transport.start()

    let helper = FakeSocketHelper(group: group)
    // Connecting succeeds — the refusal happens on our side, after the accept.
    try? await helper.connect(path: path)
    try await Task.sleep(for: .milliseconds(300))

    #expect(await !transport.isConnected)

    try? await helper.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }
}

@Suite("Peer identity")
struct PeerIdentityTests {

  /// Identity is checked by AUDIT TOKEN, not by pid, and this is why: an audit token
  /// carries the pid generation as well as the pid. A pid on its own can be recycled
  /// between the moment it is read and the moment the Security framework is asked about it,
  /// so a check that passes may describe a process that has already exited.
  @Test("An audit token carries the pid and its generation")
  func auditTokenCarriesGeneration() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    let status = withUnsafeMutablePointer(to: &token) {
      getsockopt(fds[0], SOL_LOCAL, LOCAL_PEERTOKEN, $0, &length)
    }
    #expect(status == 0)
    #expect(length == 32)

    let identity = PeerIdentity(auditToken: token)
    #expect(identity.pid == getpid())

    // Word 7 is the pid generation. A recycled pid gets a different one, which is the
    // whole reason the token is used instead of the bare number.
    let words = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
    #expect(words.count == 8)
    #expect(words[7] != 0)
  }

  /// Ad-hoc signed test binaries cannot satisfy `anchor apple`, so this is a real check.
  @Test("The validator rejects a peer that does not meet the requirement")
  func validatorRejects() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    _ = withUnsafeMutablePointer(to: &token) {
      getsockopt(fds[0], SOL_LOCAL, LOCAL_PEERTOKEN, $0, &length)
    }

    let validator = CodeSignaturePeerValidator(requirement: "anchor apple")
    #expect(throws: PeerValidationError.self) {
      try validator.validate(PeerIdentity(auditToken: token))
    }
  }

  @Test("A malformed requirement is reported rather than silently accepting everyone")
  func malformedRequirement() throws {
    let validator = CodeSignaturePeerValidator(requirement: "this is not a requirement (((")
    #expect(throws: PeerValidationError.invalidRequirement("this is not a requirement (((")) {
      try validator.validate(PeerIdentity(auditToken: audit_token_t()))
    }
  }
}

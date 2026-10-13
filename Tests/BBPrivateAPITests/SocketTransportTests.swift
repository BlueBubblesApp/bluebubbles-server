//  SocketTransportTests
//  The Swift helper's transport: framing, and who is allowed to connect.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBPrivateAPIContract
import BBTestSupport
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

  /// One frame carrying exactly `body`, for bytes that are not a JSON object.
  func write(raw body: Data) async throws {
    guard let channel else { return }
    var buffer = channel.allocator.buffer(capacity: body.count + 4)
    buffer.writeInteger(UInt32(body.count), endianness: .big)
    buffer.writeBytes(body)
    try await channel.writeAndFlush(buffer).get()
  }

  func awaitTransactionId(timeout: Duration = .seconds(5)) async throws -> String {
    try await waitFor("a frame carrying a transaction id", timeout: timeout) {
      handler.received.compactMap { $0["transactionId"] as? String }.first
    }
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
    try await waitUntil("the helper to connect") { await transport.isConnected }
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
  /// has sent a single frame; the test binary is ad-hoc signed, so it cannot satisfy
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
    // Connecting succeeds; the refusal happens on our side, after the accept.
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

/// Returns the first `count` events a subscription yields, or however many arrived in time.
///
/// Same deadline discipline as `firstEvent`: an event that never arrives has to fail the test
/// rather than hang it, and a short count on the way out is more useful than a timeout with
/// nothing to show.
private func events(
  in stream: AsyncStream<PrivateAPIEvent>,
  count: Int,
  timeout: Duration = .seconds(10)
) async -> [PrivateAPIEvent] {
  let collected = Locked<[PrivateAPIEvent]>([])
  let drain = Task {
    for await event in stream {
      let total = collected.withLock { events in
        events.append(event)
        return events.count
      }
      if total == count { break }
    }
  }
  defer { drain.cancel() }
  // `try?`: a shortfall is what the caller's count assertion reports, with what did arrive.
  try? await waitUntil("\(count) event(s)", timeout: timeout) { collected.value.count >= count }
  return collected.value
}

/// Returns the first event a subscription yields, or nil if none arrives in time.
///
/// A timeout rather than an open `for await`: the failure this guards against is an event
/// that never arrives, and without a deadline that failure is a hung test rather than a
/// red one.
private func firstEvent(
  in stream: AsyncStream<PrivateAPIEvent>,
  timeout: Duration = .seconds(5)
) async -> PrivateAPIEvent? {
  // `try?`: a `TimedOut` is the nil the caller's assertion reports.
  try? await withTimeout(timeout) { () -> PrivateAPIEvent? in
    for await event in stream { return event }
    return nil
  }
}

@Suite("Private API event fan-out")
struct PrivateAPIEventFanOutTests {

  /// The regression. There are two consumers of this stream in the shipping server: the
  /// runtime waiting for `helperRegistered` to confirm an injection took, and the service
  /// that forwards everything to the event bus, and for a while both iterated ONE
  /// `AsyncStream`. An `AsyncStream` hands each element to a single waiting iterator, so the
  /// two loops split the events between them: the registration wait timed out while the
  /// helper was plainly connected, and typing indicators reached clients only sometimes.
  ///
  /// Which loop won was a race, which is why it presented as flakiness rather than a
  /// reproducible failure. Two subscribers, one event, both must see it.
  @Test("Every subscriber receives every event")
  func everySubscriberSeesEveryEvent() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    // Both subscriptions are taken BEFORE the event is sent. The buffering is unbounded, so
    // this pins the fan-out and not merely the timing of two readers.
    let runtimeStream = await transport.events
    let busStream = await transport.events
    #expect(await transport.subscriberCount == 2)

    let helper = FakeSocketHelper(group: group)
    try await helper.connect(path: path)
    try await waitUntil("the helper to connect") { await transport.isConnected }

    try await helper.write(json: [
      "event": "ping",
      "process": HelperHost.messages,
      "protocolVersion": 2,
      "events": "daemon-listener",
    ])

    async let runtimeEvent = firstEvent(in: runtimeStream)
    async let busEvent = firstEvent(in: busStream)

    for event in [await runtimeEvent, await busEvent] {
      guard case .helperRegistered(let process, let version, let rung) = event else {
        Issue.record("a subscriber did not receive the registration: \(String(describing: event))")
        continue
      }
      #expect(process == HelperHost.messages)
      #expect(version == 2)
      #expect(rung == "daemon-listener")
    }

    try await helper.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// Fan-out means a continuation per reader, so it also means a way to let one go. Without
  /// this the transport accumulates a dead continuation for every subscription ever taken,
  /// and yielding walks all of them.
  @Test("A subscription that ends is dropped")
  func endedSubscriptionIsDropped() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    do {
      let stream = await transport.events
      #expect(await transport.subscriberCount == 1)
      // Released here without ever being iterated. Dropping the stream is what signals
      // termination, and the subscription has to go with it.
      withExtendedLifetime(stream) {}
    }

    // Termination is delivered asynchronously, so poll rather than assert immediately.
    try await waitUntil("every subscriber to be released") { await transport.subscriberCount == 0 }
    #expect(await transport.subscriberCount == 0)

    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// A stopped transport will never yield again, so a reader still parked on `for await`
  /// would wait for the life of the process.
  @Test("Stopping the transport ends every subscription")
  func stopFinishesSubscriptions() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    let stream = await transport.events
    let drained = Task {
      var count = 0
      for await _ in stream { count += 1 }
      return count
    }

    await transport.stop()

    // Completes only because the stream finished; a leaked continuation hangs here.
    #expect(await drained.value == 0)
    #expect(await transport.subscriberCount == 0)

    try? await group.shutdownGracefully()
  }

  /// Events reach a subscriber in the order the helper sent them.
  ///
  /// The transport used to spawn `Task { await handle(frame:) }` per frame, which takes the
  /// ordering NIO guarantees on a channel and hands it to the scheduler. Harmless for a
  /// transaction reply, which is correlated by id, and not harmless for an EVENT, which has
  /// no id and whose order is its meaning: `typing-started` behind its own `typing-stopped`
  /// leaves an indicator lit with nothing to clear it.
  ///
  /// **What this test does and does not prove, because the difference matters.** It pins the
  /// property. It is NOT a reproduction of the old defect: the previous shape passes it too,
  /// measured, three runs out of three. Forty tasks enqueued back to back from one event-loop
  /// thread onto an actor that does no suspending work per frame come out in order in
  /// practice, so the reordering was possible rather than observable — Swift promises no FIFO
  /// across separately-created tasks, and priority escalation and pool scheduling are both
  /// free to break it. The lane makes the ordering structural instead of incidental, and this
  /// test is the guard on that property, not evidence of a bug that was firing.
  ///
  /// Forty frames, each naming a different chat, so a reordering shows up as a permutation
  /// rather than as an ambiguous flake.
  @Test("Events are delivered in the order the helper sent them")
  func eventsKeepTheirOrder() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()
    let stream = await transport.events

    let helper = FakeSocketHelper(group: group)
    try await helper.connect(path: path)
    try await waitUntil("the helper to connect") { await transport.isConnected }

    let total = 40
    let collector = Task { await events(in: stream, count: total) }

    var sent: [String] = []
    for index in 1...total {
      let guid = "iMessage;+;chat0000000000000000\(String(format: "%02d", index))"
      sent.append(guid)
      try await helper.write(json: ["event": "started-typing", "chatGuid": guid])
    }

    let received = await collector.value.compactMap { event -> String? in
      guard case .typingChanged(let chat, let isTyping) = event, isTyping else { return nil }
      return chat.rawValue
    }

    #expect(received.count == total, "\(received.count) of \(total) events arrived")
    #expect(received == sent, "events were reordered on the way to the subscriber")

    try await helper.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }
}

@Suite("Helper disconnection")
struct HelperDisconnectionTests {

  /// The runtime's state stream and the registry's health stream both turn on this: a
  /// helper that goes away says nothing on the way out, so the transport has to say it.
  @Test("A registered helper closing its socket is reported")
  func closedSocketIsReported() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()
    let stream = await transport.events

    let helper = FakeSocketHelper(group: group)
    try await helper.connect(path: path)
    try await waitUntil("the helper to connect") { await transport.isConnected }
    try await helper.write(json: [
      "event": "ping",
      "process": HelperHost.messages,
      "protocolVersion": 2,
      "events": "none",
    ])
    guard case .helperRegistered? = await firstEvent(in: stream) else {
      Issue.record("the registration never arrived")
      await transport.stop()
      try? await group.shutdownGracefully()
      return
    }

    try await helper.disconnect()

    guard case .helperDisconnected(let process)? = await firstEvent(in: stream) else {
      Issue.record("the disconnection never arrived")
      await transport.stop()
      try? await group.shutdownGracefully()
      return
    }
    #expect(process == HelperHost.messages)
    #expect(await !transport.connectedProcesses.contains(HelperHost.messages))

    await transport.stop()
    try? await group.shutdownGracefully()
  }

  /// A request is failed when ITS connection drops, not when the last one does.
  ///
  /// The transport used to fail outstanding requests only once no helper was left, so with
  /// Messages still connected a FaceTime caller whose helper had gone waited out the whole
  /// timeout for a reply that could no longer arrive.
  @Test("A helper dropping fails its own requests while another helper stays up")
  func droppedHelperFailsItsRequests() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()

    let messages = FakeSocketHelper(group: group)
    let faceTime = FakeSocketHelper(group: group)
    for (helper, process) in [(messages, HelperHost.messages), (faceTime, HelperHost.faceTime)] {
      try await helper.connect(path: path)
      try await Task.sleep(for: .milliseconds(50))
      try await helper.write(json: [
        "event": "ping", "process": process, "protocolVersion": 2, "events": "none",
      ])
    }
    try await waitUntil("both helpers to register") {
      await transport.connectedProcesses.count >= 2
    }
    #expect(await transport.connectedProcesses.count == 2)

    let started = ContinuousClock.now
    let request = Task {
      try await transport.request(
        action: "get-active-calls", data: .object([:]), timeout: .seconds(30),
        process: HelperHost.faceTime)
    }
    _ = try await faceTime.awaitTransactionId()
    try await faceTime.disconnect()

    await #expect(throws: PrivateAPIError.self) { _ = try await request.value }
    #expect(ContinuousClock.now - started < .seconds(10), "the caller waited out its timeout")
    #expect(await transport.connectedProcesses.contains(HelperHost.messages))

    await transport.stop()
    try? await group.shutdownGracefully()
  }
}

/// The connection bookkeeping, without a socket.
///
/// A failed write cannot be produced on demand over a real socket (the close usually lands
/// first), so the drop it triggers is asserted here, on the one value both paths go through.
@Suite("Helper connection bookkeeping")
struct HelperConnectionsTests {

  private final class Connection {}

  private func key(_ connection: Connection) -> ObjectIdentifier { ObjectIdentifier(connection) }

  @Test("Dropping a connection takes its registration with it and reports it once")
  func dropTakesRegistration() {
    var connections = HelperConnections<Connection>()
    let messages = Connection()
    connections.add(messages, as: key(messages))
    #expect(connections.register(HelperHost.messages, on: key(messages)) == nil)
    connections.carrying("tx-1", on: key(messages))

    let dropped = connections.remove(key(messages))
    #expect(dropped == .init(processes: [HelperHost.messages], inFlight: ["tx-1"]))
    #expect(connections.processes.isEmpty, "a dropped helper is still reported as connected")
    #expect(connections.connection(registeredAs: HelperHost.messages) == nil)
    #expect(connections.isEmpty)

    // The close that follows a failed write finds nothing left to announce.
    #expect(connections.remove(key(messages)) == .init())
  }

  @Test("The newest live connection wins, and a dropped one falls through to the next")
  func newestFallsThrough() {
    var connections = HelperConnections<Connection>()
    let older = Connection()
    let newer = Connection()
    connections.add(older, as: key(older))
    connections.add(newer, as: key(newer))
    #expect(connections.newest?.key == key(newer))

    _ = connections.remove(key(newer))
    #expect(connections.newest?.key == key(older))
    _ = connections.remove(key(older))
    #expect(connections.newest == nil)
  }

  @Test("A finished transaction is not failed when its connection later drops")
  func finishedTransactionIsForgotten() {
    var connections = HelperConnections<Connection>()
    let helper = Connection()
    connections.add(helper, as: key(helper))
    connections.carrying("tx-1", on: key(helper))
    connections.carrying("tx-2", on: key(helper))
    connections.finished("tx-1")
    #expect(connections.remove(key(helper)).inFlight == ["tx-2"])
  }
}

/// A frame that does not decode still answers the request it was replying to.
///
/// Dropped silently, an unreadable reply left its caller waiting out the whole timeout for an
/// answer that had already arrived. When the transaction id can be read, the request fails at
/// once with `protocolMismatch`.
@Suite("Undecodable helper frames", .serialized)
struct UndecodableFrameTests {

  @Test("An undecodable reply fails its request at once, not at the timeout")
  func undecodableReplyFailsFast() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let path = temporarySocketPath()
    let transport = SocketTransport(
      socketPath: path, validator: PermissivePeerValidator(), group: group
    )
    try await transport.start()
    let helper = FakeSocketHelper(group: group)
    try await helper.connect(path: path)
    try await waitUntil("the helper to connect") { await transport.isConnected }

    let started = ContinuousClock.now
    let response = Task {
      try await transport.request(
        action: "get-account-info", data: .object([:]), timeout: .seconds(30)
      )
    }
    let id = try await helper.awaitTransactionId()
    // Cut short mid-object: not JSON, but the id is on the wire.
    try await helper.write(raw: Data(#"{"transactionId":"\#(id)","data":{"appleId":"#.utf8))

    do {
      _ = try await response.value
      Issue.record("an undecodable reply was answered as a success")
    } catch let error as PrivateAPIError {
      guard case .protocolMismatch = error else {
        Issue.record("expected protocolMismatch, got \(error)")
        return
      }
    }
    #expect(ContinuousClock.now - started < .seconds(10), "the caller waited out its timeout")

    try await helper.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  @Test("The transaction id is recovered from a frame that is not JSON, and only then")
  func recovery() {
    #expect(
      SocketTransport.recoverTransactionId(from: Data(#"{"transactionId":"tx-1","data":"#.utf8))
        == "tx-1")
    #expect(
      SocketTransport.recoverTransactionId(from: Data(#"{"transactionId" : "tx-2"}"#.utf8))
        == "tx-2")
    #expect(SocketTransport.recoverTransactionId(from: Data(#"{"event":"ping""#.utf8)) == nil)
    #expect(SocketTransport.recoverTransactionId(from: Data([0xFF, 0xFE, 0x00])) == nil)
    #expect(SocketTransport.recoverTransactionId(from: Data(#"{"transactionId":""}"#.utf8)) == nil)
  }
}

/// Which app a connection belongs to is decided by the socket it arrived on.
///
/// There is one socket per app, inside that app's container, so the listener knows who can be
/// on the other end. A registration ping naming a different app is refused rather than
/// believed: routing on it would hand one helper the other's actions.
@Suite("Helper routing by socket", .serialized)
struct HelperSocketRoutingTests {

  private func ping(as process: String) -> [String: Any] {
    ["event": "ping", "process": process, "protocolVersion": 2, "events": "none"]
  }

  private func transport(
    messages: String, faceTime: String, group: any EventLoopGroup
  ) -> SocketTransport {
    SocketTransport(
      listeners: [
        .init(path: messages, host: HelperHost.messages),
        .init(path: faceTime, host: HelperHost.faceTime),
      ],
      validator: PermissivePeerValidator(), group: group)
  }

  @Test("A helper naming another app than its socket serves is refused, not registered")
  func mismatchedRegistrationIsRefused() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let (messagesPath, faceTimePath) = (temporarySocketPath(), temporarySocketPath())
    let transport = transport(messages: messagesPath, faceTime: faceTimePath, group: group)
    try await transport.start()
    let stream = await transport.events

    let impostor = FakeSocketHelper(group: group)
    try await impostor.connect(path: faceTimePath)
    try await waitUntil("the impostor to connect") { await transport.isConnected }
    try await impostor.write(json: ping(as: HelperHost.messages))
    try await waitUntil("the impostor to be closed") { await !transport.isConnected }
    #expect(await transport.connectedProcesses.isEmpty)

    // The honest registration is the FIRST event: the refused one was never announced.
    let messages = FakeSocketHelper(group: group)
    try await messages.connect(path: messagesPath)
    try await waitUntil("the helper to connect") { await transport.isConnected }
    try await messages.write(json: ping(as: HelperHost.messages))
    guard case .helperRegistered(let process, _, _)? = await firstEvent(in: stream) else {
      Issue.record("the honest registration never arrived")
      await transport.stop()
      try? await group.shutdownGracefully()
      return
    }
    #expect(process == HelperHost.messages)
    #expect(await transport.connectedProcesses == [HelperHost.messages])

    try? await impostor.disconnect()
    try await messages.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  @Test("An untargeted action never lands on another app's socket")
  func untargetedStaysOffFaceTime() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let (messagesPath, faceTimePath) = (temporarySocketPath(), temporarySocketPath())
    let transport = transport(messages: messagesPath, faceTime: faceTimePath, group: group)
    try await transport.start()

    let faceTime = FakeSocketHelper(group: group)
    try await faceTime.connect(path: faceTimePath)
    try await faceTime.write(json: ping(as: HelperHost.faceTime))
    try await waitUntil("the FaceTime helper to register") {
      await transport.connectedProcesses == [HelperHost.faceTime]
    }

    await #expect(throws: PrivateAPIError.notConnected) {
      try await transport.request(
        action: "send-message", data: .object([:]), timeout: .seconds(3))
    }
    #expect(faceTime.handler.received.isEmpty, "a Messages action reached the FaceTime helper")

    try await faceTime.disconnect()
    await transport.stop()
    try? await group.shutdownGracefully()
  }

  @Test("A path is bound to the app whose container socket it is, and no other")
  func listenersForPaths() {
    let listeners = SocketTransport.Listener.forPaths([
      SocketLocation.privateAPISocket(for: HelperHost.faceTime), temporarySocketPath(),
    ])
    // Under a BLUEBUBBLES_HELPER_SOCKET override every app resolves to the same path, so it
    // is bound to none of them.
    let overridden = ProcessInfo.processInfo.environment["BLUEBUBBLES_HELPER_SOCKET"] != nil
    #expect(listeners.first?.host == (overridden ? nil : HelperHost.faceTime))
    #expect(listeners.last?.host == nil)
  }
}

@Suite("Helper connection binding")
struct HelperConnectionBindingTests {

  private final class Connection {}

  @Test("A connection on one app's socket cannot register as the other")
  func boundConnectionRefusesAnotherName() {
    var connections = HelperConnections<Connection>()
    let helper = Connection()
    let key = ObjectIdentifier(helper)
    connections.bind(key, to: HelperHost.faceTime)
    connections.add(helper, as: key)

    #expect(connections.register(HelperHost.messages, on: key) == HelperHost.faceTime)
    #expect(connections.processes.isEmpty)
    #expect(connections.register(HelperHost.faceTime, on: key) == nil)
    #expect(connections.processes == [HelperHost.faceTime])
    // Never offered an untargeted (Messages) action.
    #expect(connections.newest(servingUntargeted: true) == nil)
    #expect(connections.newest?.key == key)
  }

  @Test("A connection on an unbound socket registers as whatever it says")
  func unboundConnectionTakesTheSelfReport() {
    var connections = HelperConnections<Connection>()
    let helper = Connection()
    let key = ObjectIdentifier(helper)
    connections.bind(key, to: nil)
    connections.add(helper, as: key)
    #expect(connections.register(HelperHost.faceTime, on: key) == nil)
    #expect(connections.newest(servingUntargeted: true)?.key == key)
  }
}

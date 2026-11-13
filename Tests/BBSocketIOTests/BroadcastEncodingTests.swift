//  BroadcastEncodingTests
//  One event, many phones: encoded once per frame shape rather than once per connection.
//
//  The projection was already shared across connections; the JSON encoding was not. Three
//  phones on one event meant three identical encodings of the same bytes, on a path that runs
//  during a backfill burst -- exactly when the server has least to spare.
//
//  Sealed frames are DELIBERATELY excluded and that is the interesting half of this suite. A
//  sealed payload is encrypted to one client's key with a fresh ephemeral keypair per call, so
//  sharing one across connections would hand a client a frame it cannot open. Multi-client is
//  a hard requirement here, so the test that matters is not "it got faster" but "two clients
//  still get what each of them asked for".

import BBEvents
import BBSerialization
import Foundation
import Testing

@testable import BBSocketIO

@Suite("Broadcast encoding")
struct BroadcastEncodingTests {

  /// Records every frame it is handed.
  private final class RecordingConnection: SocketConnection, @unchecked Sendable {
    let id: SocketID
    let options: SocketClientOptions
    private let lock = NSLock()
    private var frames: [String] = []

    init(id: String, options: SocketClientOptions) {
      self.id = SocketID(id)
      self.options = options
    }

    func send(_ frame: String) async { lock.withLock { frames.append(frame) } }
    func close() async {}
    var received: [String] { lock.withLock { frames } }
  }

  /// Counts how many times the codec was actually asked to encode.
  private final class CountingCodec: EventPayloadCodec, @unchecked Sendable {
    let identifier: CodecIdentifier
    private let lock = NSLock()
    private var calls = 0
    var encodeCount: Int { lock.withLock { calls } }

    init(identifier: CodecIdentifier = .legacyV1) { self.identifier = identifier }

    func encode(
      _ event: ServerEvent, projection: PayloadProjection, capabilities: TargetCapabilities
    ) async throws -> EncodedPayload {
      lock.withLock { calls += 1 }
      return EncodedPayload(codec: identifier, body: event.payload(for: projection))
    }
  }

  private func event() -> ServerEvent {
    ServerEvent(name: .newMessage, fullPayload: .object(["guid": .string("EVENT-1")]))
  }

  @Test("Three identical clients cost one encoding, and all three get the same frame")
  func identicalClientsShareOneEncoding() async throws {
    let codec = CountingCodec()
    let server = SocketServer(
      negotiator: CodecNegotiator(serverPreference: .legacyV1, codecs: [codec]))

    let connections = (0..<3).map {
      RecordingConnection(id: "c\($0)", options: SocketClientOptions())
    }
    for connection in connections { await server.register(connection) }

    await server.broadcast(event())

    #expect(codec.encodeCount == 1, "encoded \(codec.encodeCount) times for three clients")
    let frames = connections.map(\.received)
    #expect(frames.allSatisfy { $0.count == 1 }, "every client must receive exactly one frame")
    #expect(Set(frames.flatMap { $0 }).count == 1, "the three clients got different frames")
  }

  /// The frame differs when the client asked for a replay sequence, so those clients must
  /// not be served from the same entry.
  @Test("A replay client gets its own frame, with the sequence in it")
  func replayClientsAreSeparate() async throws {
    let codec = CountingCodec()
    let server = SocketServer(
      negotiator: CodecNegotiator(serverPreference: .legacyV1, codecs: [codec]))

    let plain = RecordingConnection(id: "plain", options: SocketClientOptions())
    let replaying = RecordingConnection(
      id: "replay", options: SocketClientOptions(wantsReplay: true))
    await server.register(plain)
    await server.register(replaying)

    await server.broadcast(event())

    #expect(codec.encodeCount == 2, "the two shapes must be encoded separately")
    let plainFrame = try #require(plain.received.first)
    let replayFrame = try #require(replaying.received.first)
    #expect(plainFrame != replayFrame)
    #expect(replayFrame.contains("\"seq\""), "the replay client's frame has no sequence")
    #expect(!plainFrame.contains("\"seq\""), "a client that did not ask got a sequence")
  }

  /// Two clients of the SAME shape, with one also asking for replay, still each get theirs.
  @Test("Mixed clients each get the frame their own options describe")
  func mixedClientsAreEachCorrect() async throws {
    let codec = CountingCodec()
    let server = SocketServer(
      negotiator: CodecNegotiator(serverPreference: .legacyV1, codecs: [codec]))

    let a = RecordingConnection(id: "a", options: SocketClientOptions())
    let b = RecordingConnection(id: "b", options: SocketClientOptions())
    let c = RecordingConnection(id: "c", options: SocketClientOptions(wantsReplay: true))
    for connection in [a, b, c] { await server.register(connection) }

    await server.broadcast(event())

    // Two shapes, three clients.
    #expect(codec.encodeCount == 2)
    #expect(a.received == b.received)
    #expect(c.received != a.received)
    #expect(c.received.first?.contains("\"seq\"") == true)
  }

  // MARK: - The replay ring

  /// Bounded by BYTES as well as by count.
  ///
  /// A count is the wrong unit for a bound whose purpose is memory: one message with twenty
  /// attachments is not one typing indicator, and the ring has no say in which it gets.
  /// Measured at 2.69MB for 500 events before this, 5,636 bytes each, because it keeps the
  /// full projection rather than the wire form.
  @Test("A ring of large events is bounded by bytes, not just count")
  func replayRingIsBoundedByBytes() async throws {
    let server = SocketServer(negotiator: .legacyOnly(), replayCapacity: 500)

    // Well under the count cap, well over the byte budget.
    let big = String(repeating: "x", count: 64 * 1024)
    for index in 0..<32 {
      await server.broadcast(
        ServerEvent(
          name: .newMessage,
          fullPayload: .object(["guid": .string("E\(index)"), "text": .string(big)])))
    }

    // A client asking from the very beginning must be told to resync, because the oldest
    // events are gone. That is the CORRECT answer and the proof that eviction happened:
    // silently sending a partial history it would treat as complete is the failure mode
    // `resyncRequired` exists to prevent.
    guard case .resyncRequired = await server.replay(since: 0) else {
      Issue.record("nothing was evicted, so the byte bound did nothing")
      return
    }

    // And what it kept is the NEWEST, which is what a reconnecting client needs.
    guard case .events(let held) = await server.replay(since: 31) else {
      Issue.record("the ring could not replay its own most recent event")
      return
    }
    #expect(held.map(\.sequence) == [32])
  }

  /// The count cap still applies to small events, which are the common case.
  @Test("Small events are still bounded by the count")
  func smallEventsUseTheCountBound() async throws {
    let server = SocketServer(negotiator: .legacyOnly(), replayCapacity: 10)
    for index in 0..<25 {
      await server.broadcast(
        ServerEvent(name: .newMessage, fullPayload: .object(["i": .int(index)])))
    }
    guard case .events(let held) = await server.replay(since: 15) else {
      Issue.record("unexpected resync")
      return
    }
    #expect(held.count == 10, "held \(held.count) events against a capacity of 10")
  }
}

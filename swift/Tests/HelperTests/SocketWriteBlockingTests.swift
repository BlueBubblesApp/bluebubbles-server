//  SocketWriteBlockingTests
//  A server that stops reading must not stop Messages.
//
//  The helper is injected into Messages.app, and `HelperSocketClient.perform` is `@MainActor`
//  because the dispatch it wraps has to be. Replies were therefore written from the main
//  thread with a blocking `write()` loop, held inside an unfair lock, on a socket never set
//  non-blocking. Once the peer's receive buffer filled, that call did not return: the user's
//  Messages froze, and `stop()` deadlocked against the same lock.
//
//  The property under test is the one that matters to the user, and it is not "writes
//  succeed". It is that the CALLER IS RELEASED even when the peer never reads a byte.
//
//  This drives a real socketpair rather than a mock, because the thing being tested is what
//  the kernel does when a send buffer fills, which no mock reproduces.

import Darwin
import Foundation
import Testing

@testable import BBPrivateAPIContract
@testable import HelperShared

@Suite("Socket write blocking")
struct SocketWriteBlockingTests {

  /// A connected pair where NOTHING reads the far end, so its buffer fills and stays full.
  private final class DeafPeer: @unchecked Sendable {
    let ours: Int32
    let theirs: Int32

    init() {
      var pair: [Int32] = [0, 0]
      let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
      precondition(result == 0, "socketpair failed: \(errno)")
      ours = pair[0]
      theirs = pair[1]
      // Matches what the helper sets, so a full buffer surfaces as a timeout rather than
      // killing the test process with SIGPIPE.
      var noSignal: Int32 = 1
      setsockopt(ours, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(ours, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Fills the pipe so the next write cannot complete. Returns how many bytes it took.
    func fill() -> Int {
      var total = 0
      let chunk = [UInt8](repeating: 0xAB, count: 64 * 1024)
      // Bounded so a kernel with a very large buffer cannot spin here forever.
      for _ in 0..<512 {
        let written = chunk.withUnsafeBytes { Darwin.write(ours, $0.baseAddress!, $0.count) }
        if written <= 0 { break }
        total += written
        if written < chunk.count { break }
      }
      return total
    }

    deinit {
      Darwin.close(ours)
      Darwin.close(theirs)
    }
  }

  @Test("A blocking write on a full socket does block, which is the hazard")
  func theHazardIsReal() {
    // Establishes the premise the fix exists for, rather than asserting it in a comment. If
    // this ever stops blocking, the rest of this suite is testing nothing.
    let peer = DeafPeer()
    let filled = peer.fill()
    #expect(filled > 0, "the pipe should have accepted something before filling")

    let started = ContinuousClock.now
    let chunk = [UInt8](repeating: 0xCD, count: 64 * 1024)
    let written = chunk.withUnsafeBytes { Darwin.write(peer.ours, $0.baseAddress!, $0.count) }
    let elapsed = ContinuousClock.now - started

    // It did not complete, and it consumed the send timeout doing so.
    #expect(written < 0, "a write to a full socket should not succeed")
    #expect(errno == EAGAIN || errno == EWOULDBLOCK, "expected a send timeout, got \(errno)")
    #expect(elapsed > .milliseconds(500), "the write returned too quickly to have blocked")
  }

  @Test("The main thread is released even though the peer never reads")
  func mainThreadIsNotBlocked() async throws {
    let peer = DeafPeer()
    _ = peer.fill()

    let client = HelperSocketClient(
      socketPath: "/nonexistent/never-connected.sock",
      bundleIdentifier: "com.apple.MobileSMS",
      dispatch: { _ in nil },
      describeError: { String(describing: $0) }
    )
    client.adoptDescriptorForTesting(peer.ours)

    // A frame far larger than whatever room is left, so it cannot be absorbed.
    let payload = String(repeating: "x", count: 256 * 1024)

    let started = ContinuousClock.now
    await MainActor.run {
      // The call under test, on the actor that used to freeze. Before the fix this did not
      // return until the peer read, and the peer never reads.
      client.write(object: [.event: payload])
    }
    let elapsed = ContinuousClock.now - started

    #expect(
      elapsed < .seconds(1),
      "write() blocked the main thread for \(elapsed); it must hand off and return"
    )
  }

  @Test("Many queued writes still do not block the caller")
  func repeatedWritesDoNotBlock() async {
    let peer = DeafPeer()
    _ = peer.fill()

    let client = HelperSocketClient(
      socketPath: "/nonexistent/never-connected.sock",
      bundleIdentifier: "com.apple.MobileSMS",
      dispatch: { _ in nil },
      describeError: { String(describing: $0) }
    )
    client.adoptDescriptorForTesting(peer.ours)

    let started = ContinuousClock.now
    await MainActor.run {
      for index in 0..<200 {
        client.write(object: [.event: "event-\(index)"])
      }
    }
    let elapsed = ContinuousClock.now - started

    // Two hundred frames against a peer that reads none of them. Queueing is O(1) per frame,
    // so the caller's cost is serialization and nothing else.
    #expect(elapsed < .seconds(1), "queueing 200 frames took \(elapsed)")
  }

  @Test("Frames are not interleaved when written concurrently")
  func framesStayWhole() async throws {
    // The lock used to guarantee this by spanning the syscall. The serial queue guarantees
    // it now, and a frame split down the middle is unparseable, so it is worth pinning.
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      Darwin.close(pair[0])
      Darwin.close(pair[1])
    }

    let client = HelperSocketClient(
      socketPath: "/nonexistent/never-connected.sock",
      bundleIdentifier: "com.apple.MobileSMS",
      dispatch: { _ in nil },
      describeError: { String(describing: $0) }
    )
    client.adoptDescriptorForTesting(pair[0])

    let count = 50
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<count {
        group.addTask { client.write(object: [.event: "frame-\(index)"]) }
      }
      await group.waitForAll()
    }
    client.drainWritesForTesting()

    // Read them back and check each length prefix lines up with a whole JSON body. An
    // interleaved write shows up here as a frame whose declared length runs past the next
    // frame's start.
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    var deadline = 200
    while deadline > 0 {
      let read = buffer.withUnsafeMutableBytes {
        Darwin.recv(pair[1], $0.baseAddress!, $0.count, MSG_DONTWAIT)
      }
      if read > 0 {
        received.append(contentsOf: buffer[0..<read])
      } else {
        try? await Task.sleep(for: .milliseconds(10))
        deadline -= 1
        if received.count > 0 && read < 0 && errno == EAGAIN { break }
      }
    }

    var frames = 0
    var cursor = received.startIndex
    while received.distance(from: cursor, to: received.endIndex) >= 4 {
      let length =
        (Int(received[cursor]) << 24) | (Int(received[received.index(cursor, offsetBy: 1)]) << 16)
        | (Int(received[received.index(cursor, offsetBy: 2)]) << 8)
        | Int(received[received.index(cursor, offsetBy: 3)])
      let bodyStart = received.index(cursor, offsetBy: 4)
      guard length > 0, received.distance(from: bodyStart, to: received.endIndex) >= length else {
        break
      }
      let body = received[bodyStart..<received.index(bodyStart, offsetBy: length)]
      let decoded = try? JSONSerialization.jsonObject(with: Data(body))
      #expect(decoded != nil, "frame \(frames) did not decode; frames were interleaved")
      frames += 1
      cursor = received.index(bodyStart, offsetBy: length)
    }
    #expect(frames == count, "expected \(count) whole frames, parsed \(frames)")
  }
}

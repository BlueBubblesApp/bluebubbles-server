//  LoopbackSyslogReceiver
//  A syslog receiver on 127.0.0.1, so a forwarder test asserts what actually ARRIVED.
//
//  The forwarder's own state (`queuedCount`, `currentState`) says what it believes; the two
//  defects these tests exist for were both cases of that belief and the wire disagreeing: a
//  datagram the kernel refused, and a queue thrown away on stop. Only a socket on the other
//  end can tell them apart.
//
//  Plain BSD sockets on a thread of its own, polled with a short timeout so `close()` ends it.
//  TCP frames are RFC 6587 octet-counted, which is what the forwarder writes.

import BBTestSupport
import Darwin
import Foundation

import struct os.OSAllocatedUnfairLock

final class LoopbackSyslogReceiver: Sendable {

  enum Transport { case udp, tcp }

  let port: Int
  private let listener: Int32
  private let transport: Transport
  private let state = OSAllocatedUnfairLock(initialState: State())

  private struct State {
    var datagrams: [String] = []
    var stream = Data()
    var open = true
  }

  init(_ transport: Transport) throws {
    self.transport = transport
    let fd = socket(AF_INET, transport == .udp ? SOCK_DGRAM : SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    // Room for a datagram past macOS's default `net.inet.udp.maxdgram`, so an oversized
    // send is refused by the sender's kernel rather than by this end.
    var buffer: Int32 = 1 << 20
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, transport == .udp || listen(fd, 4) == 0 else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    self.port = Int(UInt16(bigEndian: address.sin_port))
    self.listener = fd
    Thread.detachNewThread { [self] in run() }
  }

  /// The messages received so far: one per datagram, or one per octet-counted TCP frame.
  var messages: [String] {
    state.withLock { state in
      switch transport {
      case .udp: state.datagrams
      case .tcp: Self.frames(in: state.stream)
      }
    }
  }

  /// Waits until `count` messages have arrived, and returns them.
  ///
  /// - Throws: `WaitTimedOut` if fewer than `count` arrive within `timeout`.
  func waitFor(_ count: Int, timeout: Duration = .seconds(5)) async throws -> [String] {
    try await waitUntil("\(count) syslog message(s)", timeout: timeout) {
      messages.count >= count
    }
    return messages
  }

  func stop() {
    state.withLock { $0.open = false }
  }

  private var isOpen: Bool { state.withLock { $0.open } }

  private func run() {
    defer { close(listener) }
    var connection: Int32 = -1
    defer { if connection >= 0 { close(connection) } }
    var buffer = [UInt8](repeating: 0, count: 1 << 17)
    while isOpen {
      let watched = (transport == .tcp && connection >= 0) ? connection : listener
      var poller = pollfd(fd: watched, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 50) > 0 else { continue }
      if transport == .tcp && connection < 0 {
        connection = accept(listener, nil, nil)
        continue
      }
      let read = recv(watched, &buffer, buffer.count, 0)
      guard read > 0 else {
        // The sender closed: a later connection is a new one.
        if transport == .tcp, connection >= 0 {
          close(connection)
          connection = -1
        }
        continue
      }
      let bytes = Data(buffer[0..<read])
      state.withLock { state in
        switch transport {
        case .udp: state.datagrams.append(String(decoding: bytes, as: UTF8.self))
        case .tcp: state.stream.append(bytes)
        }
      }
    }
  }

  /// RFC 6587 octet counting: `LENGTH SP MESSAGE`, repeated. A partial frame is not returned.
  private static func frames(in stream: Data) -> [String] {
    var frames: [String] = []
    var index = stream.startIndex
    while let space = stream[index...].firstIndex(of: UInt8(ascii: " ")),
      let length = Int(String(decoding: stream[index..<space], as: UTF8.self))
    {
      let start = stream.index(after: space)
      guard let end = stream.index(start, offsetBy: length, limitedBy: stream.endIndex) else {
        break
      }
      frames.append(String(decoding: stream[start..<end], as: UTF8.self))
      index = end
    }
    return frames
  }
}

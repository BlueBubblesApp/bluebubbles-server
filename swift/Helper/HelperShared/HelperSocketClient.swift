//  HelperSocketClient
//  The helper's side of the Unix-domain socket.
//
//  Hand-rolled POSIX rather than SwiftNIO, deliberately. This code is injected into
//  Messages.app — someone else's process, which the user did not agree to have us destabilise
//  — so every dependency is one more thing that can conflict with what is already loaded
//  there, one more source of unexpected threads, and one more library whose crash is
//  attributed to Messages. A framed socket client is about two hundred lines; NIO is not
//  worth carrying across that boundary.
//
//  The same reasoning is why this target links `BBPrivateAPIContract` and nothing else.
//
//  Framing matches SocketTransport: a 4-byte big-endian length, then that many bytes of JSON.
//  One framing, because there is now one transport.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Darwin
import Foundation

/// Connects to the server, answers requests, and pushes events.
public final class HelperSocketClient: @unchecked Sendable {

  /// How the client reports what it is doing. Injected so the helper does not decide on a
  /// logging framework inside somebody else's process.
  public typealias LogHandler = @Sendable (String) -> Void
  /// Runs one request and returns its reply payload. Injected so the SHARED socket client
  /// serves whichever helper it belongs to — the Messages dispatch or the FaceTime one —
  /// without the transport knowing either action set.
  public typealias Dispatch =
    @MainActor @Sendable (HelperProtocol.Request) async throws -> [String: Any]?
  /// Turns a thrown error into wire text.
  public typealias DescribeError = @Sendable (any Error) -> String

  private let socketPath: String
  private let bundleIdentifier: String
  private let log: LogHandler
  private let dispatch: Dispatch
  private let describeError: DescribeError
  /// Which observation rung this helper attached to, reported in the registration handshake.
  /// The Messages helper passes `EventObservation.rung`; the FaceTime helper reports its own.
  private let eventRung: String

  private var descriptor: Int32 = -1
  /// A dedicated thread, not a queue.
  ///
  /// `serve()` sits in a blocking `read()` for the client's lifetime. On a DispatchQueue
  /// that permanently consumes one of the pool's threads — which in production is one
  /// thread and fine, but is a real hazard anywhere several clients exist at once: the pool
  /// runs out, and work that has nothing to do with this queue simply stops being
  /// scheduled. A thread we own has no such shared budget to exhaust.
  private var thread: Thread?
  private let writeLock = NSLock()
  private var running = false
  /// Grows until a complete frame is available.
  private var inbound = Data()

  /// Reconnect backoff. The server restarting is normal, not an error — the helper simply
  /// waits for it to come back rather than requiring Messages to be relaunched.
  private var reconnectDelay: TimeInterval = 1
  private let maximumReconnectDelay: TimeInterval = 30

  public init(
    socketPath: String,
    bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "unknown",
    eventRung: String = "none",
    log: @escaping LogHandler = { _ in },
    dispatch: @escaping Dispatch,
    describeError: @escaping DescribeError
  ) {
    self.socketPath = socketPath
    self.bundleIdentifier = bundleIdentifier
    self.eventRung = eventRung
    self.log = log
    self.dispatch = dispatch
    self.describeError = describeError
  }

  // MARK: - Lifecycle

  public func start() {
    guard thread == nil else { return }
    let thread = Thread { [weak self] in self?.runLoop() }
    thread.name = "com.bluebubbles.helper.socket"
    // Below the default: this thread spends its life blocked on a socket read, and
    // nothing about it is latency-sensitive until a frame actually arrives.
    thread.qualityOfService = .utility
    self.thread = thread
    thread.start()
  }

  public func stop() {
    running = false
    // Closing the descriptor is what unblocks the read; the loop then sees `running` is
    // false and the thread exits on its own.
    closeConnection()
    thread = nil
  }

  /// Connect, serve, and reconnect forever.
  ///
  /// Runs on a dedicated queue, never on Messages.app's main thread: blocking that would
  /// freeze the user's UI, which is a far worse failure than the helper being late.
  private func runLoop() {
    running = true
    while running {
      if connect() {
        reconnectDelay = 1
        announce()
        serve()
      }
      guard running else { return }
      Thread.sleep(forTimeInterval: reconnectDelay)
      reconnectDelay = min(reconnectDelay * 2, maximumReconnectDelay)
    }
  }

  /// Connects to the server's Unix socket inside Messages' container.
  ///
  /// ONE transport, with no loopback TCP fallback. The sandbox refuses Unix sockets OUTSIDE
  /// the container, not Unix sockets as such, which is why the socket lives inside it — see
  /// `SocketLocation`.
  ///
  /// Having no TCP path is what makes the connection verifiable: a Unix socket carries the
  /// peer's audit token, so the server can confirm this really is Messages. Loopback TCP
  /// cannot — any local process could connect to it and drive the Private API.
  private func connect() -> Bool {
    connectUnixSocket()
  }

  private func connectUnixSocket() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      log("Could not create a socket: \(String(cString: strerror(errno))) (\(errno))")
      return false
    }

    // SO_NOSIGPIPE, and this is not optional.
    //
    // Writing to a socket whose peer has closed raises SIGPIPE, whose default
    // disposition TERMINATES THE PROCESS. This code runs inside Messages.app, so the
    // default would mean: the user restarts the BlueBubbles server, the helper's next
    // write lands on a closed socket, and Messages dies — with no crash report anyone
    // would connect to us.
    //
    // With this set, the write returns EPIPE instead and the reconnect loop handles it,
    // which is what the loop is for. macOS has no MSG_NOSIGNAL; this is the equivalent.
    var noSignal: Int32 = 1
    setsockopt(
      fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    // sun_path is a fixed 104-byte buffer; a longer path would be silently truncated into
    // a different socket, so it is refused instead.
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      log("Socket path is too long for sockaddr_un: \(socketPath)")
      close(fd)
      return false
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, size)
      }
    }
    guard result == 0 else {
      // The reason, not just the failure. Every one of these means something
      // different and only errno distinguishes them:
      //
      //   ENOENT  the server is not running, or is listening somewhere else — the
      //           ordinary case, and the reason the loop retries
      //   EPERM   the SANDBOX refused it. Messages.app is sandboxed, so a socket
      //           outside its container is subject to the app sandbox's file rules
      //   ECONNREFUSED  the socket file exists but nothing is accepting on it, which
      //           is a stale file left by a server that did not clean up
      //
      // Discarding this was why an injected, correctly-mapped helper looked identical
      // to one that never loaded.
      let reason = String(cString: strerror(errno))
      log("Could not connect to \(socketPath): \(reason) (errno \(errno))")
      close(fd)
      return false
    }

    descriptor = fd
    inbound.removeAll(keepingCapacity: true)
    log("Connected to the BlueBubbles server over the Unix socket")
    return true
  }

  private func closeConnection() {
    writeLock.lock()
    defer { writeLock.unlock() }
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }

  /// Registration. The server treats this as proof the injection actually took — nothing
  /// else tells it, because dyld declining the library still leaves Messages running.
  private func announce() {
    // `events` reports which observation rung attached, and it is carried here rather
    // than logged because os_log from an injected dylib inside a sandboxed host does not
    // reliably reach `log show` — measured. The registration handshake is the one channel
    // proven to work, so the capability rides along with it.
    //
    // This is capability reporting, not diagnostics: the server can now say "typing
    // indicators are unavailable on this macOS" instead of a user discovering it.
    write(object: [
      "event": "ping",
      "process": bundleIdentifier,
      "protocolVersion": HelperProtocol.version,
      "events": eventRung,
    ])
  }

  // MARK: - Reading

  private func serve() {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while running, descriptor >= 0 {
      let count = read(descriptor, &buffer, buffer.count)
      guard count > 0 else {
        // 0 is a clean close; negative is an error. Either way the connection is
        // finished and the outer loop will reconnect.
        log(count == 0 ? "Server closed the connection" : "Socket read failed")
        closeConnection()
        return
      }
      inbound.append(contentsOf: buffer[0..<count])
      drainFrames()
    }
  }

  private func drainFrames() {
    // Length-prefixed: a 4-byte big-endian count, then that many bytes. One framing,
    // because there is one transport — the newline-delimited variant went with the TCP
    // bridge it existed for.
    while inbound.count >= 4 {
      let length = Int(inbound.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
      guard length <= HelperProtocol.maximumFrameBytes else {
        log("Server announced an oversized frame; dropping the connection")
        closeConnection()
        return
      }
      let total = 4 + length
      guard inbound.count >= total else { return }

      let frame = Data(
        inbound[
          inbound.index(
            inbound.startIndex, offsetBy: 4)..<inbound.index(inbound.startIndex, offsetBy: total)])
      inbound.removeSubrange(
        inbound.startIndex..<inbound.index(inbound.startIndex, offsetBy: total))
      handle(frame: frame)
    }
  }

  private func handle(frame: Data) {
    guard let request = try? JSONDecoder().decode(HelperProtocol.Request.self, from: frame) else {
      log("Undecodable request frame")
      return
    }

    // Dispatched onto a task so a slow action does not stall the read loop behind it.
    // The server correlates by transaction id, so replies may come back out of order.
    Task { [weak self] in
      guard let self else { return }
      await self.perform(request)
    }
  }

  /// `@MainActor`, so the reply dictionary is built and written on the same actor that
  /// produced it.
  ///
  /// The alternative — returning `[String: Any]` from a main-actor call — does not compile,
  /// and rightly so: an untyped dictionary is not Sendable and would be crossing an
  /// isolation boundary. Doing the write here instead is also what the shipping
  /// Objective-C helper does; its `NetworkController` both reads and writes on the main
  /// queue (NetworkController.m:49).
  ///
  /// `write` is lock-guarded and the frames are small local-socket writes, so holding main
  /// for one is not a stall the user could perceive.
  @MainActor
  private func perform(_ request: HelperProtocol.Request) async {
    guard let transactionId = request.transactionId else {
      // Fire-and-forget. Still executed; there is simply nobody waiting.
      _ = try? await dispatch(request)
      return
    }

    do {
      let result = try await dispatch(request)
      var reply: [String: Any] = ["transactionId": transactionId]
      if let result { reply["data"] = result }
      write(object: reply)
    } catch {
      write(object: [
        "transactionId": transactionId,
        "error": describeError(error),
      ])
    }
  }

  // MARK: - Writing

  /// Serialized: two frames interleaved on the wire would be unparseable, and a Task per
  /// request means several can finish at once.
  func write(object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }

    var frame = Data(capacity: body.count + 4)
    let length = UInt32(body.count)
    frame.append(contentsOf: [
      UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
      UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
    ])
    frame.append(body)

    writeLock.lock()
    defer { writeLock.unlock() }
    guard descriptor >= 0 else { return }

    frame.withUnsafeBytes { raw in
      var offset = 0
      // A single write() can be partial on a stream socket; looping is not optional.
      while offset < raw.count {
        let written = Darwin.write(
          descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset
        )
        guard written > 0 else {
          // EPIPE or any other write failure: the connection is finished. The read
          // loop will see the same thing and reconnect; there is nothing useful to
          // do with a partially-written frame except abandon it.
          return
        }
        offset += written
      }
    }
  }

  /// Pushes an unsolicited event to the server.
  public func emit(event: String, payload: [String: Any] = [:]) {
    var object = payload
    object["event"] = event
    write(object: object)
  }
}

// MARK: - Protocol constants

public enum HelperProtocol {
  /// Bumped when the frame format or dispatch semantics change. Reported in the `ping` so
  /// the server can tell an old helper from a new one rather than guessing from behaviour.
  public static let version = 2
  public static let maximumFrameBytes = 64 * 1024 * 1024

  /// What the server sends.
  public struct Request: Decodable, Sendable {
    public let action: String
    public let transactionId: String?
    /// Left as raw JSON: dispatch decodes it per action, so an action this helper does
    /// not know cannot fail to decode before it can be reported as unimplemented.
    public let data: [String: WireValue]?
  }

  /// Minimal dynamic JSON, so the helper carries no serialization dependency.
  public enum WireValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WireValue])
    case object([String: WireValue])

    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Double.self) {
        self = .number(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([WireValue].self) {
        self = .array(value)
      } else if let value = try? container.decode([String: WireValue].self) {
        self = .object(value)
      } else {
        self = .null
      }
    }

    public var stringValue: String? {
      if case .string(let value) = self { return value }
      return nil
    }
    public var intValue: Int? {
      if case .number(let value) = self { return Int(value) }
      return nil
    }
    public var boolValue: Bool? {
      switch self {
      case .bool(let value): value
      case .number(let value): value != 0
      default: nil
      }
    }
    public var arrayValue: [WireValue]? {
      if case .array(let values) = self { return values }
      return nil
    }
  }
}

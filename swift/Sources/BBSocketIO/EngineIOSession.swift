//  EngineIOSession
//  One connected client's Engine.IO session, independent of which transport carries it.
//
//  The session outlives the transport, and that is the whole reason it is a separate type.
//  A Socket.IO client ALWAYS opens on polling and upgrades to websocket afterwards, so a
//  single logical connection is served by two different transports in its first second of
//  life. Anything that belongs to the client rather than to the socket — the sid, the
//  negotiated codecs, the outbound queue, whether it has been authenticated — has to survive
//  that switch, or the upgrade silently becomes a reconnect.
//
//  Outbound delivery is a queue with a waiter rather than a direct write, for the same
//  reason: on polling there is no open socket most of the time, so a broadcast has to be
//  parked until the client's next GET. The websocket transport drains the same queue, which
//  is what makes the upgrade a change of drain strategy rather than a change of model.
//
//  See `docs/EVENTS.md`.

import BBCore
import Foundation

/// One client, for as long as it keeps its sid.
public actor EngineIOSession: SocketConnection {

  public nonisolated let id: SocketID
  public nonisolated let options: SocketClientOptions

  /// Which transport is currently draining the queue.
  public enum Carrier: Sendable, Equatable {
    case polling
    case webSocket
  }

  /// Why a session ended, so the transport can answer correctly rather than guessing.
  public enum Closure: Sendable, Equatable {
    /// The client asked, or the server is shutting down.
    case normal
    /// Authentication failed. The client is closed WITHOUT an error packet — see
    /// `SocketServer.authenticate`.
    case rejected
    /// No poll and no pong within the timeout.
    case timedOut
  }

  /// True when the handshake carried no credential and the client may still supply one in
  /// its Socket.IO CONNECT `auth` payload. See `EngineIOServer.open`.
  private var awaitingAuth = false

  private var queue: [String] = []
  private var waiter: CheckedContinuation<[String], Never>?
  private var carrier: Carrier = .polling
  private var closed: Closure?
  private var lastSeen: ContinuousClock.Instant = .now

  /// Bounded, because a client that stops polling must not let broadcasts accumulate
  /// without limit. Dropping the OLDEST is deliberate: a client this far behind is going
  /// to have to resync anyway, and the newest events are the ones worth keeping.
  let queueLimit: Int

  public init(
    id: SocketID,
    options: SocketClientOptions,
    queueLimit: Int = 512
  ) {
    self.id = id
    self.options = options
    self.queueLimit = queueLimit
  }

  // MARK: - State

  var isAwaitingAuth: Bool { awaitingAuth }
  func setAwaitingAuth(_ value: Bool) { awaitingAuth = value }

  public var currentCarrier: Carrier { carrier }
  public var isClosed: Bool { closed != nil }
  public var closure: Closure? { closed }
  public var queueDepth: Int { queue.count }

  /// Records client activity. A session with no activity inside `pingTimeout` is reaped.
  public func touch() { lastSeen = .now }

  public func isIdle(beyond timeout: Duration, now: ContinuousClock.Instant = .now) -> Bool {
    now - lastSeen > timeout
  }

  // MARK: - Outbound

  /// Enqueues one already-encoded Engine.IO packet.
  ///
  /// `SocketConnection.send` takes a wire frame, so a caller that already has one — which
  /// `SocketServer.broadcast` does — never has to know about transports.
  public func send(_ frame: String) async {
    guard closed == nil else { return }
    queue.append(frame)
    if queue.count > queueLimit {
      queue.removeFirst(queue.count - queueLimit)
    }
    wakeWaiter()
  }

  /// Takes everything queued, or waits for the first packet.
  ///
  /// The wait is what makes polling a LONG poll: returning an empty body immediately would
  /// put the client in a hot reconnect loop, and every event would be delayed by however
  /// long it takes the client to come back.
  ///
  /// - Parameter timeout: How long to hold the request open with nothing to say. Must be
  ///   comfortably under the client's own request timeout, or the client aborts first.
  func drain(waitingUpTo timeout: Duration) async -> [String] {
    if !queue.isEmpty || closed != nil {
      return takeQueued()
    }

    // One waiter at a time. A second concurrent GET for the same sid is a client bug
    // (or a retry racing its predecessor); the older one is released with nothing
    // rather than left parked forever.
    if let existing = waiter {
      waiter = nil
      existing.resume(returning: [])
    }

    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.wakeWaiter()
    }
    defer { timeoutTask.cancel() }

    return await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  private func takeQueued() -> [String] {
    let packets = queue
    queue.removeAll()
    return packets
  }

  private func wakeWaiter() {
    guard let continuation = waiter else { return }
    waiter = nil
    continuation.resume(returning: takeQueued())
  }

  // MARK: - Transport

  /// Moves the session onto the websocket.
  ///
  /// Anything queued while the upgrade was in flight comes with it — dropping it here is
  /// how an event goes missing exactly once per connection, which is close to impossible
  /// to reproduce after the fact.
  func upgrade() -> [String] {
    carrier = .webSocket
    return takeQueued()
  }

  // MARK: - Closing

  public func close() async {
    close(.normal)
  }

  func close(_ reason: Closure) {
    guard closed == nil else { return }
    closed = reason
    // Released with whatever is queued, so a client that is mid-poll gets the packets
    // that were written before the close rather than an empty body.
    wakeWaiter()
  }
}

//  EngineIOSession
//  One connected client's Engine.IO session, independent of which transport carries it.
//
//  The session outlives the transport, and that is the whole reason it is a separate type.
//  A Socket.IO client ALWAYS opens on polling and upgrades to websocket afterwards, so a
//  single logical connection is served by two different transports in its first second of
//  life. Anything that belongs to the client rather than to the socket (the sid, the
//  negotiated codecs, the outbound queue, whether it has been authenticated) has to survive
//  that switch, or the upgrade silently becomes a reconnect.
//
//  Outbound delivery is a queue with a waiter rather than a direct write, for the same
//  reason: on polling there is no open socket most of the time, so a broadcast has to be
//  parked until the client's next GET. The websocket transport drains the same queue, which
//  is what makes the upgrade a change of drain strategy rather than a change of model.
//
//  See `docs/EVENTS.md`.

import BBAuth
import BBCore
import Foundation

/// One client, for as long as it keeps its sid.
public actor EngineIOSession: SocketConnection {

  public nonisolated let id: SocketID
  public nonisolated let options: SocketClientOptions

  /// Which transport is draining the queue.
  public enum Carrier: Sendable, Equatable {
    case polling
    case webSocket
  }

  /// Why a session ended, so the transport can answer correctly rather than guessing.
  public enum Closure: Sendable, Equatable {
    /// The client asked, or the server is shutting down.
    case normal
    /// Authentication failed. The client is closed WITHOUT an error packet; see
    /// `SocketServer.authenticate`.
    case rejected
    /// No poll and no pong within the timeout.
    case timedOut
  }

  /// True when the handshake carried no credential and the client may still supply one in
  /// its Socket.IO CONNECT `auth` payload. See `EngineIOServer.open`.
  private var awaitingAuth = false

  /// Who the access controller holds responsible for this session, as the handshake resolved
  /// it, with the peer beside it for the audit log.
  ///
  /// Carried on the session because the credential can arrive one request later than the
  /// handshake: an EIO4 client authenticates in its CONNECT `auth` payload, which is a
  /// different HTTP request with its own headers. Resolving the identity again there would
  /// count a failure against whatever address that second request happened to present.
  private(set) var caller = AuthenticationGate.Caller(
    identity: .unresolved, peerAddress: nil, route: EngineIOServer.authPath)

  private var queue: [String] = []
  private var waiter: OnceContinuation<[String]>?
  private var carrier: Carrier = .polling
  private var closed: Closure?
  private var lastSeen: ContinuousClock.Instant = .now

  /// When the session was created, and never touched afterwards.
  ///
  /// Separate from `lastSeen` on purpose, because the two answer different questions and the
  /// auth reaper needs this one. `lastSeen` is "has this client gone quiet", which every poll
  /// refreshes; this is "how long has this session existed", which nothing can refresh. An
  /// unauthenticated session that keeps polling is active by the first measure and overdue by
  /// the second, and it is the second that decides whether it may go on holding a slot.
  private let createdAt: ContinuousClock.Instant = .now

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

  func setCaller(_ value: AuthenticationGate.Caller) { caller = value }

  public var isClosed: Bool { closed != nil }
  public var closure: Closure? { closed }
  public var queueDepth: Int { queue.count }

  /// Records client activity. A session with no activity inside `pingTimeout` is reaped.
  public func touch() { lastSeen = .now }

  public func isIdle(beyond timeout: Duration, now: ContinuousClock.Instant = .now) -> Bool {
    now - lastSeen > timeout
  }

  /// Whether the session has existed for longer than `timeout`, regardless of activity.
  ///
  /// What the auth grace period is actually about: time between the Engine.IO handshake and
  /// the Socket.IO CONNECT that carries the credential. A real client sends CONNECT as its
  /// very next message, so this is generous by construction.
  public func isOlder(than timeout: Duration, now: ContinuousClock.Instant = .now) -> Bool {
    now - createdAt > timeout
  }

  // MARK: - Outbound

  /// Enqueues one already-encoded Engine.IO packet.
  ///
  /// `SocketConnection.send` takes a wire frame, so a caller that already has one (which
  /// `SocketServer.broadcast` does) never has to know about transports.
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

    // Ends at the timeout with whatever is queued, which is nothing unless it raced the
    // wake; and at once, with nothing, when the request is cancelled because the client went
    // away. Whatever is queued then stays queued for the next poll rather than being written
    // to a connection that is no longer there.
    do {
      return try await awaitContinuation(
        timeout: timeout,
        timeoutError: { TimedOut(after: timeout) },
        register: { [weak self] handle in await self?.park(handle) },
        abandon: { [weak self] handle in await self?.release(handle) }
      )
    } catch is TimedOut {
      return takeQueued()
    } catch {
      return []
    }
  }

  /// Parks a poll, or answers it at once if something arrived while it was registering.
  private func park(_ handle: OnceContinuation<[String]>) {
    if !queue.isEmpty || closed != nil {
      handle.resume(returning: takeQueued())
      return
    }
    guard !handle.isResolved else { return }
    // One waiter at a time. A second concurrent GET for the same sid is a client bug
    // (or a retry racing its predecessor); the older one is released with nothing
    // rather than left parked forever.
    waiter?.resume(returning: [])
    waiter = handle
  }

  private func release(_ handle: OnceContinuation<[String]>) {
    if waiter === handle { waiter = nil }
  }

  private func takeQueued() -> [String] {
    let packets = queue
    queue.removeAll()
    return packets
  }

  private func wakeWaiter() {
    guard let waiter else { return }
    self.waiter = nil
    waiter.resume(returning: takeQueued())
  }

  // MARK: - Transport

  /// Moves the session onto the websocket.
  ///
  /// Anything queued while the upgrade was in flight comes with it: dropping it here is
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

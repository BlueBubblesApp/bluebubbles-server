//  SocketTransport
//  The Swift helper's transport: a Unix-domain socket with peer identity verification.
//
//  Why not loopback TCP
//  --------------------
//  A TCP listener on a port derived from the uid accepts anything that connects to it. Any
//  local process (any sandboxed app, any script) can connect and drive the Private
//  API, which means sending messages as the user. It also has to do uid-to-port arithmetic to
//  avoid collisions between accounts, and it can provoke a firewall prompt.
//
//  A Unix-domain socket inside the target app's container fixes reachability: it is reachable
//  only by processes that can traverse that path, which is this user. That is necessary and
//  not sufficient, because "this user" also covers every app the user runs. (The directory's
//  mode is whatever `createDirectory` and the umask produce; nothing here chmods it to `0700`,
//  and the identity check below is what the security actually rests on.) So the peer is
//  identified:
//
//    1. `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` gives the connecting process's AUDIT TOKEN,
//       recorded by the kernel at connect time.
//    2. `SecCodeCopyGuestWithAttributes` turns that token into a code object.
//    3. `SecCodeCheckValidity` checks it against a designated requirement.
//
//  Step 1 is the load-bearing one, and it is an audit token rather than `LOCAL_PEERPID` on
//  purpose: a pid the peer *claims* is worthless, and even a kernel-supplied pid can be
//  reused after exit, so a pid read now and resolved a moment later can name a different
//  process. The audit token carries a pidversion that makes that substitution detectable.
//  See `peerIdentity(of:)` in `SocketTransport+Accepting.swift`, which is where this is
//  actually done.
//
//  Framing is a 4-byte big-endian length prefix rather than newlines. Both sides are ours, so
//  there is no reason to keep a delimiter the payload has to avoid.
//
//  The type is split by concern, one extension file each: `+Lifecycle` binds and tears down
//  the listeners, `+Accepting` identifies the peer, `+Connections` keeps the bookkeeping,
//  `+Sending` routes and correlates requests, and `+Receiving` frames and decodes what the
//  helper sends back. This file holds the type, its stored state and the subscriber streams.
//
//  See `.claude/docs/private-api.md`.

import BBCore
import BBPrivateAPIContract
import Foundation
import Logging
import NIOCore
import NIOPosix

public actor SocketTransport: PrivateAPITransport {

  /// One listening socket, and the app whose helper it serves.
  ///
  /// **Which app a connection belongs to is decided by the socket it arrived on**, not by
  /// what the helper says about itself. There is one socket per app, inside that app's own
  /// container, and a sandboxed app can reach no other (`SocketLocation`), so the listener
  /// already knows who can be on the other end. The helper's registration ping still names
  /// its process, and a name that disagrees with the socket is refused as a protocol error:
  /// routing on the self-report would let one helper claim the other's actions.
  public struct Listener: Sendable, Equatable {
    public let path: String
    /// The bundle identifier of the app this socket serves, or nil for a socket that is not
    /// one app's own: an explicit `BLUEBUBBLES_HELPER_SOCKET` override or a test path, where
    /// either helper may connect and the self-report is all there is to go on.
    public let host: String?

    public init(path: String, host: String?) {
      self.path = path
      self.host = host
    }

    /// The listeners for `paths`, each bound to the app whose container socket it is.
    ///
    /// A path that is exactly one app's `SocketLocation.privateAPISocket(for:)` serves that
    /// app; any other path (and the override, which every app resolves to) serves whichever
    /// helper connects.
    public static func forPaths(_ paths: [String]) -> [Listener] {
      paths.map { path in
        let owners = [HelperHost.messages, HelperHost.faceTime].filter {
          SocketLocation.privateAPISocket(for: $0) == path
        }
        return Listener(path: path, host: owners.count == 1 ? owners[0] : nil)
      }
    }
  }

  let listeners: [Listener]
  var socketPaths: [String] { listeners.map(\.path) }
  let logger: Logger
  let group: any EventLoopGroup
  let ownsGroup: Bool
  let validator: any PeerValidating

  var serverChannels: [any Channel] = []
  /// Every verified connection, what registered on it and what it is carrying. One value,
  /// so dropping a connection is one call: see `HelperConnections`.
  var connections = HelperConnections<any Channel>()

  let transactions: TransactionStore

  /// One continuation per subscriber, keyed by subscription.
  ///
  /// There is more than one consumer of this stream and there always has been: the runtime
  /// watches for `helperRegistered` to know an injection took, and the service that owns the
  /// event bus forwards everything to the sinks. A single shared `AsyncStream` cannot serve
  /// both: an element goes to whichever iterator happens to be waiting, so the two loops
  /// divide the events between them rather than each seeing all of them. That presents as a
  /// helper that "never registered" while it is plainly connected, and as typing indicators
  /// that arrive only sometimes.
  var subscribers: [UUID: AsyncStream<PrivateAPIEvent>.Continuation] = [:]

  /// One inbound frame, on its way from the event loop to `handle`.
  struct InboundFrame: Sendable {
    let payload: Data
    let channel: any Channel
  }

  /// Inbound frames, drained IN ARRIVAL ORDER by one task.
  ///
  /// **The lane is the point.** NIO reassembles frames on the channel's event loop and calls
  /// `onFrame` for each, in order; this used to spawn `Task { await handle(frame:) }` per
  /// frame, which hands that order to the scheduler. Swift promises no FIFO across
  /// separately-created tasks, so the ordering was incidental rather than guaranteed — and
  /// measured, it did hold: forty frames come out in order under the old shape too, because
  /// tasks enqueued back to back from one thread onto an actor that never suspends per frame
  /// are picked up in order in practice. So this hardens a latent race; it does not fix an
  /// observed reordering. It is worth having anyway, because what makes it hold today is the
  /// scheduler's current behaviour under no load, and none of that is a promise.
  ///
  /// For a transaction REPLY that is harmless, and the helper's own read loop says so where
  /// it does the same thing on its side: "the server correlates by transaction id, so replies
  /// may come back out of order". But `handle` decodes EVENTS on the same path, and an event
  /// carries no correlation id: its order IS its meaning. `typing-started` then
  /// `typing-stopped` arriving reversed leaves a typing indicator lit with nothing to clear
  /// it, and `new-message` behind its own `updated-message` applies an edit to a message the
  /// client has not been told about. `EventBus` keeps order per sink, so everything
  /// downstream was already careful; the order was being lost here, one hop earlier.
  ///
  /// Unbounded, and that is not a new risk: one task per frame was unbounded too, in the
  /// actor's own queue rather than in a buffer. Draining costs a JSON decode and a dictionary
  /// write, so the lane empties as fast as a verified helper can fill it, and dropping a
  /// frame would drop a reply somebody is awaiting.
  var frames: AsyncStream<InboundFrame>.Continuation?
  let frameDrain = OwnedTask()

  /// Every path the server binds: one per app it injects into. See `SocketLocation`: a
  /// sandboxed app can only reach a socket inside its OWN container, so two helpers need
  /// two sockets.
  public static func defaultSocketPaths() -> [String] {
    SocketLocation.privateAPISockets
  }

  public init(
    socketPath: String? = nil,
    validator: any PeerValidating,
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.socket")
  ) {
    self.init(
      socketPaths: socketPath.map { [$0] } ?? Self.defaultSocketPaths(),
      validator: validator, group: group, logger: logger
    )
  }

  public init(
    socketPaths: [String],
    validator: any PeerValidating,
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.socket")
  ) {
    self.init(
      listeners: Listener.forPaths(socketPaths.isEmpty ? Self.defaultSocketPaths() : socketPaths),
      validator: validator, group: group, logger: logger)
  }

  public init(
    listeners: [Listener],
    validator: any PeerValidating,
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.socket")
  ) {
    self.listeners =
      listeners.isEmpty ? Listener.forPaths(Self.defaultSocketPaths()) : listeners
    self.validator = validator
    self.logger = logger
    if let group {
      self.group = group
      self.ownsGroup = false
    } else {
      self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      self.ownsGroup = true
    }
    self.transactions = TransactionStore(logger: logger)
  }

  public var isConnected: Bool { !connections.isEmpty }
  public var connectedProcesses: Set<String> { connections.processes }

  /// A new stream per caller. Every subscriber sees every event.
  ///
  /// Each access mints a subscription, so this is a `get` with a side effect, deliberately,
  /// because the protocol requirement is a property and every existing caller reads it once
  /// to drive one `for await`. The stream ends when the subscriber stops iterating or the
  /// transport stops.
  public var events: AsyncStream<PrivateAPIEvent> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .unbounded) { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(id) }
      }
    }
  }

  private func removeSubscriber(_ id: UUID) {
    subscribers[id] = nil
  }

  /// Visible for tests: how many live subscriptions there are.
  var subscriberCount: Int { subscribers.count }
  /// The primary path. Kept singular because callers report "where the socket is"; the
  /// full set is `paths`.
  public var path: String { socketPaths.first ?? "" }
  public var paths: [String] { socketPaths }
}

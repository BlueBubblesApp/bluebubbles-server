//  EngineIOServer
//  Session lifecycle and the Engine.IO state machine, with no transport in it.
//
//  Everything here is expressed as "given this request, what packets go back" so the two
//  transports are thin: the polling endpoints and the websocket handler both call the same
//  methods and differ only in how they carry the strings. That split is what makes the
//  protocol testable without a socket, which matters because Engine.IO fails silently: a
//  wrong frame is ignored by the client rather than rejected, and the symptom is "events
//  stopped arriving" days later.
//
//  Two version differences are load-bearing, and `allowEIO3: true` in the reference
//  says older Flutter clients are still out there:
//
//    - EIO4: the SERVER sends PING and the client answers PONG. EIO3 is the other way round.
//      Getting this backwards means one side eventually declares the connection dead.
//    - EIO4: the client sends Socket.IO CONNECT (`40`) and the server answers. EIO3 clients
//      expect the server to open the default namespace unprompted.
//
//  See `docs/EVENTS.md`.

import BBAuth
import BBCore
import Foundation
import Logging

public actor EngineIOServer {

  public struct Configuration: Sendable {
    /// Transcribed from `socketOpts` in `api/http/index.ts:43-52`. These are not
    /// defaults: a client told `pingTimeout: 120000` waits two minutes before giving
    /// up, and shortening it changes reconnect behaviour in the field.
    public var pingInterval: Duration
    public var pingTimeout: Duration
    public var upgradeTimeout: Duration
    public var maxPayload: Int
    /// How long a poll with nothing to say is held open. Under the client's own request
    /// timeout, and well under `pingTimeout`.
    public var pollHoldTime: Duration
    /// How long a session may sit between its Engine.IO handshake and the Socket.IO CONNECT
    /// that carries its credential.
    ///
    /// Far shorter than `pingTimeout`, and deliberately so: a real client sends CONNECT as
    /// its very next message. `pingTimeout` is two minutes because it governs an ESTABLISHED
    /// session that may legitimately go quiet, which is a different question from how long an
    /// unauthenticated one may loiter.
    public var authGraceTimeout: Duration
    /// How many sessions may be awaiting a credential at once.
    ///
    /// The deferred-auth path creates a live session, with its own frame queue, BEFORE any
    /// credential is checked. Nothing capped that, and the reaper runs on `pingInterval`
    /// against `pingTimeout`, so credential-free handshakes accrued for about three minutes
    /// before anything collected them. The default is far above what a real deployment
    /// reaches: one client opens one session, and even a reconnect storm behind a shared
    /// tunnel resolves each handshake in the same round trip.
    public var maximumAwaitingAuth: Int

    public init(
      pingInterval: Duration = .seconds(60),
      pingTimeout: Duration = .seconds(120),
      upgradeTimeout: Duration = .seconds(30),
      maxPayload: Int = 100_000_000,
      pollHoldTime: Duration = .seconds(25),
      authGraceTimeout: Duration = .seconds(10),
      maximumAwaitingAuth: Int = 32
    ) {
      self.pingInterval = pingInterval
      self.pingTimeout = pingTimeout
      self.upgradeTimeout = upgradeTimeout
      self.maxPayload = maxPayload
      self.pollHoldTime = pollHoldTime
      self.authGraceTimeout = authGraceTimeout
      self.maximumAwaitingAuth = maximumAwaitingAuth
    }
  }

  /// What a transport should do with the result of handling a request.
  public struct Reply: Sendable {
    /// Engine.IO packets to write back, already encoded.
    public var packets: [String]
    /// Close the transport after writing.
    public var shouldClose: Bool

    public init(packets: [String] = [], shouldClose: Bool = false) {
      self.packets = packets
      self.shouldClose = shouldClose
    }
  }

  public enum HandshakeOutcome: Sendable {
    case established(sid: String, packets: [String])
    /// The sid is unknown or expired. The client must start a new session, and the
    /// Engine.IO way to say so is code 1.
    case unknownSession
  }

  private var sessions: [String: EngineIOSession] = [:]

  /// Sessions handshook but not yet authenticated, by sid.
  ///
  /// Held here as well as on the session because it is COUNTED on every deferred handshake,
  /// and asking each session actor in turn would be an await per session on the hot path.
  /// Kept in step with `sessions` by `forget(sid:closing:)`, the one place a session leaves.
  private var awaitingAuth: Set<String> = []

  private let configuration: Configuration
  private let logger: Logger
  private let server: SocketServer
  private let chain: @Sendable () async -> AuthenticationChain

  /// The sequence the HTTP middleware authenticates through, run against the same
  /// `AccessControlService` instance.
  ///
  /// Shared rather than reimplemented, and that is the point: the block list, the lockout
  /// escalation, the per-address counting and the alert that names the address all live in
  /// `AccessControlService`, and one controller across both transports is what stops a
  /// client blocked on HTTP from guessing here instead. What the socket counts differently
  /// from HTTP is spelled out in `AttemptRules`, not here.
  ///
  /// Built with an optional controller because the protocol tests construct an engine with no
  /// server around it; `SocketAccessControlWiringTests` asserts the composition root supplies
  /// one.
  private let gate: AuthenticationGate
  /// Injected so a test can pin the sid rather than matching on a UUID.
  private let makeSessionID: @Sendable () -> String
  private let reaper = OwnedTask()

  /// Whether the Socket integration is switched on: asked at every handshake.
  ///
  /// The transport is mounted by the HTTP service, on the HTTP service's one listener, so
  /// switching the socket off closes no port and unroutes nothing: `/socket.io/` answers
  /// either way. This is what makes "off" mean something to a client.
  private let isAccepting: @Sendable () async -> Bool

  public init(
    server: SocketServer,
    configuration: Configuration = Configuration(),
    chain: @escaping @Sendable () async -> AuthenticationChain,
    accessControl: AccessControlService? = nil,
    auditor: (any AuthenticationAuditing)? = nil,
    isAccepting: @escaping @Sendable () async -> Bool = { true },
    logger: Logger = Logger(label: "bluebubbles.socket.engine"),
    makeSessionID: @escaping @Sendable () -> String = { UUID().uuidString }
  ) {
    self.server = server
    self.configuration = configuration
    self.chain = chain
    self.gate = AuthenticationGate(
      accessControl: accessControl, auditor: auditor, transport: .socket)
    self.isAccepting = isAccepting
    self.logger = logger
    self.makeSessionID = makeSessionID
  }

  public var sessionCount: Int { sessions.count }

  /// How many sessions hold a slot in the deferred-auth pool.
  var awaitingAuthCount: Int { awaitingAuth.count }

  /// What a socket auth failure is recorded against.
  ///
  /// The transport path, which is what `SocketServer.authenticate` already presents to the
  /// chain. It is what a person reads in the failure list to tell a socket attempt from an
  /// API one, so the two have to agree.
  static let authPath = "/socket.io/"

  nonisolated var pingInterval: Duration { configuration.pingInterval }

  func session(_ sid: String) -> EngineIOSession? { sessions[sid] }

  // MARK: - Handshake

  /// Why a handshake was closed without a session. Each one is answered identically on the
  /// wire, which is the point: see `open`.
  private enum HandshakeRefusal {
    case switchedOff
    case blocked
    case tooManyAwaitingAuth(count: Int)
    case credentialRejected

    var logMessage: Logger.Message {
      switch self {
      case .switchedOff: "Refused a socket handshake: the Socket integration is switched off"
      case .blocked: "Refused a socket handshake: the client is blocked"
      case .tooManyAwaitingAuth:
        "Refused a socket handshake: too many sessions are awaiting authentication"
      case .credentialRejected: "Rejected a socket handshake"
      }
    }
  }

  /// Opens a session.
  ///
  /// Authentication happens HERE and its failure is deliberately quiet. A rejected client
  /// gets a complete, successful-looking handshake and is then closed with a bare Engine.IO
  /// CLOSE, which is exactly what `socket.disconnect()` produces today. Sending a
  /// CONNECT_ERROR instead would be more informative and would change client behaviour:
  /// clients RETRY a connect error and stop on a silent close, so being helpful here turns
  /// a wrong password into an infinite reconnect loop.
  ///
  /// Every refusal leaves through `refuse`, so they cannot come to differ on the wire:
  /// anything that distinguishes "blocked" from "wrong password" from "pool full" tells an
  /// attacker what they hit.
  public func open(
    query: [String: String],
    clientAddress: String?,
    forwardedFor: String? = nil
  ) async -> HandshakeOutcome {
    let options = SocketClientOptions.parse(query)
    let sid = makeSessionID()
    let handshake = handshakePacket(sid: sid, options: options)

    // THE SWITCH, and it is checked before a session exists rather than after.
    //
    // Closed the same way a rejected password is, for the same reason: clients RETRY a
    // connect error and STOP on a silent close. Without this the socket service stopping
    // left the transport mounted and the reaper cancelled, so a client handshook
    // successfully, received nothing, never got a ping, timed out, reconnected, and each
    // reconnect left another session nothing would ever reap.
    guard await isAccepting() else {
      return refuse(.switchedOff, sid: sid, handshake: handshake, clientAddress: clientAddress)
    }

    let caller = await gate.identify(
      peerAddress: clientAddress, forwardedFor: forwardedFor, route: Self.authPath)

    // The block list, checked BEFORE the credential, exactly as on HTTP: a blocked client
    // costs nothing after the block lands. `.blocked` ONLY: an unidentifiable client refused
    // its handshake retries, is refused again, and the event stream every client depends on
    // is down for the window. See `AccessDecision.refusesBeforeCredential`.
    guard await gate.admit(caller) else {
      return refuse(.blocked, sid: sid, handshake: handshake, clientAddress: clientAddress)
    }

    // A client that sent no credential in the query is allowed through the Engine.IO
    // handshake and asked again at Socket.IO CONNECT, where socket.io v4 carries an
    // `auth` object. That is the path worth steering clients onto: `auth` is JSON in a
    // packet body, so a password never touches a URL and never has to survive percent
    // encoding, `+`, or a proxy that logs query strings. EIO3 has no such payload, so an
    // EIO3 client with no query credential is refused here as before.
    let hasQueryCredential = !SocketHandshakeScheme.normalize(query: query).isEmpty
    if !hasQueryCredential && options.engineIOVersion >= 4 {
      return await openAwaitingAuth(
        sid: sid, options: options, caller: caller, handshake: handshake)
    }

    let outcome = await server.authenticate(query: query, using: await chain())
    // COUNTED: a wrong password here once produced a log line and nothing else, so no
    // lockout, no block and no alert naming the address, on a transport reachable by
    // anyone who can reach the port. A failure that is the server's own is not.
    await gate.settle(outcome, for: caller, under: .socketHandshake)
    guard case .authenticated = outcome else {
      logServerFault(outcome, sid: sid)
      return refuse(
        .credentialRejected, sid: sid, handshake: handshake, clientAddress: clientAddress)
    }

    let session = EngineIOSession(id: SocketID(sid), options: options)
    await session.setCaller(caller)
    sessions[sid] = session

    var packets = [handshake]
    // EIO3 clients expect the default namespace to be opened for them; EIO4 clients ask.
    // A bare `0` has no payload to serialize, so the encode cannot actually fail, but
    // it is still not worth a `try!`, and dropping the packet degrades to "this EIO3
    // client never connects" rather than to a crash.
    if options.engineIOVersion <= 3, let connect = try? WireFrame.encode(.connect(sid: nil)) {
      packets.append(connect)
      await server.register(session)
    }

    await session.touch()
    logger.info(
      "Socket session opened",
      metadata: [
        "sid": .string(sid),
        "eio": .stringConvertible(options.engineIOVersion),
        "transport": .string(options.transport.rawValue),
      ])
    return .established(sid: sid, packets: packets)
  }

  /// The handshake packet every outcome of `open` begins with, a refusal included.
  private func handshakePacket(sid: String, options: SocketClientOptions) -> String {
    (try? EngineIOHandshake(
      sid: sid,
      upgrades: options.transport == .webSocket ? [] : ["websocket"],
      pingInterval: Int(configuration.pingInterval.seconds * 1000),
      pingTimeout: Int(configuration.pingTimeout.seconds * 1000),
      maxPayload: configuration.maxPayload
    ).encode()) ?? "0{}"
  }

  /// A session whose credential is expected in its CONNECT `auth` payload.
  ///
  /// The cap is applied BEFORE the session exists, so a refused client costs nothing to
  /// remember: no session, no queue, nothing for the reaper to collect. The sweep runs
  /// first, which is what makes this self-healing without a faster timer: whoever is opening
  /// handshakes is also driving the collection of the ones they opened before.
  private func openAwaitingAuth(
    sid: String, options: SocketClientOptions, caller: AuthenticationGate.Caller,
    handshake: String
  ) async -> HandshakeOutcome {
    await sweepExpiredAuthWaiters()
    guard awaitingAuth.count < configuration.maximumAwaitingAuth else {
      return refuse(
        .tooManyAwaitingAuth(count: awaitingAuth.count), sid: sid, handshake: handshake,
        clientAddress: caller.peerAddress)
    }

    // The slot is TAKEN before the first await, in the same synchronous stretch as the
    // check. The session's setters are awaits on another actor, and this actor runs other
    // handshakes while it waits: counting the slot only after them let every handshake
    // arriving in that window pass the check against the same count, and the cap held for
    // sequential clients only.
    let session = EngineIOSession(id: SocketID(sid), options: options)
    sessions[sid] = session
    awaitingAuth.insert(sid)
    await session.setCaller(caller)
    await session.setAwaitingAuth(true)
    await session.touch()
    logger.debug(
      "Socket handshake deferred pending its CONNECT auth payload",
      metadata: ["sid": .string(sid)])
    return .established(sid: sid, packets: [handshake])
  }

  /// The one way a handshake is refused: the handshake, then a bare CLOSE. No session
  /// exists, so a refused client costs nothing to remember.
  private func refuse(
    _ refusal: HandshakeRefusal, sid: String, handshake: String, clientAddress: String?
  ) -> HandshakeOutcome {
    var metadata: Logger.Metadata = ["client": .string(clientAddress ?? "unknown")]
    switch refusal {
    case .tooManyAwaitingAuth(let count): metadata["awaiting"] = .stringConvertible(count)
    case .credentialRejected: metadata["sid"] = .string(sid)
    case .switchedOff, .blocked: break
    }
    logger.info(refusal.logMessage, metadata: metadata)
    return .established(sid: sid, packets: [handshake, EngineIOPacket(type: .close).encode()])
  }

  // MARK: - Inbound

  /// Handles packets the client sent, on either transport.
  public func receive(sid: String, packets: [String]) async -> Reply {
    guard let session = sessions[sid] else { return Reply(shouldClose: true) }
    await session.touch()

    var reply = Reply()
    for raw in packets where !raw.isEmpty {
      guard let packet = EngineIOPacket.decode(raw) else { continue }

      switch packet.type {
      case .ping:
        // EIO3's client-initiated heartbeat, and the `2probe` that opens an upgrade.
        reply.packets.append(
          EngineIOPacket(type: .pong, payload: packet.payload).encode()
        )

      case .pong:
        // EIO4's answer to our PING. `touch()` above is the whole handling.
        break

      case .message:
        if let response = await handleMessage(packet.payload, session: session) {
          reply.packets.append(response)
        }

      case .close:
        await close(sid: sid, reason: .normal)
        reply.shouldClose = true

      case .upgrade:
        _ = await session.upgrade()

      case .open, .noop:
        break
      }
    }
    return reply
  }

  private func handleMessage(_ payload: String, session: EngineIOSession) async -> String? {
    guard let packet = SocketIOPacket.decode(payload) else { return nil }

    switch packet.type {
    case .connect:
      // A deferred handshake is resolved here, from the `auth` payload. Refused the same
      // silent way a bad query password is: no CONNECT_ERROR, because clients RETRY a
      // connect error and stop on a silent close.
      if await session.isAwaitingAuth {
        guard await authenticateDeferred(session, connect: packet) else {
          await close(sid: session.id.rawValue, reason: .rejected)
          return EngineIOPacket(type: .close).encode()
        }
        await session.setAwaitingAuth(false)
        awaitingAuth.remove(session.id.rawValue)
      }

      // Registering here rather than at handshake time is what makes the socket a
      // BROADCAST target only once it is actually ready to receive: broadcasting into
      // a half-open session drops the event with no trace.
      await server.register(session)
      return try? WireFrame.encode(.connect(sid: session.id.rawValue))

    case .disconnect:
      await server.unregister(session.id)
      await session.close(.normal)
      return nil

    case .event, .ack, .binaryEvent, .binaryAck, .connectError:
      // THE SOCKET IS SERVER -> CLIENT ONLY. There is deliberately no inbound command
      // dispatch here and there should never be one.
      //
      // The legacy socket API let clients request and post data over the socket:
      // roughly thirty commands duplicating the REST surface. Every shipping client
      // drives the server over `/api/v1`, and the socket carries live updates and
      // notifications and nothing else. Re-adding inbound handling would mean a second
      // implementation of every endpoint, with its own auth and validation, reachable
      // over a transport that was never designed to carry it.
      //
      // Dropped in silence rather than answered with an `exception` frame: a stray ack
      // from a client is not an error worth surfacing in its UI.
      return nil
    }
  }

  /// Admits and verifies a deferred session's CONNECT, against the caller its handshake
  /// resolved.
  private func authenticateDeferred(
    _ session: EngineIOSession, connect packet: SocketIOPacket
  ) async -> Bool {
    let caller = await session.caller
    let sid = session.id.rawValue

    // Admitted again here and not only at the handshake. This is a second request, and a
    // client admitted a moment ago may have been blocked since by its own failures on this
    // transport or on HTTP; without this, one handshake bought an unlimited number of
    // password attempts.
    guard await gate.admit(caller) else {
      logger.info(
        "Rejected a socket CONNECT: the client is blocked", metadata: ["sid": .string(sid)])
      return false
    }

    let outcome = await authenticate(connect: packet)
    await gate.settle(outcome, for: caller, under: .socketConnect)
    guard case .authenticated = outcome else {
      // Logged, because this is the path clients are steered onto and a bad password here
      // must leave the same trace one in the query does.
      logger.info("Rejected a socket CONNECT: bad credential", metadata: ["sid": .string(sid)])
      logServerFault(outcome, sid: sid)
      return false
    }
    return true
  }

  /// Reads the credential out of a Socket.IO CONNECT packet's `auth` object.
  ///
  /// Its string fields are read exactly as a handshake query is, through
  /// `SocketServer.authenticate`: `{"password": "…"}` (or `guid`, for the same historical
  /// reason the query accepts it) so a client changing transports does not change its
  /// credential shape, and `auth_token` / `access_token` for a bearer token. NOT decoded:
  /// this came out of a JSON body, so it is already the literal value, and `normalize`
  /// decodes nothing either.
  private func authenticate(connect packet: SocketIOPacket) async -> AuthenticationChain.Outcome {
    guard case .object(let auth)? = packet.data else { return .noCredential }
    let fields = auth.compactMapValues(\.stringValue)
    return await server.authenticate(query: fields, using: await chain())
  }

  /// The server could not check a credential. Said at error level, because every client is
  /// refused until it is fixed and nothing else will say so. Silent for any other outcome.
  private func logServerFault(_ outcome: AuthenticationChain.Outcome, sid: String) {
    guard case .failed(let failure) = outcome, !failure.countsAsAttempt else { return }
    logger.error(
      "A socket credential could not be checked",
      metadata: ["sid": .string(sid), "reason": .string(failure.code)])
  }

  // MARK: - Polling

  /// One long-poll. Returns the batched Engine.IO payload body.
  public func poll(sid: String) async -> HandshakeOutcome {
    guard let session = sessions[sid] else { return .unknownSession }
    await session.touch()

    let packets = await session.drain(waitingUpTo: configuration.pollHoldTime)
    if await session.isClosed {
      // Already closed, by a DISCONNECT or by the server; this is the session leaving.
      await forget(sid: sid, closing: nil)
    }
    return .established(sid: sid, packets: packets)
  }

  // MARK: - Upgrade

  /// Hands the websocket everything queued and switches the session's carrier.
  func beginWebSocket(sid: String) async -> [String]? {
    guard let session = sessions[sid] else { return nil }
    await session.touch()
    return await session.upgrade()
  }

  // MARK: - Lifecycle

  public func close(sid: String, reason: EngineIOSession.Closure = .normal) async {
    await forget(sid: sid, closing: reason)
  }

  /// The one way a single session leaves: out of every table that names it, then closed with
  /// `reason` (nil when it is already closed), then unregistered from broadcast.
  ///
  /// One place, because the tables are several and a second exit path is how one of them
  /// gets missed: a session closed by a rejected CONNECT stayed in `awaitingAuth`, counted
  /// against the cap, until the next sweep noticed it had no session.
  private func forget(sid: String, closing reason: EngineIOSession.Closure?) async {
    awaitingAuth.remove(sid)
    guard let session = sessions.removeValue(forKey: sid) else { return }
    if let reason { await session.close(reason) }
    await server.unregister(session.id)
  }

  /// Drops sessions that handshook and never sent their credential.
  ///
  /// Separate from `runMaintenance` and called from the handshake as well, because the
  /// reaper's period is `pingInterval` and the grace period here is much shorter than that.
  /// Waiting for the next tick would let the cap fill with sessions that are already past
  /// their deadline, and refuse a legitimate client on their behalf.
  private func sweepExpiredAuthWaiters() async {
    for sid in awaitingAuth {
      guard let session = sessions[sid] else {
        awaitingAuth.remove(sid)
        continue
      }
      // AGE, not idleness, and the difference is the whole point of this sweep.
      //
      // `isIdle` is measured from `lastSeen`, which `poll(sid:)` refreshes on every request
      // BEFORE anything checks who the caller is. So a client that handshook without a
      // credential and then long-polled every twenty seconds was never idle and was never
      // reaped: it held its slot indefinitely, and nothing counted it as an auth failure, so
      // the per-address lockout never saw it either. Thirty-two of those filled
      // `maximumAwaitingAuth` for good, after which every legitimate client authenticating
      // through the CONNECT payload — the path this file recommends — was refused at
      // handshake with a bare close, which clients do not retry.
      //
      // `createdAt` cannot be refreshed by anything the client does, which is what makes the
      // grace period mean what its own documentation says it means.
      if await session.isOlder(than: configuration.authGraceTimeout) {
        logger.debug(
          "Reaping a socket session that never authenticated",
          metadata: ["sid": .string(sid)])
        await forget(sid: sid, closing: .rejected)
        // Counted as a failure so a caller doing this deliberately meets the same lockout as
        // one guessing passwords. A handshake that expires unauthenticated is not an accident
        // a real client has: it sends CONNECT immediately. See `AttemptRules.counts`.
        await gate.settle(.noCredential, for: await session.caller, under: .socketGraceExpiry)
      }
    }
  }

  /// Sends PING to EIO4 sessions and drops sessions that have gone quiet.
  ///
  /// Both halves matter. Without the ping an idle EIO4 client eventually decides the
  /// server is gone; without the reap, a client that vanished without closing leaves a
  /// session (and its queued broadcasts) in memory forever, which on a server that runs
  /// for months is a slow leak with an attacker-controlled rate.
  public func startMaintenance() {
    guard !reaper.isRunning else { return }
    reaper.runPeriodically(every: pingInterval, after: pingInterval) { [weak self] in
      await self?.runMaintenance()
    }
  }

  public func stopMaintenance() async {
    await reaper.stop()
  }

  func runMaintenance() async {
    // Before the ping sweep: an unauthenticated session has a much shorter deadline than
    // `pingTimeout`, and collecting it here keeps an idle server tidy even when nothing is
    // handshaking to drive the opportunistic sweep.
    await sweepExpiredAuthWaiters()

    let ping = EngineIOPacket(type: .ping).encode()
    for (sid, session) in sessions {
      if await session.isIdle(beyond: configuration.pingTimeout) {
        logger.debug("Reaping an idle socket session", metadata: ["sid": .string(sid)])
        await forget(sid: sid, closing: .timedOut)
        continue
      }
      // EIO3 clients ping us; pinging them too would be answered but is not the
      // protocol, and some clients log it as unexpected.
      if session.options.engineIOVersion >= 4 {
        await session.send(ping)
      }
    }
  }

  /// Closes every session. Used when the password changes and on shutdown.
  ///
  /// The tables are emptied before the first await, so nothing arriving while the sessions
  /// close can find one of them still open: `forget` for every session at once.
  public func closeAll() async {
    let all = sessions
    sessions.removeAll()
    awaitingAuth.removeAll()
    for (_, session) in all {
      await server.unregister(session.id)
      await session.close(.normal)
    }
  }
}

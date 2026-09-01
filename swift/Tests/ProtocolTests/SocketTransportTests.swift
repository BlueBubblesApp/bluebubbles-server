//  SocketTransportTests
//  The Engine.IO state machine, driven the way a client drives it.
//
//  Before this, `BBSocketIO` was a codec and a connection table with nothing mounted: the
//  packet encoders were verified against golden vectors and passed, `SocketServer` had a
//  broadcast method with tests, and NO CLIENT COULD CONNECT. The module tested everything
//  except whether it was reachable.
//
//  So these are deliberately about sequences rather than about frames — the frames already
//  have vector tests. What was missing is "open, poll, connect, receive a broadcast".

import BBAuth
import BBCore
import BBEvents
import BBSerialization
import BBSettings
import Foundation
import Testing

@testable import BBSocketIO

@Suite("Engine.IO transport")
struct SocketTransportTests {

  /// Hands out session ids in order, so a multi-client test can address each one by name
  /// instead of matching on a UUID.
  final class SessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String]
    init(_ pending: [String]) { self.pending = pending }
    func next() -> String {
      lock.lock()
      defer { lock.unlock() }
      return pending.isEmpty ? UUID().uuidString : pending.removeFirst()
    }
  }

  private func engine(
    password: String? = "hunter2hunter2",
    makeSessionID: @escaping @Sendable () -> String = { "SID" }
  ) -> (EngineIOServer, SocketServer) {
    let sockets = SocketServer()
    let chain: @Sendable () async -> AuthenticationChain = {
      AuthenticationChain(schemes: [
        PasswordQueryScheme(passwordProvider: { password.map { PasswordDigest($0) } })
      ])
    }
    return (
      EngineIOServer(server: sockets, chain: chain, makeSessionID: makeSessionID),
      sockets
    )
  }

  private func packets(_ outcome: EngineIOServer.HandshakeOutcome) -> [String] {
    guard case .established(_, let packets) = outcome else { return [] }
    return packets
  }

  // MARK: - Handshake

  @Test("A handshake returns an OPEN packet carrying the session id")
  func handshakeOpens() async throws {
    let (engine, _) = engine()
    let outcome = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: "198.51.100.1"
    )
    let frames = packets(outcome)

    let open = try #require(frames.first, "a handshake must produce an OPEN frame")
    #expect(open.hasPrefix("0{"))
    #expect(open.contains("\"sid\":\"SID\""))
    // The three timeouts are the current server's explicit values, not defaults: a
    // client told `pingTimeout: 120000` waits two minutes before giving up.
    #expect(open.contains("\"pingInterval\":60000"))
    #expect(open.contains("\"pingTimeout\":120000"))
    #expect(open.contains("\"upgrades\":[\"websocket\"]"))
  }

  @Test("A bad password is closed silently, with no error packet")
  func badPasswordClosesWithoutAnError() async {
    // Clients RETRY a connect error and stop on a silent close, so emitting a
    // CONNECT_ERROR here would turn a wrong password into an infinite reconnect loop.
    // The Node server calls `socket.disconnect()`, which is a bare Engine.IO CLOSE.
    let (engine, sockets) = engine()
    let frames = packets(
      await engine.open(
        query: ["EIO": "4", "transport": "polling", "password": "wrong"],
        clientAddress: nil
      ))

    #expect(frames.count == 2)
    #expect(frames.last == "1")
    #expect(frames.contains { $0.hasPrefix("4") } == false, "no CONNECT_ERROR may be sent")
    #expect(await sockets.connectionCount == 0)
    #expect(await engine.sessionCount == 0)
  }

  @Test("An EIO4 client with no query password is asked again at CONNECT")
  func missingQueryPasswordDefersToAuth() async {
    // Not a rejection: socket.io v4 carries credentials in the CONNECT `auth` object,
    // and that is the path worth steering clients onto — a password in a JSON body never
    // has to survive percent encoding, `+`, or a proxy that logs query strings.
    let (engine, sockets) = engine()
    let frames = packets(
      await engine.open(
        query: ["EIO": "4", "transport": "polling"], clientAddress: nil
      ))
    #expect(frames.last != "1", "the handshake should be deferred, not refused")
    #expect(await sockets.connectionCount == 0, "nothing may be registered before auth")
  }

  @Test("An EIO3 client with no password is refused at the handshake")
  func missingPasswordIsRejectedForEIO3() async {
    // EIO3 has no `auth` payload, so there is nothing to wait for.
    let (engine, _) = engine()
    let frames = packets(
      await engine.open(
        query: ["EIO": "3", "transport": "polling"], clientAddress: nil
      ))
    #expect(frames.last == "1")
  }

  @Test("A CONNECT auth payload authenticates the session")
  func connectAuthAuthenticates() async {
    // The escape hatch for a complex password. `p@ss word+1!%20` would have to be
    // encoded in a URL and has historically been mangled on the way back out; here it
    // crosses as JSON and is compared literally.
    let awkward = "p@ss word+1!%20&x=y"
    let (engine, sockets) = engine(password: awkward)
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: nil
    )

    let auth = JSONValue.object(["password": .string(awkward)])
    let connect = try? SocketIOPacket(type: .connect, data: auth).encode()
    let reply = await engine.receive(sid: "SID", packets: ["4" + (connect ?? "")])

    #expect(reply.packets.first?.hasPrefix("40{\"sid\"") == true)
    #expect(await sockets.connectionCount == 1)
  }

  @Test("A wrong CONNECT auth payload closes the session silently")
  func connectAuthRejects() async {
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: nil
    )

    let auth = JSONValue.object(["password": .string("wrong")])
    let connect = try? SocketIOPacket(type: .connect, data: auth).encode()
    let reply = await engine.receive(sid: "SID", packets: ["4" + (connect ?? "")])

    // Same silent close as a bad query password: no CONNECT_ERROR, because clients retry
    // a connect error and stop on a silent close.
    #expect(reply.packets == ["1"])
    #expect(await sockets.connectionCount == 0)
    #expect(await engine.sessionCount == 0)
  }

  @Test("A CONNECT with no auth payload closes a deferred session")
  func connectWithoutAuthRejects() async {
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: nil
    )
    let reply = await engine.receive(sid: "SID", packets: ["40"])
    #expect(reply.packets == ["1"])
    #expect(await sockets.connectionCount == 0)
  }

  // MARK: - Connect

  @Test("An EIO4 client is registered once it sends CONNECT")
  func eio4ConnectsExplicitly() async {
    // EIO4 opens the namespace itself. Registering at handshake time instead would make
    // the socket a broadcast target before it is ready, and those events vanish.
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    #expect(await sockets.connectionCount == 0)

    let reply = await engine.receive(sid: "SID", packets: ["40"])
    #expect(reply.packets.first?.hasPrefix("40{\"sid\"") == true)
    #expect(await sockets.connectionCount == 1)
  }

  @Test("An EIO3 client is connected without being asked")
  func eio3ConnectsImplicitly() async {
    // `allowEIO3: true` is load-bearing for older Flutter clients, and socket.io v2
    // expects the server to open the default namespace unprompted.
    let (engine, sockets) = engine()
    let frames = packets(
      await engine.open(
        query: ["EIO": "3", "transport": "polling", "password": "hunter2hunter2"],
        clientAddress: nil
      ))
    #expect(frames.contains("40"))
    #expect(await sockets.connectionCount == 1)
  }

  // MARK: - Heartbeat

  @Test("An EIO3 client's PING is answered with PONG")
  func eio3PingIsAnswered() async {
    // EIO3: the CLIENT pings. EIO4: the server does. Getting this backwards means one
    // side eventually declares the connection dead.
    let (engine, _) = engine()
    _ = await engine.open(
      query: ["EIO": "3", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    let reply = await engine.receive(sid: "SID", packets: ["2"])
    #expect(reply.packets == ["3"])
  }

  @Test("The upgrade probe is answered")
  func upgradeProbeIsAnswered() async {
    // `2probe` -> `3probe`. Without it the upgrade fails silently and the client stays
    // on polling forever — working, but with every event delayed by a poll cycle.
    let (engine, _) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    let reply = await engine.receive(sid: "SID", packets: ["2probe"])
    #expect(reply.packets == ["3probe"])
  }

  @Test("Only EIO4 sessions are sent a server PING")
  func maintenancePingsOnlyEIO4() async {
    let (engine, _) = engine(makeSessionID: { "V4" })
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "V4", packets: ["40"])

    await engine.runMaintenance()
    let queued = await engine.session("V4")?.queueDepth ?? 0
    #expect(queued == 1)
  }

  // MARK: - Delivery

  @Test("A broadcast reaches a connected client's next poll")
  func broadcastIsDelivered() async {
    // The end-to-end assertion the module could not previously make: an event goes onto
    // the bus and comes back out of an HTTP poll as a Socket.IO EVENT frame.
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])

    await sockets.broadcast(
      ServerEvent(
        name: .newMessage,
        fullPayload: .object(["guid": .string("MSG-1")]),
        notificationPayload: .object(["guid": .string("MSG-1")])
      )
    )

    let frames = packets(await engine.poll(sid: "SID"))
    let event = frames.first { $0.hasPrefix("42") }
    #expect(event != nil, "the broadcast never reached the poll")
    #expect(event?.contains("new-message") == true)
    // The RAW object, never envelope-wrapped: clients read fields straight off it.
    #expect(event?.contains("\"guid\":\"MSG-1\"") == true)
    #expect(event?.contains("\"status\"") == false)
  }

  @Test("A poll with several queued events returns them record-separated")
  func pollBatchesWithRecordSeparator() async {
    // U+001E, not a comma and not a newline. A client splitting on the wrong character
    // sees one malformed packet and drops the whole batch.
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])

    for index in 0..<3 {
      await sockets.broadcast(
        ServerEvent(
          name: .newMessage,
          fullPayload: .object(["n": .int64(Int64(index))]),
          notificationPayload: .null
        )
      )
    }

    let body = EngineIOPayload.encode(packets(await engine.poll(sid: "SID")))
    #expect(body.split(separator: "\u{1e}").count == 3)
  }

  @Test("A poll with nothing queued waits rather than returning empty")
  func pollWaitsForAnEvent() async throws {
    // Returning immediately would put the client in a hot reconnect loop and delay every
    // event by however long it takes it to come back.
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])

    async let polled = engine.poll(sid: "SID")
    try await Task.sleep(for: .milliseconds(50))
    await sockets.broadcast(
      ServerEvent(name: .typingIndicator, fullPayload: .null, notificationPayload: .null)
    )

    let frames = packets(await polled)
    #expect(frames.contains { $0.contains("typing-indicator") })
  }

  // MARK: - Sessions

  @Test("An unknown sid is reported as an unknown session")
  func unknownSessionIsReported() async {
    // Engine.IO code 1. The client's correct response is to open a NEW session, which is
    // why it must not read as "no such endpoint".
    let (engine, _) = engine()
    guard case .unknownSession = await engine.poll(sid: "nope") else {
      Issue.record("Expected an unknown-session outcome")
      return
    }
  }

  @Test("Inbound client events are ignored, not dispatched")
  func inboundEventsAreIgnored() async {
    // The socket is server -> client only. The legacy socket API let clients request and
    // post data over it — roughly thirty commands duplicating the REST surface — and
    // every shipping client now uses `/api/v1` instead. Answering here would mean a
    // second implementation of every endpoint with its own auth, over a transport that
    // was never designed to carry it.
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])

    let commands = [
      "42[\"get-chats\",{}]",
      "42[\"send-message\",{\"chatGuid\":\"x\"}]",
      "421[\"get-server-metadata\",{}]",
      "43[\"ack\"]",
    ]
    for command in commands {
      let reply = await engine.receive(sid: "SID", packets: [command])
      #expect(reply.packets.isEmpty, "\(command) produced a response")
      #expect(!reply.shouldClose, "\(command) closed the connection")
    }
    // And the client stays connected — a stray command is not an error worth
    // disconnecting a working client over.
    #expect(await sockets.connectionCount == 1)
  }

  @Test("A client that closes is unregistered")
  func closeUnregisters() async {
    let (engine, sockets) = engine()
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])
    #expect(await sockets.connectionCount == 1)

    let reply = await engine.receive(sid: "SID", packets: ["1"])
    #expect(reply.shouldClose)
    #expect(await sockets.connectionCount == 0)
    #expect(await engine.sessionCount == 0)
  }

  @Test("Several clients each get their own session and every broadcast")
  func multipleClientsAreIndependent() async {
    // An install serves an Android phone and two desktops at once. One client's session
    // must not be another's, and a broadcast goes to all of them.
    let ids = SessionIDs(["A", "B", "C"])
    let (engine, sockets) = engine(makeSessionID: { ids.next() })

    for _ in 0..<3 {
      _ = await engine.open(
        query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
        clientAddress: nil
      )
    }
    for sid in ["A", "B", "C"] {
      _ = await engine.receive(sid: sid, packets: ["40"])
    }
    #expect(await sockets.connectionCount == 3)

    await sockets.broadcast(
      ServerEvent(
        name: .newMessage,
        fullPayload: .object(["guid": .string("MSG-1")]),
        notificationPayload: .null
      )
    )

    for sid in ["A", "B", "C"] {
      let frames = packets(await engine.poll(sid: sid))
      #expect(
        frames.contains { $0.contains("MSG-1") },
        "client \(sid) did not receive the broadcast"
      )
    }

    // And one leaving does not disturb the others.
    _ = await engine.receive(sid: "B", packets: ["1"])
    #expect(await sockets.connectionCount == 2)
  }

  @Test("An idle session is reaped")
  func idleSessionsAreReaped() async {
    // A client that vanished without closing otherwise leaves its session and its queued
    // broadcasts in memory for the life of the process.
    let sockets = SocketServer()
    let engine = EngineIOServer(
      server: sockets,
      configuration: .init(pingTimeout: .milliseconds(1)),
      chain: {
        AuthenticationChain(schemes: [
          PasswordQueryScheme(passwordProvider: { PasswordDigest("hunter2hunter2") })
        ])
      },
      makeSessionID: { "SID" }
    )
    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
      clientAddress: nil
    )
    _ = await engine.receive(sid: "SID", packets: ["40"])
    #expect(await engine.sessionCount == 1)

    try? await Task.sleep(for: .milliseconds(20))
    await engine.runMaintenance()
    #expect(await engine.sessionCount == 0)
    #expect(await sockets.connectionCount == 0)
  }

  @Test("Closing every session leaves nothing registered")
  func closeAllClears() async {
    // What a password change does. A client holding the old password must not stay on an
    // already-open socket.
    let ids = SessionIDs(["A", "B"])
    let (engine, sockets) = engine(makeSessionID: { ids.next() })
    for _ in 0..<2 {
      _ = await engine.open(
        query: ["EIO": "4", "transport": "polling", "password": "hunter2hunter2"],
        clientAddress: nil
      )
    }
    for sid in ["A", "B"] { _ = await engine.receive(sid: sid, packets: ["40"]) }

    await engine.closeAll()
    #expect(await engine.sessionCount == 0)
    #expect(await sockets.connectionCount == 0)
  }

  @Test("A client that stops polling cannot grow the queue without bound")
  func outboundQueueIsBounded() async {
    // The queue is what makes polling work, and it is also an unbounded buffer keyed to
    // a client that may never come back.
    let session = EngineIOSession(
      id: SocketID("SID"), options: SocketClientOptions(), queueLimit: 4
    )
    for index in 0..<20 { await session.send("4\(index)") }
    #expect(await session.queueDepth == 4)

    // The NEWEST are kept: a client this far behind has to resync anyway.
    let drained = await session.drain(waitingUpTo: .zero)
    #expect(drained == ["416", "417", "418", "419"])
  }
}

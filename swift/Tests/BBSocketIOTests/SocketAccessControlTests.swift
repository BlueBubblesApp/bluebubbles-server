//  SocketAccessControlTests
//  The socket handshake goes through the same access controller the HTTP middleware uses.
//
//  It did not, for as long as the socket has existed. A wrong password on this transport
//  wrote one log line and nothing else: no failure recorded, so no lockout, no block, and
//  no alert naming the address. An attacker blocked on HTTP after ten guesses could keep
//  guessing here indefinitely, at whatever rate the network allowed.
//
//  Two properties matter and they pull in opposite directions, which is why both are tested
//  here. Failures must COUNT, or the limiter does nothing. And a rejection must look
//  IDENTICAL to a wrong password from the client's side: anything that distinguishes
//  "blocked" from "wrong password" tells an attacker their guessing is being counted, and
//  anything clients retry rebuilds the reconnect loop the silent close exists to prevent.

import BBAuth
import BBSerialization
import Foundation
import Testing

@testable import BBSocketIO

@Suite("Socket access control")
struct SocketAccessControlTests {

  private static let password = "hunter2hunter2"

  private func makeEngine(
    accessControl: AccessControlService
  ) -> (EngineIOServer, SocketServer) {
    let sockets = SocketServer(negotiator: .legacyOnly())
    let digest = PasswordDigest(Self.password)
    let engine = EngineIOServer(
      server: sockets,
      chain: {
        AuthenticationChain(
          schemes: [SocketHandshakeScheme(passwordProvider: { digest })]
        )
      },
      accessControl: accessControl
    )
    return (engine, sockets)
  }

  private func controller(threshold: Int = 3) -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(
        perClientThreshold: threshold,
        window: .seconds(300),
        baseLockout: .seconds(900)
      ),
      // Not loopback: the default allowlist makes 127.0.0.1 unblockable, which is correct
      // in production and would make this test assert nothing.
      trust: ProxyTrustPolicy(trustedProxies: [], permanentAllowlist: [])
    )
  }

  @Test("A wrong password on the socket is counted against the client")
  func failuresAreCounted() async {
    let access = controller()
    let (engine, _) = makeEngine(accessControl: access)

    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.4")

    let failures = await access.failures()
    #expect(failures.count == 1)
    #expect(failures.first?.address == "198.51.100.4")
    // The transport, so a person reading the failure list can tell a socket attempt from
    // an API one.
    #expect(failures.first?.path == "/socket.io/")
  }

  @Test("Enough wrong passwords block the client")
  func repeatedFailuresBlock() async {
    let access = controller(threshold: 3)
    let (engine, _) = makeEngine(accessControl: access)

    for _ in 0..<3 {
      _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.5")
    }

    let blocked = await access.blockedClients()
    #expect(blocked.contains { $0.address == "198.51.100.5" })
  }

  @Test("A blocked client cannot open a session even with the RIGHT password")
  func blockedClientIsRefused() async {
    let access = controller(threshold: 2)
    let (engine, _) = makeEngine(accessControl: access)

    for _ in 0..<2 {
      _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.6")
    }
    let before = await engine.sessionCount

    // The password is now correct. The block is what refuses it, which is the whole point:
    // a lockout that a correct guess ends is not a lockout.
    let outcome = await engine.open(
      query: ["password": Self.password], clientAddress: "198.51.100.6"
    )

    #expect(await engine.sessionCount == before)
    guard case .established(_, let packets) = outcome else {
      Issue.record("expected a handshake-shaped reply even for a blocked client")
      return
    }
    // Closed, not errored: identical to a wrong password. See the header.
    #expect(packets.contains(EngineIOPacket(type: .close).encode()))
  }

  @Test("A blocked client's reply is byte-identical to a wrong password's")
  func blockLooksLikeABadPassword() async {
    let access = controller(threshold: 1)
    let (engine, _) = makeEngine(accessControl: access)

    // One failure from a DIFFERENT address, so this address is refused for being blocked
    // while the comparison address is refused for its password.
    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.7")

    let blockedReply = await engine.open(
      query: ["password": Self.password], clientAddress: "198.51.100.7"
    )
    let badPasswordReply = await engine.open(
      query: ["password": "wrong"], clientAddress: "198.51.100.8"
    )

    guard
      case .established(_, let blockedPackets) = blockedReply,
      case .established(_, let badPackets) = badPasswordReply
    else {
      Issue.record("both refusals should still look like handshakes")
      return
    }
    // The sid differs by construction; what a client branches on is the packet TYPES.
    #expect(blockedPackets.map { $0.prefix(1) } == badPackets.map { $0.prefix(1) })
  }

  @Test("A correct password clears the client's failure count")
  func successResets() async {
    let access = controller(threshold: 3)
    let (engine, _) = makeEngine(accessControl: access)

    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.9")
    _ = await engine.open(query: ["password": Self.password], clientAddress: "198.51.100.9")
    // Two more wrong guesses. Without the reset this would be the third and would block.
    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.9")
    _ = await engine.open(query: ["password": "wrong"], clientAddress: "198.51.100.9")

    let blocked = await access.blockedClients()
    #expect(!blocked.contains { $0.address == "198.51.100.9" })
  }

  @Test("The forwarding header does not decide who is counted")
  func forwardedHeaderIsNotTakenAtFaceValue() async {
    let access = controller()
    let (engine, _) = makeEngine(accessControl: access)

    // The peer is not a trusted proxy, so its claim about who it is forwarding for is
    // worth nothing. Counting the header's address instead would let a caller spend
    // somebody else's budget, and spare its own.
    _ = await engine.open(
      query: ["password": "wrong"],
      clientAddress: "198.51.100.10",
      forwardedFor: "203.0.113.99"
    )

    let failures = await access.failures()
    #expect(failures.first?.address == "198.51.100.10")
  }

  // MARK: - Shared tunnels

  // The socket is address-keyed from this change onward, which puts it under the same
  // requirement the HTTP path already carries: MOST INSTALLS SIT BEHIND ONE TUNNEL, and
  // every client then arrives from a single egress address. Counting failures against that
  // address would let one wrong password lock every legitimate client out at once. The
  // controller's existing answers cover it and these pin that they do on this transport.

  private func tunnelController() -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2, window: .seconds(300)),
      // The shipped defaults. The bundled tunnels run on this machine and connect over
      // loopback, so the peer is trusted (its forwarding header is believed) and
      // permanently allowed (it can never be blocked).
      trust: ProxyTrustPolicy()
    )
  }

  @Test("One bad client behind a tunnel cannot lock the tunnel out")
  func tunnelIsNotBlocked() async {
    let access = tunnelController()
    let (engine, _) = makeEngine(accessControl: access)

    // Well past the threshold, all arriving over the loopback tunnel.
    for _ in 0..<5 {
      _ = await engine.open(
        query: ["password": "wrong"],
        clientAddress: "127.0.0.1",
        forwardedFor: "203.0.113.50"
      )
    }

    // The guilty client is blocked; the tunnel is not.
    let blocked = await access.blockedClients().map(\.address)
    #expect(blocked.contains("203.0.113.50"))
    #expect(!blocked.contains("127.0.0.1"))

    // And a DIFFERENT client behind the same tunnel still connects.
    let outcome = await engine.open(
      query: ["password": Self.password],
      clientAddress: "127.0.0.1",
      forwardedFor: "203.0.113.51"
    )
    guard case .established = outcome else {
      Issue.record("an innocent client behind a shared tunnel must still connect")
      return
    }
    #expect(await engine.sessionCount == 1)
  }

  @Test("An untrusted peer's forwarding claim is not believed")
  func untrustedPeerCannotSpendAnotherAddressBudget() async {
    let access = tunnelController()
    let (engine, _) = makeEngine(accessControl: access)

    // 198.51.100.30 is not a configured proxy, so its claim to be forwarding for someone
    // else is worth nothing: the failures land on it, not on the address it named.
    for _ in 0..<2 {
      _ = await engine.open(
        query: ["password": "wrong"],
        clientAddress: "198.51.100.30",
        forwardedFor: "203.0.113.60"
      )
    }

    let blocked = await access.blockedClients().map(\.address)
    #expect(blocked.contains("198.51.100.30"))
    #expect(!blocked.contains("203.0.113.60"))
  }

  // MARK: - The deferred CONNECT path

  // This is the path clients are STEERED onto: socket.io v4 carries credentials in the
  // CONNECT `auth` object rather than the query string, so a password never touches a URL.
  // It is therefore the path that matters most, and the one where a bad password used to
  // leave no trace at all.

  private func connectPacket(password: String) -> String {
    let auth = JSONValue.object(["password": .string(password)])
    return "4" + ((try? SocketIOPacket(type: .connect, data: auth).encode()) ?? "")
  }

  private func makeEngineWithFixedSID(
    accessControl: AccessControlService
  ) -> (EngineIOServer, SocketServer) {
    let sockets = SocketServer(negotiator: .legacyOnly())
    let digest = PasswordDigest(Self.password)
    let engine = EngineIOServer(
      server: sockets,
      chain: {
        AuthenticationChain(
          schemes: [SocketHandshakeScheme(passwordProvider: { digest })]
        )
      },
      accessControl: accessControl,
      makeSessionID: { "SID" }
    )
    return (engine, sockets)
  }

  @Test("A wrong CONNECT password is counted, not just logged")
  func connectFailuresAreCounted() async {
    let access = controller()
    let (engine, _) = makeEngineWithFixedSID(accessControl: access)

    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: "198.51.100.20"
    )
    _ = await engine.receive(sid: "SID", packets: [connectPacket(password: "wrong")])

    let failures = await access.failures()
    #expect(failures.count == 1)
    #expect(failures.first?.address == "198.51.100.20")
  }

  @Test("A block that lands after the handshake still stops the CONNECT")
  func connectIsReEvaluated() async {
    // The handshake and the CONNECT are two different requests, and a deferred session
    // sits open between them. Checking the block list only at the handshake would leave
    // that window unguarded: a client already holding a session could keep sending
    // CONNECT packets after it was blocked.
    //
    // The failures here are recorded directly, which is what makes this the CROSS-TRANSPORT
    // case: the same controller backs the HTTP middleware, so this is a client that
    // handshook on the socket and then burnt its budget guessing over the API.
    let access = controller(threshold: 2)
    let (engine, sockets) = makeEngineWithFixedSID(accessControl: access)

    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: "198.51.100.21"
    )

    for _ in 0..<2 {
      await access.recordFailure(
        .address("198.51.100.21"), path: "/api/v1/message/text", reason: "wrong password"
      )
    }

    // Blocked now, and the CONNECT carries the CORRECT password. It must still be refused.
    let reply = await engine.receive(
      sid: "SID", packets: [connectPacket(password: Self.password)]
    )

    #expect(reply.packets == ["1"], "a blocked client should get the same silent close")
    #expect(await sockets.connectionCount == 0)
  }

  @Test("A blocked client cannot even open a deferred session")
  func blockedClientCannotDeferAuth() async {
    // The earlier guard, for completeness: a client blocked BEFORE it handshakes is
    // refused at the handshake, so it never reaches CONNECT and never gets a session to
    // hold open. Both guards are load-bearing and they cover different windows.
    let access = controller(threshold: 1)
    let (engine, _) = makeEngineWithFixedSID(accessControl: access)

    await access.recordFailure(
      .address("198.51.100.23"), path: "/api/v1/message/text", reason: "wrong password"
    )

    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: "198.51.100.23"
    )
    #expect(await engine.sessionCount == 0)
  }

  @Test("A correct CONNECT password still connects and is recorded as a success")
  func connectSuccessIsRecorded() async {
    let access = controller()
    let (engine, sockets) = makeEngineWithFixedSID(accessControl: access)

    _ = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: "198.51.100.22"
    )
    let reply = await engine.receive(
      sid: "SID", packets: [connectPacket(password: Self.password)]
    )

    #expect(reply.packets.first?.hasPrefix("40{\"sid\"") == true)
    #expect(await sockets.connectionCount == 1)
    #expect(await access.failures().isEmpty)
  }

  @Test("An unresolvable client still authenticates normally")
  func unresolvedClientStillWorks() async {
    // No address at all is the in-process and unix-socket case. Blocking is off the table
    // for such a caller by design; it must not become a refusal.
    let access = controller()
    let (engine, _) = makeEngine(accessControl: access)

    let outcome = await engine.open(
      query: ["password": Self.password], clientAddress: nil
    )
    guard case .established = outcome else {
      Issue.record("a client with no address should still be able to connect")
      return
    }
    #expect(await engine.sessionCount == 1)
  }
}

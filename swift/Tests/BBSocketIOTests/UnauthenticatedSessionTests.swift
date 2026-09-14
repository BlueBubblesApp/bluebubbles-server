//  UnauthenticatedSessionTests
//  What an unauthenticated socket session costs, and for how long.
//
//  The deferred-auth path is the one clients are steered onto: a socket.io v4 client sends no
//  credential in the query and supplies it in the CONNECT `auth` payload instead, so the
//  handshake has to succeed before anything has been checked. That means a LIVE SESSION,
//  with its own frame queue, exists for a caller who has proved nothing.
//
//  Nothing capped how many of those there could be, and the collection schedule made it
//  worse rather than better: the reaper runs on `pingInterval` (60s) and reaps at
//  `pingTimeout` (120s), both sized for an ESTABLISHED session that may legitimately go
//  quiet. An unauthenticated one has no such claim on the server, and used to get the same
//  two-minute grace.
//
//  Two properties are tested here, and the second is why the first is safe: the cap holds,
//  and a real client is never refused because of it, because expired waiters are collected
//  on the way in rather than only on the timer.

import BBAuth
import BBSerialization
import Foundation
import Testing

@testable import BBSocketIO

@Suite("Unauthenticated socket sessions")
struct UnauthenticatedSessionTests {

  private static let password = "hunter2hunter2"

  /// Short deadlines and a small cap, so the behaviour is testable without sleeping through
  /// the shipping ten seconds. The defaults are asserted separately below.
  private func engine(
    grace: Duration = .milliseconds(60),
    cap: Int = 3
  ) -> (EngineIOServer, SocketServer) {
    let sockets = SocketServer(negotiator: .legacyOnly())
    let digest = PasswordDigest(Self.password)
    let engine = EngineIOServer(
      server: sockets,
      configuration: .init(authGraceTimeout: grace, maximumAwaitingAuth: cap),
      chain: {
        AuthenticationChain(
          schemes: [SocketHandshakeScheme(passwordProvider: { digest })]
        )
      }
    )
    return (engine, sockets)
  }

  /// An EIO4 handshake with no credential: the deferred path.
  private func deferredHandshake(
    _ engine: EngineIOServer
  ) async -> EngineIOServer.HandshakeOutcome {
    await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: "198.51.100.40")
  }

  private func isClosed(_ outcome: EngineIOServer.HandshakeOutcome) -> Bool {
    guard case .established(_, let packets) = outcome else { return false }
    return packets.contains(EngineIOPacket(type: .close).encode())
  }

  @Test("Sessions awaiting a credential are capped")
  func capIsEnforced() async {
    let (engine, _) = engine(cap: 3)

    for _ in 0..<3 {
      let outcome = await deferredHandshake(engine)
      #expect(!isClosed(outcome), "a handshake within the cap should be allowed")
    }
    #expect(await engine.sessionCount == 3)

    // The fourth is refused, and no session is created for it.
    let refused = await deferredHandshake(engine)
    #expect(isClosed(refused), "a handshake past the cap should be closed")
    #expect(await engine.sessionCount == 3, "a refused handshake must not create a session")
  }

  @Test("A refused handshake looks exactly like a wrong password")
  func refusalIsIndistinguishable() async {
    let (engine, _) = engine(cap: 1)
    _ = await deferredHandshake(engine)

    let overCap = await deferredHandshake(engine)
    let wrongPassword = await engine.open(
      query: ["password": "wrong"], clientAddress: "198.51.100.41")

    guard
      case .established(_, let capPackets) = overCap,
      case .established(_, let badPackets) = wrongPassword
    else {
      Issue.record("both refusals should still look like handshakes")
      return
    }
    // Anything that distinguishes one refusal from another tells an attacker which wall
    // they hit. The sid differs by construction; the packet TYPES are what a client reads.
    #expect(capPackets.map { $0.prefix(1) } == badPackets.map { $0.prefix(1) })
  }

  @Test("An expired waiter is collected, and its place is given back")
  func expiredWaitersAreSwept() async throws {
    let (engine, _) = engine(grace: .milliseconds(60), cap: 2)

    _ = await deferredHandshake(engine)
    _ = await deferredHandshake(engine)
    #expect(await engine.sessionCount == 2)
    #expect(isClosed(await deferredHandshake(engine)), "the cap should be full")

    // Past the grace period, the two that never authenticated are collected. This is the
    // property that makes the cap safe: it is swept ON THE WAY IN, so a real client
    // arriving after an attacker is not refused on their behalf.
    try await Task.sleep(for: .milliseconds(120))

    let allowed = await deferredHandshake(engine)
    #expect(!isClosed(allowed), "a client should be admitted once the waiters expire")
    #expect(await engine.sessionCount == 1, "the expired sessions should be gone")
  }

  @Test("Authenticating frees the slot immediately")
  func authenticatingFreesTheSlot() async {
    // A session that completes CONNECT is no longer awaiting anything and must stop
    // counting against the cap, or a busy server would refuse clients on behalf of the ones
    // that already succeeded.
    let sockets = SocketServer(negotiator: .legacyOnly())
    let digest = PasswordDigest(Self.password)
    let engine = EngineIOServer(
      server: sockets,
      configuration: .init(authGraceTimeout: .seconds(30), maximumAwaitingAuth: 1),
      chain: {
        AuthenticationChain(
          schemes: [SocketHandshakeScheme(passwordProvider: { digest })]
        )
      },
      makeSessionID: { "SID" }
    )

    _ = await engine.open(query: ["EIO": "4", "transport": "polling"], clientAddress: nil)
    let auth = JSONValue.object(["password": .string(Self.password)])
    let connect = "4" + ((try? SocketIOPacket(type: .connect, data: auth).encode()) ?? "")
    _ = await engine.receive(sid: "SID", packets: [connect])

    // The cap is one, and the only waiter has now authenticated.
    let next = await engine.open(
      query: ["EIO": "4", "transport": "polling"], clientAddress: nil)
    #expect(!isClosed(next), "an authenticated session must not hold a waiting slot")
  }

  @Test("A handshake that carries its password is not subject to the cap")
  func queryCredentialBypassesTheCap() async {
    // The cap exists for sessions created BEFORE a credential is seen. One that arrives
    // with a valid password is checked immediately and never enters that state.
    let (engine, _) = engine(cap: 1)
    _ = await deferredHandshake(engine)

    for _ in 0..<5 {
      let outcome = await engine.open(
        query: ["password": Self.password], clientAddress: "198.51.100.42")
      #expect(!isClosed(outcome), "an authenticated handshake should never hit the cap")
    }
  }

  @Test("An EIO3 client with no credential is still refused outright")
  func eio3IsUnchanged() async {
    // EIO3 has no `auth` payload, so there is nothing to defer to: it was refused before
    // this change and must still be, without consuming a waiting slot.
    let (engine, _) = engine(cap: 1)
    let outcome = await engine.open(
      query: ["EIO": "3", "transport": "polling"], clientAddress: nil)

    #expect(isClosed(outcome))
    #expect(await engine.sessionCount == 0)
  }

  @Test("The shipping defaults are the ones described")
  func defaults() {
    // The tests above run with short deadlines; this is what a real server uses.
    let configuration = EngineIOServer.Configuration()
    #expect(configuration.authGraceTimeout == .seconds(10))
    #expect(configuration.maximumAwaitingAuth == 32)
    // The grace must stay well under the established-session timeout, which is the whole
    // distinction being drawn.
    #expect(configuration.authGraceTimeout < configuration.pingTimeout)
  }
}

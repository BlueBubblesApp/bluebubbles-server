//  GlobalThrottleTests
//  Global throttling must never refuse a client that is sending the right password.
//
//  `AccessControlService` answers `.throttled` for `.unresolved`, which is every client behind
//  a proxy that does not identify them — and on the shipped trust policy that is any tunnel
//  which forwards no `X-Forwarded-For`, because loopback is trusted and there is nothing to
//  read through it.
//
//  `AuthenticationStage.admit` refused `.blocked` and `.throttled` with one `case`, and the two
//  are not the same answer. `.blocked` names one client that has already failed ten times.
//  `.throttled` names nobody, so refusing on it meant `globalThreshold` bad guesses locked out
//  EVERY client on the install, correct password included, for a rolling window an attacker can
//  hold open from anywhere. That is the outage `AccessControl`'s own header says the unresolved
//  path exists to avoid.
//
//  Both halves are asserted here, because a test for the first alone would pass just as well if
//  the refusal had been deleted outright rather than split.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BlueBubblesServerCore

@Suite("Global throttling")
struct GlobalThrottleTests {

  private static let password = "correct-horse-battery-staple"
  private static let handlerID = HandlerID("throttle.probe")

  /// The shipped defaults, with a threshold a test can reach: loopback is a trusted proxy and
  /// is permanently allowlisted, which is what makes a header-less request from it resolve to
  /// `.unresolved` rather than to an address.
  private func unidentifiedTunnel() -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2, globalThreshold: 3),
      trust: ProxyTrustPolicy()
    )
  }

  /// Trusting nothing, so the same loopback caller resolves as an ordinary address and CAN be
  /// blocked. This is what an install with no reverse proxy sees.
  private func attributable() -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 2),
      trust: ProxyTrustPolicy(
        trustedProxies: [], permanentAllowlist: [], honorForwardedFor: false
      )
    )
  }

  private func withServer(
    accessControl: AccessControlService,
    _ body: (Int) async throws -> Void
  ) async throws {
    let group = RouteGroup(
      "Probe", prefix: "probe", routes: [RouteDefinition(.get, "", Self.handlerID)]
    )
    try await TestHTTPServer.run(
      registry: TestHTTPServer.registry(Self.handlerID) { _ in
        .data(.object(["ok": .bool(true)]))
      },
      groups: [group],
      authentication: .password(Self.password, accessControl: accessControl),
      body)
  }

  private static func get(port: Int, query: String = "") async throws -> Int {
    try await TestHTTPServer.send(port: port, path: "/api/v1/probe\(query)").status
  }

  /// The regression, stated as the thing a user would report: "everyone was logged out and
  /// nobody had changed the password".
  @Test("Past the global threshold, a correct password still works")
  func throttlingDoesNotLockOutAGoodClient() async throws {
    let control = unidentifiedTunnel()
    let identity = await control.identity(peerAddress: "127.0.0.1", forwardedFor: nil)
    #expect(identity == .unresolved)

    for _ in 0..<4 {
      _ = await control.recordFailure(identity, path: "/api/v1/probe", reason: "bad")
    }
    #expect(await control.evaluate(identity) == .throttled)

    try await withServer(accessControl: control) { port in
      let accepted = try await Self.get(port: port, query: "?password=\(Self.password)")
      #expect(accepted == 200)
      // And a wrong one is still refused, so the route is not simply unguarded.
      let refused = try await Self.get(port: port, query: "?password=nope")
      #expect(refused == 401)
    }
  }

  /// The other half of the split. Blocking is what actually bounds guessing, and it has to
  /// keep refusing a caller holding the RIGHT password: a lockout a correct guess ends is not
  /// a lockout.
  @Test("A blocked address is still refused with the right password")
  func blockingIsUnchanged() async throws {
    let control = attributable()
    await control.blockPermanently(address: "127.0.0.1", reason: "test")

    try await withServer(accessControl: control) { port in
      let blocked = try await Self.get(port: port, query: "?password=\(Self.password)")
      #expect(blocked == 401)
      await control.unblock(address: "127.0.0.1")
      let unblocked = try await Self.get(port: port, query: "?password=\(Self.password)")
      #expect(unblocked == 200)
    }
  }

  /// The decision is asked once and answered once, so a fourth call site cannot fold a new
  /// case into whichever neighbour it was written beside.
  @Test("Only a block refuses before the credential is read")
  func onlyBlocksRefuseEarly() {
    #expect(AccessDecision.blocked(until: nil).refusesBeforeCredential)
    #expect(AccessDecision.blocked(until: Date()).refusesBeforeCredential)
    #expect(!AccessDecision.throttled.refusesBeforeCredential)
    #expect(!AccessDecision.allow.refusesBeforeCredential)
  }
}

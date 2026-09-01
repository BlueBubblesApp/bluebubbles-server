//  PeerAddressTests
//  The client's address has to reach the auth stage, or access control is inert.
//
//  `APIRequestContext.peerAddress` was hardcoded to nil. Everything downstream then behaved
//  exactly as designed for the "we cannot identify this client" case: `ProxyTrustPolicy`
//  resolved every request to `.unresolved`, `AccessControlService` declined to block anyone,
//  and `X-Forwarded-For` was never consulted because the peer was never a trusted proxy.
//
//  So the block list, the lockout escalation and the whole per-client half of § 17 were
//  present, tested in isolation, and unreachable in the running server. Nothing failed —
//  the throttle simply never fired.
//
//  Like PathParameterTests, these run a real Hummingbird instance: the defect was in what
//  the router handed the context, and a hand-rolled harness would reproduce the fixed
//  version rather than the shipping one.

import BBAuth
import BBSerialization
import Foundation
import Hummingbird
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Peer address plumbing", .serialized)
struct PeerAddressTests {

  /// A route that reports back what reached the handler, so the assertion is about the
  /// value that actually arrived rather than about the code that reads it.
  ///
  /// `requires: .unauthenticated` on the echo route, and `.authenticated` on the second:
  /// the peer address is read by the auth stage, so a test that skipped authentication
  /// entirely would never exercise the path the fix is about.
  private static let echoGroup = RouteGroup(
    "Test", prefix: "test",
    routes: [
      .init(.get, "peer", "test.peer", requires: .unauthenticated),
      .init(.get, "guarded", "test.guarded"),
    ])

  private func withServer(
    accessControl: AccessControlService,
    chain: AuthenticationChain = AuthenticationChain(schemes: []),
    _ body: (Int) async throws -> Void
  ) async throws {
    var registry = HandlerRegistry()
    let echo: RouteHandler = { request in
      .data(
        .object([
          "peer": request.peerAddress.map(JSONValue.string) ?? .null,
          "identity": .string(String(describing: request.identity)),
        ]))
    }
    registry.register("test.peer", echo)
    registry.register("test.guarded", echo)
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    // Port 0 throughout: the kernel picks, and it never picks one it has already given out.
    // See `EphemeralPort` for what this replaced and why guessing was worse than it looked.
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      authentication: AuthenticationStage(chain: chain, accessControl: accessControl),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let router = try builder.buildRouter(
      registry: registry, additionalGroups: [Self.echoGroup]
    )

    let listener = HTTPListener()
    try await listener.start(router: router, host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }

    try await body(try await listener.boundPortOrFail())
  }

  /// Accepts any request, so a test can reach an AUTHENTICATED route and still be about
  /// the address rather than about credentials.
  private struct AlwaysAuthenticates: AuthenticationScheme {
    let id = "test-always"
    func authenticate(
      _ presentation: CredentialPresentation
    ) async throws -> AuthenticatedPrincipal? {
      AuthenticatedPrincipal(deviceID: nil, scopes: Scope.all, schemeID: id)
    }
  }

  private static func get(
    port: Int, path: String, headers: [String: String] = [:]
  ) async throws -> JSONValue {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONValue.parse(data)
  }

  @Test("A request carries the connection's address to the handler")
  func peerAddressIsPopulated() async throws {
    try await withServer(accessControl: AccessControlService()) { port in
      let body = try await Self.get(port: port, path: "/api/v1/test/peer")
      let peer = body["data"]?["peer"]?.stringValue
      #expect(peer == "127.0.0.1", "peerAddress was \(peer ?? "nil")")
    }
  }

  @Test("A loopback peer is trusted, so its forwarded header names the client")
  func forwardedHeaderIsHonouredFromLoopback() async throws {
    // This is the shipped topology: ngrok, cloudflared and zrok all run on this machine.
    // Without the peer address the header was never read, so every tunnelled client was
    // unresolved and none of them could be told apart.
    //
    // Through the GUARDED route, because identity is resolved by the auth stage — an
    // unauthenticated route never asks who the caller is, and correctly so.
    try await withServer(
      accessControl: AccessControlService(),
      chain: AuthenticationChain(schemes: [AlwaysAuthenticates()])
    ) { port in
      let body = try await Self.get(
        port: port, path: "/api/v1/test/guarded",
        headers: ["X-Forwarded-For": "198.51.100.42"]
      )
      #expect(body["data"]?["identity"]?.stringValue?.contains("198.51.100.42") == true)
    }
  }

  @Test("Without a forwarded header a loopback peer stays unresolved")
  func loopbackWithoutHeaderIsUnresolved() async throws {
    // The fail-open half. Attributing this to 127.0.0.1 — which is a trusted proxy and
    // an allowlisted address — must not happen either; it is nobody's failure to own.
    try await withServer(
      accessControl: AccessControlService(),
      chain: AuthenticationChain(schemes: [AlwaysAuthenticates()])
    ) { port in
      let body = try await Self.get(port: port, path: "/api/v1/test/guarded")
      #expect(body["data"]?["identity"]?.stringValue?.contains("unresolved") == true)
    }
  }

  @Test("Rate limiting actually engages against a real client")
  func blockingReachesTheWire() async throws {
    // The end-to-end assertion the module tests could not make: a client that fails
    // enough times stops getting through, at the HTTP layer, over a real socket.
    let control = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 3),
      trust: ProxyTrustPolicy(trustedProxies: ["127.0.0.1"])
    )
    let identity = await control.identity(
      peerAddress: "127.0.0.1", forwardedFor: "198.51.100.99"
    )
    #expect(identity == .address("198.51.100.99"))

    for _ in 0..<3 {
      _ = await control.recordFailure(identity, path: "/api/v1/test/peer", reason: "bad")
    }

    try await withServer(
      accessControl: control,
      chain: AuthenticationChain(schemes: [AlwaysAuthenticates()])
    ) { port in
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/test/guarded")!)
      request.setValue("198.51.100.99", forHTTPHeaderField: "X-Forwarded-For")
      let (_, response) = try await URLSession.shared.data(for: request)
      // 401, not 403 or 429: a blocked caller is told exactly what a wrong password is
      // told, so guessing yields no signal that it is being counted.
      #expect((response as? HTTPURLResponse)?.statusCode == 401)

      // And a different client through the same tunnel is unaffected — the property
      // the whole attribution model exists to preserve.
      var other = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/test/guarded")!)
      other.setValue("198.51.100.100", forHTTPHeaderField: "X-Forwarded-For")
      let (_, otherResponse) = try await URLSession.shared.data(for: other)
      #expect((otherResponse as? HTTPURLResponse)?.statusCode == 200)
    }
  }
}

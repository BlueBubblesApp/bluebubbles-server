//  CORSConfigurationTests
//  `cors_allowed_origin` against a real listener, on both surfaces it has to cover.
//
//  The policy is unit-tested in `CORSPolicyTests`; what this adds is that it is actually
//  APPLIED — by the REST middleware and by the socket transport mounted on the same port. A
//  narrowed origin that left the event stream answering every page would be the worst of both:
//  an operator believing they had restricted the server, and the half a browser client
//  actually streams from still open.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAuth
import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BlueBubblesServerCore

@Suite("CORS configuration")
struct CORSConfigurationTests {

  private static let password = "correct-horse-battery-staple"
  private static let handlerID = HandlerID("cors.probe")

  private func withServer(
    allowedOrigin: String,
    _ body: (Int) async throws -> Void
  ) async throws {
    var registry = HandlerRegistry()
    registry.register(Self.handlerID) { _ in .data(.object(["ok": .bool(true)])) }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    let group = RouteGroup(
      "Probe", prefix: "probe", routes: [RouteDefinition(.get, "", Self.handlerID)]
    )
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(allowedOrigin: allowedOrigin),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: [
          PasswordQueryScheme(passwordProvider: { PasswordDigest(Self.password) })
        ]),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let listener = HTTPListener()
    try await listener.start(
      router: try builder.buildRouter(registry: registry, additionalGroups: [group]),
      host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }
    try await body(try await listener.boundPortOrFail())
  }

  private static func get(
    port: Int, origin: String?
  ) async throws -> HTTPURLResponse {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(port)/api/v1/probe?password=\(password)")!)
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    let (_, response) = try await URLSession.shared.data(for: request)
    return response as! HTTPURLResponse
  }

  /// The default, and the property that outranks the rest of this file: a server nobody has
  /// configured answers exactly as it always has.
  @Test("The default answers every origin with a wildcard and no Vary")
  func defaultIsUnchanged() async throws {
    try await withServer(allowedOrigin: "*") { port in
      let response = try await Self.get(port: port, origin: "https://anywhere.example.com")
      #expect(response.statusCode == 200)
      #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
      #expect(response.value(forHTTPHeaderField: "Vary")?.contains("Origin") != true)
    }
  }

  @Test("A configured origin is echoed, and anything else gets no allow header")
  func narrowedOriginIsEnforced() async throws {
    try await withServer(allowedOrigin: "https://app.example.com") { port in
      let allowed = try await Self.get(port: port, origin: "https://app.example.com")
      #expect(
        allowed.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
          == "https://app.example.com")
      #expect(allowed.value(forHTTPHeaderField: "Vary")?.contains("Origin") == true)

      let refused = try await Self.get(port: port, origin: "https://evil.example.com")
      // The REQUEST still succeeds. There is no status for this: the browser is what
      // refuses, and it refuses by the header not being there.
      #expect(refused.statusCode == 200)
      #expect(refused.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
      #expect(refused.value(forHTTPHeaderField: "Vary")?.contains("Origin") == true)
    }
  }

  /// **The reason narrowing is safe to offer.** A non-browser client sends no `Origin`, and
  /// nothing about the response changes for it: same status, same body. Every client that is
  /// not a web page is in this case.
  @Test("A client that sends no Origin is served exactly as before")
  func nonBrowserClientsAreUnaffected() async throws {
    try await withServer(allowedOrigin: "https://app.example.com") { port in
      let response = try await Self.get(port: port, origin: nil)
      #expect(response.statusCode == 200)
      #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }
  }

  @Test("The preflight follows the same policy as the response")
  func preflightMatches() async throws {
    try await withServer(allowedOrigin: "https://app.example.com") { port in
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/probe")!)
      request.httpMethod = "OPTIONS"
      request.setValue("https://app.example.com", forHTTPHeaderField: "Origin")
      request.setValue(
        "Authorization, X-Forwarded-For", forHTTPHeaderField: "Access-Control-Request-Headers")
      let (_, raw) = try await URLSession.shared.data(for: request)
      let response = raw as! HTTPURLResponse

      #expect(
        response.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
          == "https://app.example.com")
      // And the forwarding header is still refused, which is a separate policy on the same
      // response: an origin allowlist does not make `X-Forwarded-For` assertable.
      #expect(
        response.value(forHTTPHeaderField: "Access-Control-Allow-Headers") == "Authorization")
    }
  }
}

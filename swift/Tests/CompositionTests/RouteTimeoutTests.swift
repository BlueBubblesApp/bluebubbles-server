//  RouteTimeoutTests
//  The per-route timeouts in the table are actually applied.
//
//  They were not. `RouteDefinition.requestTimeout` and `responseTimeout` had been in the
//  table since it was written, `HTTPAPIConfiguration` stored them, and the generated OpenAPI
//  document published both as `x-request-timeout-seconds` and `x-response-timeout-seconds` —
//  and nothing anywhere applied one. A handler that never returned held its connection open
//  forever, and the declared values described behaviour that did not exist.
//
//  A real Hummingbird instance rather than a call into the dispatcher, for the reason
//  `PathParameterTests` gives: the thing being checked is what the server does, and a
//  hand-rolled harness can reproduce the intended version rather than the shipping one.

import BBAuth
import BBSerialization
import Foundation
import Hummingbird
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Route timeouts", .serialized)
struct RouteTimeoutTests {

  private func withServer(
    registry: HandlerRegistry,
    groups: [RouteGroup],
    _ body: (Int) async throws -> Void
  ) async throws {
    // Port 0, not a guess-and-retry. The loop this replaced re-picked a random port up to
    // eight times, which lowered the odds of a collision without removing them — and had a
    // worse failure than the one it was guarding against: when all eight attempts failed it
    // fell out of the loop WITHOUT calling `body`, so the test passed having asserted
    // nothing. See `EphemeralPort`.
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: []),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let router = try builder.buildRouter(registry: registry, additionalGroups: groups)

    let listener = HTTPListener()
    try await listener.start(router: router, host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }

    try await body(try await listener.boundPortOrFail())
  }

  /// A handler that sleeps past whatever limit the route declares.
  private func stalling(_ id: HandlerID, for duration: Duration) -> HandlerRegistry {
    var registry = HandlerRegistry()
    registry.register(id) { _ in
      try await Task.sleep(for: duration)
      return .data(.string("this should never be reached"))
    }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)
    return registry
  }

  private static func get(port: Int, path: String) async throws -> (Int, JSONValue) {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (status, try JSONValue.parse(data))
  }

  @Test("A handler that outruns its route's timeout returns 504")
  func slowHandlerTimesOut() async throws {
    let group = RouteGroup(
      "Test", prefix: "timeout",
      routes: [
        .init(
          .get, "slow", "timeout.slow",
          requires: .unauthenticated,
          // Far below the sleep below, so the race has no chance of going the other way.
          responseTimeout: .milliseconds(200)
        )
      ])

    try await withServer(
      registry: stalling("timeout.slow", for: .seconds(30)), groups: [group]
    ) { port in
      let (status, body) = try await Self.get(port: port, path: "/api/v1/timeout/slow")
      #expect(status == 504)
      // The documented envelope: `message` carries the elapsed time, and the error body
      // is the fixed string clients have always received.
      #expect(body["status"]?.intValue == 504)
      #expect(body["message"]?.stringValue?.contains("timed-out") == true)
      #expect(
        body["error"]?["type"]?.stringValue == ErrorType.gatewayTimeout.rawValue,
        "the 504 must keep its documented error type"
      )
    }
  }

  @Test("A handler inside its timeout is untouched")
  func fastHandlerIsUnaffected() async throws {
    let group = RouteGroup(
      "Test", prefix: "timeout",
      routes: [
        .init(
          .get, "quick", "timeout.quick",
          requires: .unauthenticated,
          responseTimeout: .seconds(30)
        )
      ])

    try await withServer(
      registry: stalling("timeout.quick", for: .milliseconds(1)), groups: [group]
    ) { port in
      let (status, body) = try await Self.get(port: port, path: "/api/v1/timeout/quick")
      #expect(status == 200)
      #expect(body["data"]?.stringValue == "this should never be reached")
    }
  }

  @Test("The enforced precedence is the one the document publishes")
  func precedenceMatchesTheDocument() {
    // route → group → default, and the OpenAPI generator resolves it the same way. Two
    // rules for one value is how a published contract drifts from the behaviour.
    let group = RouteGroup(
      "Test", prefix: "t", responseTimeout: .seconds(30),
      routes: [
        .init(.get, "a", "t.a", requires: .unauthenticated),
        .init(.get, "b", "t.b", requires: .unauthenticated, responseTimeout: .seconds(90)),
      ])

    #expect(HTTPAPIBuilder.responseTimeout(for: group.routes[0], in: group) == .seconds(30))
    #expect(HTTPAPIBuilder.responseTimeout(for: group.routes[1], in: group) == .seconds(90))

    let ungrouped = RouteGroup(
      "U", prefix: "u",
      routes: [.init(.get, "c", "u.c", requires: .unauthenticated)]
    )
    #expect(
      HTTPAPIBuilder.responseTimeout(for: ungrouped.routes[0], in: ungrouped)
        == RouteTable.defaultResponseTimeout
    )
  }
}

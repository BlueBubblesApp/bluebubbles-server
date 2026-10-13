//  RouteTimeoutTests
//  The per-route timeouts in the table are actually applied.
//
//  They were not. `RouteDefinition.requestTimeout` and `responseTimeout` had been in the
//  table since it was written, `HTTPAPIConfiguration` stored them, and the generated OpenAPI
//  document published both as `x-request-timeout-seconds` and `x-response-timeout-seconds`,
//  and nothing anywhere applied one. A handler that never returned held its connection open
//  forever, and the declared values described behaviour that did not exist.
//
//  A real Hummingbird instance rather than a call into the dispatcher, for the reason
//  `PathParameterTests` gives: the thing being checked is what the server does, and a
//  hand-rolled harness can reproduce the intended version rather than the shipping one.

import BBAuth
import BBCore
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
    try await TestHTTPServer.run(registry: registry, groups: groups, body)
  }

  /// A handler that sleeps past whatever limit the route declares.
  private func stalling(_ id: HandlerID, for duration: Duration) -> HandlerRegistry {
    TestHTTPServer.registry(id) { _ in
      try await Task.sleep(for: duration)
      return .data(.string("this should never be reached"))
    }
  }

  private static func get(port: Int, path: String) async throws -> (Int, JSONValue) {
    let reply = try await TestHTTPServer.send(port: port, path: path)
    return (reply.status, try reply.json())
  }

  @Test("A handler that outruns its route's timeout returns 504")
  func slowHandlerTimesOut() async throws {
    let group = RouteGroup(
      "Test", prefix: "timeout",
      routes: [
        .init(
          .get, "slow", HandlerID("timeout.slow"),
          requires: .unauthenticated,
          // Far below the sleep below, so the race has no chance of going the other way.
          responseTimeout: .milliseconds(200)
        )
      ])

    try await withServer(
      registry: stalling(HandlerID("timeout.slow"), for: .seconds(30)), groups: [group]
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
          .get, "quick", HandlerID("timeout.quick"),
          requires: .unauthenticated,
          responseTimeout: .seconds(30)
        )
      ])

    try await withServer(
      registry: stalling(HandlerID("timeout.quick"), for: .milliseconds(1)), groups: [group]
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
        .init(.get, "a", HandlerID("t.a"), requires: .unauthenticated),
        .init(
          .get, "b", HandlerID("t.b"), requires: .unauthenticated, responseTimeout: .seconds(90)),
      ])

    #expect(HTTPAPIBuilder.responseTimeout(for: group.routes[0], in: group) == .seconds(30))
    #expect(HTTPAPIBuilder.responseTimeout(for: group.routes[1], in: group) == .seconds(90))

    let ungrouped = RouteGroup(
      "U", prefix: "u",
      routes: [.init(.get, "c", HandlerID("u.c"), requires: .unauthenticated)]
    )
    #expect(
      HTTPAPIBuilder.responseTimeout(for: ungrouped.routes[0], in: ungrouped)
        == RouteTable.defaultResponseTimeout
    )
  }
}

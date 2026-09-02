//  PathParameterTests
//  Every `:name` segment the route table declares reaches the handler.
//
//  This exists because it did not. `APIRequestContext.pathParameters` was declared, threaded
//  through, and never populated — the router matched the routes correctly and then dropped
//  what it had matched. Every `:guid` and `:id` route answered 400 "missing path parameter"
//  regardless of the request.
//
//  It was invisible from inside: nothing failed to compile, no test touched a parameterised
//  route, and the server started clean reporting all its routes mounted. What found it was
//  curling `DELETE /webhook/1` against a running server.
//
//  These run a real Hummingbird instance rather than calling the dispatcher directly. Calling
//  the dispatcher would test the code that reads the dictionary, and the dictionary was the
//  thing that was empty.

import BBAuth
import BBSerialization
import Foundation
import Hummingbird
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Path parameters", .serialized)
struct PathParameterTests {

  /// Mounts a throwaway route table and reports back whatever parameters arrived.
  ///
  /// Uses the real `HTTPListener`, so this exercises the same path the server does — the
  /// bug was in how the router's match reached the context, and a hand-rolled harness
  /// could easily reproduce the working version rather than the shipping one.
  private func withServer(
    registry: HandlerRegistry,
    groups: [RouteGroup],
    _ body: (Int) async throws -> Void
  ) async throws {
    // Port 0: the kernel picks a free port and never picks one it has already given
    // out. See `EphemeralPort`.
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      // Open. This is testing routing, and an auth failure would mask the result —
      // every route below declares `.unauthenticated` for the same reason.
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
    let port = try await listener.boundPortOrFail()

    try await body(port)
  }

  /// A registry with one real handler and the base table filled in.
  ///
  /// `buildRouter` refuses to mount a table with any unregistered handler, which is the
  /// behaviour we want everywhere else — so the base routes get placeholders and only the
  /// route under test does anything.
  private func echoing(_ handlerID: HandlerID) -> HandlerRegistry {
    var registry = HandlerRegistry()
    registry.register(handlerID) { request in
      // Echoed rather than asserted inside the handler, so the failure message names
      // the actual value.
      .data(.object(request.pathParameters.mapValues(JSONValue.string)))
    }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)
    return registry
  }

  private static func get(port: Int, path: String) async throws -> JSONValue {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONValue.parse(data)
  }

  @Test("a single parameter reaches the handler")
  func single() async throws {
    let group = RouteGroup(
      "Test", prefix: "test",
      routes: [
        .init(.get, ":id", HandlerID("test.one"), requires: .unauthenticated)
      ])
    try await withServer(registry: echoing(HandlerID("test.one")), groups: [group]) { port in
      let body = try await Self.get(port: port, path: "/api/v1/test/42")
      #expect(body["data"]?["id"]?.stringValue == "42")
    }
  }

  @Test("two parameters on one route both arrive")
  func two() async throws {
    let group = RouteGroup(
      "Test", prefix: "test",
      routes: [
        .init(.get, ":guid/:messageGuid", HandlerID("test.two"), requires: .unauthenticated)
      ])
    try await withServer(registry: echoing(HandlerID("test.two")), groups: [group]) { port in
      let body = try await Self.get(port: port, path: "/api/v1/test/CHAT-1/MSG-2")
      #expect(body["data"]?["guid"]?.stringValue == "CHAT-1")
      #expect(body["data"]?["messageGuid"]?.stringValue == "MSG-2")
    }
  }

  /// A chat GUID is `iMessage;-;+15555550101` — semicolons, a plus, often an `@`. Clients
  /// percent-encode it, and a handler that reads the raw value looks up the encoded form
  /// and finds nothing. The decoding happens in `requirePathParameter`, so what arrives
  /// here is still encoded; this pins that the segment survives intact either way.
  @Test("an encoded GUID survives the round trip")
  func encoded() async throws {
    let group = RouteGroup(
      "Test", prefix: "test",
      routes: [
        .init(.get, ":guid", HandlerID("test.guid"), requires: .unauthenticated)
      ])
    try await withServer(registry: echoing(HandlerID("test.guid")), groups: [group]) { port in
      let body = try await Self.get(
        port: port, path: "/api/v1/test/iMessage%3B-%3B%2B15555550101"
      )
      let raw = try #require(body["data"]?["guid"]?.stringValue)
      #expect(raw.removingPercentEncoding == "iMessage;-;+15555550101")
    }
  }

  /// The table's ordering trap, asserted rather than assumed: `count` is declared before
  /// `:guid`, so `/message/count` must reach the count handler and not be swallowed as a
  /// message whose GUID is the word "count".
  @Test("a literal segment wins over a parameter")
  func literalPrecedence() async throws {
    var registry = HandlerRegistry()
    registry.register(HandlerID("test.literal")) { _ in .data(.string("literal")) }
    registry.register(HandlerID("test.parameter")) { request in
      .data(.string("parameter:\(request.pathParameters["guid"] ?? "?")"))
    }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    let group = RouteGroup(
      "Test", prefix: "test",
      routes: [
        .init(.get, "count", HandlerID("test.literal"), requires: .unauthenticated),
        .init(.get, ":guid", HandlerID("test.parameter"), requires: .unauthenticated),
      ])

    try await withServer(registry: registry, groups: [group]) { port in
      let literal = try await Self.get(port: port, path: "/api/v1/test/count")
      #expect(literal["data"]?.stringValue == "literal")

      let parameter = try await Self.get(port: port, path: "/api/v1/test/ABC")
      #expect(parameter["data"]?.stringValue == "parameter:ABC")
    }
  }
}

//  HTTPEdgeTests
//  What the HTTP layer itself puts on the wire, as distinct from what a handler computed.
//
//  Deliberately says NOTHING about entity fields. Whether a message carries `dateEdited`
//  depends on the macOS schema underneath, `SchemaProfile` decides it, and
//  `SerializationTests` pins it per profile — asserting it again here would be a second,
//  version-sensitive copy of that contract which would rot the first time Apple moved a
//  column.
//
//  Everything below is version-INDEPENDENT: the envelope, the pagination metadata, the
//  status codes, the error vocabulary, the CORS headers. It is also the part clients parse
//  before they ever look at a payload, and none of it was asserted anywhere — the handlers
//  and the middleware sat at 0% coverage while 1459 tests passed.

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

@Suite("HTTP edge")
struct HTTPEdgeTests {

  // MARK: - Harness

  /// Stands up the real listener and router, as `PathParameterTests` does — a hand-rolled
  /// harness could reproduce a working version rather than the shipping one.
  ///
  /// The port is retried on collision rather than picked once: a single random pick is what
  /// makes `SignalOwnershipTests` fail intermittently with "Port N is already in use", and
  /// a flaky test in a suite this size gets ignored rather than investigated.
  private func withServer(
    registry: HandlerRegistry,
    groups: [RouteGroup],
    configuration: HTTPAPIConfiguration? = nil,
    _ body: (Int) async throws -> Void
  ) async throws {
    let builder = HTTPAPIBuilder(
      configuration: configuration
        ?? HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      // Open: this is testing the envelope, and an auth failure would mask every result.
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: []),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    // Port 0. This used to retry a random port eight times, which is where the comment
    // about intermittent "Port N is already in use" failures came from — retrying makes a
    // collision rarer and slower, it does not remove it. See `EphemeralPort`.
    let listener = HTTPListener()
    let router = try builder.buildRouter(registry: registry, additionalGroups: groups)
    try await listener.start(router: router, host: "127.0.0.1", port: 0)
    defer { Task { await listener.stop() } }
    try await body(try await listener.boundPortOrFail())
  }

  private func registry(
    _ id: HandlerID, _ handler: @escaping RouteHandler
  ) -> HandlerRegistry {
    var registry = HandlerRegistry()
    registry.register(id, handler)
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)
    return registry
  }

  private struct Reply {
    let status: Int
    let headers: [String: String]
    let body: JSONValue?
  }

  private static func send(
    port: Int, method: String = "GET", path: String, body: Data? = nil
  ) async throws -> Reply {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key).lowercased()] = String(describing: value)
    }
    return Reply(status: http.statusCode, headers: headers, body: try? JSONValue.parse(data))
  }

  private func group(
    _ routes: [RouteDefinition], responseTimeout: Duration? = nil
  ) -> RouteGroup {
    RouteGroup("Edge", prefix: "edge", responseTimeout: responseTimeout, routes: routes)
  }

  // MARK: - The envelope

  @Test("A success carries status, message and data at the top level")
  func successEnvelope() async throws {
    let registry = registry("edge.ok") { _ in .data(.object(["value": .int(1)])) }
    let routes = [RouteDefinition(.get, "ok", "edge.ok", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/ok")
      #expect(reply.status == 200)
      #expect(reply.body?["status"]?.intValue == 200)
      #expect(reply.body?["message"]?.stringValue != nil)
      #expect(reply.body?["data"]?["value"]?.intValue == 1)
      // A success carries no error key at all — not an empty one.
      #expect(reply.body?["error"] == nil)
    }
  }

  @Test("Pagination metadata reaches the envelope under the keys clients page on")
  func paginationMetadata() async throws {
    let registry = registry("edge.page") { _ in
      .data(
        .array([.int(1), .int(2)]),
        metadata: .object([
          "offset": .int(0), "limit": .int(2), "total": .int(9), "count": .int(2),
        ]))
    }
    let routes = [RouteDefinition(.get, "page", "edge.page", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/page")
      #expect(reply.body?["metadata"]?["total"]?.intValue == 9)
      #expect(reply.body?["metadata"]?["count"]?.intValue == 2)
      #expect(reply.body?["metadata"]?["offset"]?.intValue == 0)
      #expect(reply.body?["metadata"]?["limit"]?.intValue == 2)
    }
  }

  // MARK: - The error vocabulary

  /// Each pairing is part of the client contract, including the one that looks wrong:
  /// a 404 reports "Database Error", not "Not Found". Odd, but shipped.
  @Test("Thrown HTTP errors reach the wire with their documented status and type")
  func errorEnvelopes() async throws {
    // Typed as `any Error` rather than `any HTTPError`: Hummingbird vends an `HTTPError`
    // of its own, so the unqualified name is ambiguous wherever both modules are in scope,
    // and the module's own `enum BBHTTPAPI` shadows the qualified spelling. The handler
    // only needs to throw it.
    let cases: [(String, any Error, Int, String)] = [
      ("notfound", NotFound("nope"), 404, ErrorType.databaseError.rawValue),
      ("unauth", Unauthorized("no"), 401, ErrorType.authenticationError.rawValue),
      ("bad", BadRequest("no"), 400, ErrorType.validationError.rawValue),
      ("unavailable", ServiceUnavailable("no chat.db"), 503, ErrorType.serverError.rawValue),
      ("imessage", IMessageError("send failed"), 500, ErrorType.iMessageError.rawValue),
    ]

    for (path, error, status, type) in cases {
      let id = HandlerID("edge.\(path)")
      let registry = registry(id) { _ in throw error }
      let routes = [RouteDefinition(.get, path, id, requires: .unauthenticated)]

      try await withServer(registry: registry, groups: [group(routes)]) { port in
        let reply = try await Self.send(port: port, path: "/api/v1/edge/\(path)")
        #expect(reply.status == status, "\(path) returned \(reply.status)")
        #expect(reply.body?["status"]?.intValue == status)
        #expect(reply.body?["error"]?["type"]?.stringValue == type, "\(path) error type")
        #expect(reply.body?["error"]?["message"]?.stringValue != nil)
      }
    }
  }

  /// A failed send comes back as 500 with the serialized message in `data`. This is the
  /// response clients depend on most, and the shape must not become a 4xx however much
  /// more correct that would be.
  @Test("An iMessage error carries its payload in data alongside the error")
  func iMessageErrorCarriesData() async throws {
    let registry = registry("edge.send") { _ in
      throw IMessageError("send failed", data: .object(["guid": .string("x")]))
    }
    let routes = [RouteDefinition(.get, "send", "edge.send", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/send")
      #expect(reply.status == 500)
      #expect(reply.body?["data"]?["guid"]?.stringValue == "x")
      #expect(reply.body?["error"]?["type"]?.stringValue == ErrorType.iMessageError.rawValue)
    }
  }

  @Test("An unrecognised error becomes a 500 rather than escaping as a crash")
  func unknownErrorBecomesServerError() async throws {
    struct Boom: Error {}
    let registry = registry("edge.boom") { _ in throw Boom() }
    let routes = [RouteDefinition(.get, "boom", "edge.boom", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/boom")
      #expect(reply.status == 500)
      #expect(reply.body?["error"]?["type"]?.stringValue == ErrorType.serverError.rawValue)
    }
  }

  /// An enum case as a `body`, so the two renderings are unmistakably different: the case
  /// name would reach the client as `refused(reason: "Messages said no")`, quotes and all.
  private enum SampleDomainError: BBError {
    case refused(reason: String)
    var code: String { "sample.refused" }
    var domain: String { "Sample" }
    var title: String { "Could not do the thing" }
    var body: String { "Messages refused the request. Try again in a moment." }
    var context: [String: DiagnosticValue] {
      ["chat": .string("any;-;person@example.com"), "password": .secret]
    }
  }

  /// The bridge added for the audit's finding 01.
  ///
  /// Thirty-seven types conform to `BBError` and none of them is an `HTTPError`, so every one
  /// of them used to fall through to `String(describing:)` — the case name, on the wire, to a
  /// client. `MessageSendError` worked around it by adopting `CustomStringConvertible`; the
  /// other thirty-six did not. The renderer reads `body` now, which is the field the protocol
  /// already requires to be a sentence a person can act on.
  @Test("A BBError reaches the client as its body rather than as its enum case")
  func bbErrorRendersItsBody() async throws {
    let registry = registry("edge.domain") { _ in
      throw SampleDomainError.refused(reason: "Messages said no")
    }
    let routes = [RouteDefinition(.get, "domain", "edge.domain", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/domain")
      let message = reply.body?["error"]?["message"]?.stringValue
      #expect(message == "Messages refused the request. Try again in a moment.")
      #expect(message?.contains("refused(reason:") == false)
    }
  }

  /// The half of the bridge that is deliberately NOT clever.
  ///
  /// `BBError` carries a `severity`, and mapping it onto a status would be easy and wrong:
  /// severity says how bad a thing is, not whose fault it is. Clients have read these as
  /// 500s since the Node server, so the status and the error type do not move — a `BBError`
  /// that wants a different status says so by also being an `HTTPError`, which is matched
  /// first.
  @Test("Bridging a BBError does not move its status or error type")
  func bbErrorKeepsItsStatus() async throws {
    let registry = registry("edge.severity") { _ in
      throw SampleDomainError.refused(reason: "warning-level, still a 500")
    }
    let routes = [RouteDefinition(.get, "severity", "edge.severity", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/severity")
      #expect(reply.status == 500)
      #expect(reply.body?["status"]?.intValue == 500)
      #expect(reply.body?["error"]?["type"]?.stringValue == ErrorType.serverError.rawValue)
      // The envelope's error object is `{type, message}` and nothing else. The structured
      // fields go to the log, because adding a key here fails the parity diff.
      #expect(reply.body?["error"]?["code"] == nil)
      #expect(reply.body?["data"] == nil)
    }
  }

  /// `DiagnosticValue.secret` exists so redaction is structural rather than something each
  /// call site remembers, and the renderer is the first place in the request path that
  /// actually spends it.
  @Test("A secret in an error's context renders redacted")
  func secretContextIsRedacted() {
    let error = SampleDomainError.refused(reason: "x")
    #expect(error.context["password"]?.redactedDescription == "••••")
    #expect(error.context["chat"]?.redactedDescription == "any;-;person@example.com")
  }

  // MARK: - Limits

  /// The 100 MB ceiling is what stops an unauthenticated caller making the server buffer
  /// arbitrary memory before it has been asked who it is. Tested at a small limit so the
  /// suite does not move a hundred megabytes to prove it.
  @Test("A body past the ceiling is refused with 413, not buffered")
  func bodyLimitIsEnforced() async throws {
    let registry = registry("edge.upload") { _ in .data(nil) }
    let routes = [RouteDefinition(.post, "upload", "edge.upload", requires: .unauthenticated)]
    let configuration = HTTPAPIConfiguration(
      host: "127.0.0.1", port: 0, maximumBodySize: 1024)

    try await withServer(
      registry: registry, groups: [group(routes)], configuration: configuration
    ) { port in
      let oversized = Data(repeating: 0x41, count: 4096)
      let reply = try await Self.send(
        port: port, method: "POST", path: "/api/v1/edge/upload", body: oversized)
      #expect(reply.status == 413)
      // Paired with validationError, not serverError: the limit is the client's
      // constraint to respect, and a client that retries a 500 forever stops on a 4xx.
      #expect(reply.body?["error"]?["type"]?.stringValue == ErrorType.validationError.rawValue)
    }
  }

  @Test("A handler past its response deadline produces the 504 body, with the elapsed time")
  func responseTimeoutProduces504() async throws {
    let registry = registry("edge.slow") { _ in
      try await Task.sleep(for: .seconds(30))
      return .data(nil)
    }
    let routes = [RouteDefinition(.get, "slow", "edge.slow", requires: .unauthenticated)]

    try await withServer(
      registry: registry, groups: [group(routes, responseTimeout: .milliseconds(250))]
    ) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/slow")
      #expect(reply.status == 504)
      #expect(reply.body?["error"]?["type"]?.stringValue == ErrorType.gatewayTimeout.rawValue)
      // The message embeds the elapsed milliseconds; clients show it.
      #expect(reply.body?["message"]?.stringValue?.contains("ms") == true)
    }
  }

  // MARK: - CORS

  /// Wide open, deliberately, and recorded as residual risk: locking it down would break
  /// browser clients that cannot be enumerated. Pinned so that "fixing" it is a decision
  /// rather than an accident — which is exactly what the comment on `allowedOrigin` warns
  /// about.
  @Test("Every response carries the permissive origin header")
  func corsOnNormalResponses() async throws {
    let registry = registry("edge.cors") { _ in .data(nil) }
    let routes = [RouteDefinition(.get, "cors", "edge.cors", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(port: port, path: "/api/v1/edge/cors")
      #expect(reply.headers["access-control-allow-origin"] == "*")
      #expect(reply.headers["access-control-allow-headers"] == "*")
    }
  }

  @Test("A preflight is answered without reaching the handler")
  func corsPreflight() async throws {
    let registry = registry("edge.pre") { _ in
      Issue.record("a preflight reached the handler")
      return .data(nil)
    }
    let routes = [RouteDefinition(.get, "pre", "edge.pre", requires: .unauthenticated)]

    try await withServer(registry: registry, groups: [group(routes)]) { port in
      let reply = try await Self.send(
        port: port, method: "OPTIONS", path: "/api/v1/edge/pre")
      #expect(reply.status == 204)
      #expect(reply.headers["access-control-allow-origin"] == "*")
      let methods = reply.headers["access-control-allow-methods"] ?? ""
      #expect(methods.contains("POST") && methods.contains("DELETE"))
    }
  }
}

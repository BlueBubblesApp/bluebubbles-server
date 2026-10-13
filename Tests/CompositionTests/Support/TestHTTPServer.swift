//  TestHTTPServer
//  The real listener and router around one test's body, started and stopped one way.
//
//  A suite that asserts what the server puts on the wire runs the shipping `HTTPListener`
//  and `HTTPAPIBuilder`, because a hand-rolled harness reproduces the intended version
//  rather than the shipping one. What varies between suites is configuration: the handlers,
//  the extra route groups, the `HTTPAPIConfiguration`, the authentication chain and access
//  control, the Private API stage, a Socket.IO transport and TLS material. So that is what
//  `run` takes, and the lifecycle is not a parameter.
//
//  **The listener is awaited on stop, on every path.** `defer` cannot await, so the shape
//  `defer { Task { await listener.stop() } }` hands the stop to a detached task: the test
//  can finish, and the next one start, while the previous listener is still up, and a stop
//  that fails or hangs is never seen. `run` stops inside the function instead, after the
//  body returns or throws, and only then returns or rethrows. `ListenerStopPolicyTests`
//  fails the build on the detached shape anywhere under `Tests/`.
//
//  Port 0 throughout; see `EphemeralPort`.

import BBAuth
import BBCore
import BBSocketIO
import BBSystem
import Foundation
import Hummingbird

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BlueBubblesServerCore

enum TestHTTPServer {

  /// Starts a listener on an ephemeral loopback port, runs `body` with the port, and stops
  /// the listener before returning or rethrowing.
  ///
  /// - Parameters:
  ///   - registry: The handlers. Build it with `registry(_:)` so the base table is filled
  ///     with placeholders, which `buildRouter` requires.
  ///   - groups: Route groups mounted beside `RouteTable.groups`.
  ///   - authentication: Open by default, so an auth failure cannot mask what a suite is
  ///     about. A suite about authentication passes its own.
  ///   - gates: Every gate open by default, so a switch cannot mask what a suite is about. A
  ///     suite about a gate passes `RouteGates.stage(context:)`.
  ///   - onClientActivity: The builder's activity hook, for the suite that pins its call site.
  ///   - sockets: A Socket.IO stack to mount on the same router and serve on the same port.
  ///   - tls: Certificate material, to serve HTTPS and wss instead of plaintext.
  static func run<Result>(
    registry: HandlerRegistry,
    groups: [RouteGroup] = [],
    configuration: HTTPAPIConfiguration = HTTPAPIConfiguration(),
    authentication: AuthenticationStage = .open(),
    privateAPI: PrivateAPIStage = PrivateAPIStage(isConnected: { true }),
    gates: RouteGateStage = .allOpen,
    onClientActivity: @escaping @Sendable () async -> Void = {},
    sockets: TestSocketStack? = nil,
    tls: CertificateStore.Material? = nil,
    _ body: (Int) async throws -> Result
  ) async throws -> Result {
    let builder = HTTPAPIBuilder(
      configuration: configuration,
      authentication: authentication,
      privateAPI: privateAPI,
      gates: gates,
      onClientActivity: onClientActivity
    )
    let router = try builder.buildRouter(registry: registry, additionalGroups: groups)
    sockets?.transport.mount(on: router)

    let listener = HTTPListener()
    try await listener.start(
      router: router, host: "127.0.0.1", port: 0, socket: sockets?.transport, tls: tls)

    let result: Result
    do {
      result = try await body(try await listener.boundPortOrFail())
    } catch {
      await listener.stop()
      throw error
    }
    await listener.stop()
    return result
  }

  /// A registry holding `handlers`, with every other route in the base table answered by a
  /// placeholder.
  static func registry(_ handlers: [(HandlerID, RouteHandler)] = []) -> HandlerRegistry {
    var registry = HandlerRegistry()
    for (id, handler) in handlers { registry.register(id, handler) }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)
    return registry
  }

  /// A registry with one handler, the common case, spelled shortly.
  static func registry(
    _ id: HandlerID, _ handler: @escaping RouteHandler
  ) -> HandlerRegistry {
    registry([(id, handler)])
  }

  /// An open router over the placeholder table, for the suites that drive `HTTPListener`
  /// directly because the listener's own start and stop are what they assert. Built fresh
  /// per listener: a router is not sendable across starts.
  static func placeholderRouter() throws -> Router<BBRequestContext> {
    try HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: .open(),
      privateAPI: PrivateAPIStage(isConnected: { true }),
      gates: .allOpen
    ).buildRouter(registry: registry())
  }

  // MARK: - Requests

  /// What a request to the test server came back with.
  struct Reply: Sendable {
    let status: Int
    /// Keyed by the LOWERCASED header name.
    let headers: [String: String]
    let data: Data
    let response: HTTPURLResponse

    /// The body as JSON, or nil when it is not.
    var body: JSONValue? { try? JSONValue.parse(data) }
    /// The body as JSON, throwing when it is not.
    func json() throws -> JSONValue { try JSONValue.parse(data) }
    var text: String { String(decoding: data, as: UTF8.self) }
  }

  /// Sends one request to `127.0.0.1:port`.
  ///
  /// - Parameters:
  ///   - path: The path and any query string, as written: `/api/v1/ping?password=x`.
  ///   - body: Sent with `Content-Type: application/json` unless `contentType` says otherwise
  ///     (nil sends no content type at all).
  static func send(
    port: Int,
    method: String = "GET",
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil,
    contentType: String? = "application/json",
    session: URLSession = .shared
  ) async throws -> Reply {
    let url = try url(port: port, path: path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let body {
      request.httpBody = body
      if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw HarnessError.notHTTP(url.absoluteString)
    }
    var lowercased: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      lowercased[String(describing: key).lowercased()] = String(describing: value)
    }
    return Reply(status: http.statusCode, headers: lowercased, data: data, response: http)
  }

  /// `http://127.0.0.1:<port><path>`, or a failure naming the path that would not parse.
  static func url(port: Int, path: String, scheme: String = "http") throws -> URL {
    guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
      throw HarnessError.badURL(path)
    }
    return url
  }

  enum HarnessError: Error, CustomStringConvertible {
    case badURL(String)
    case notHTTP(String)
    var description: String {
      switch self {
      case .badURL(let path): "could not build a loopback URL from \(path)"
      case .notHTTP(let url): "the response from \(url) was not an HTTP response"
      }
    }
  }
}

/// A Socket.IO server, its Engine.IO layer and the transport that serves it, authenticated by
/// one password.
struct TestSocketStack {
  let server: SocketServer
  let engine: EngineIOServer
  let transport: SocketIOTransport

  init(password: String) {
    let server = SocketServer()
    let engine = EngineIOServer(
      server: server,
      chain: { AuthenticationChain(schemes: [PasswordQueryScheme.fixed(password)]) }
    )
    self.server = server
    self.engine = engine
    self.transport = SocketIOTransport(engine: engine)
  }
}

extension AuthenticationStage {

  /// No credential scheme and the default access control: every route is reachable.
  static func open(
    accessControl: AccessControlService = AccessControlService()
  ) -> AuthenticationStage {
    AuthenticationStage(chain: AuthenticationChain(schemes: []), accessControl: accessControl)
  }

  /// The server password, read from `?password=`.
  static func password(
    _ password: String, accessControl: AccessControlService = AccessControlService()
  ) -> AuthenticationStage {
    AuthenticationStage(
      chain: AuthenticationChain(schemes: [PasswordQueryScheme.fixed(password)]),
      accessControl: accessControl)
  }

  /// Any credential, or none, is accepted as a full-scope principal.
  static func alwaysAuthenticates(
    accessControl: AccessControlService = AccessControlService()
  ) -> AuthenticationStage {
    AuthenticationStage(
      chain: AuthenticationChain(schemes: [AlwaysAuthenticates()]), accessControl: accessControl)
  }
}

extension RouteGateStage {
  /// Every gate open. Test-only on purpose: the builder has no default stage, so production
  /// cannot serve a gated route open by forgetting one.
  static let allOpen = RouteGateStage { _ in }
}

extension PasswordQueryScheme {
  /// A scheme accepting exactly `password`.
  static func fixed(_ password: String) -> PasswordQueryScheme {
    PasswordQueryScheme(passwordProvider: { PasswordDigest(password) })
  }
}

/// Accepts any request, so a test can reach an AUTHENTICATED route and still be about
/// something other than credentials.
struct AlwaysAuthenticates: AuthenticationScheme {
  let id = "test-always"
  func authenticate(
    _ presentation: CredentialPresentation
  ) async throws -> AuthenticatedPrincipal? {
    AuthenticatedPrincipal(deviceID: nil, scopes: Scope.all, schemeID: id)
  }
}

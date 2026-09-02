//  HTTPServer
//  The Hummingbird binding. Deliberately thin.
//
//  Everything that decides behavior — the route table, the middleware stages, the error
//  envelope — lives in files that do not import Hummingbird, so it can all be tested without
//  standing up a server and so swapping the HTTP layer would touch this file and no other.
//
//  The framework-shaped details that DO live here are the ones clients can observe:
//  wide-open CORS, `?pretty`, the 504 timeout body, and Content-Disposition on file streams.
//
//  See `.claude/docs/api.md`.

import BBAuth
import BBCore
import BBSerialization
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore

/// Signature every controller implements. Returning a `JSONValue` rather than a
/// `ResponseEnvelope` keeps controllers from having to know about the envelope at all —
/// wrapping happens once, here, which is how the shape stays consistent across ~90 routes.
public typealias RouteHandler = @Sendable (APIRequestContext) async throws -> RouteResult

public enum RouteResult: Sendable {
  /// Wrapped in the standard envelope with status 200.
  ///
  /// `message` overrides the route's entry in `SuccessMessages`, for the handful of routes
  /// whose string depends on what they found — the reference's theme and settings reads say
  /// "No saved themes!" for an empty list and "Successfully fetched theme(s)!" otherwise,
  /// and only the handler knows which.
  case data(JSONValue?, metadata: JSONValue? = nil, message: String? = nil)
  /// 201 "No Data". POST /facetime/leave/:call_uuid, and nothing else.
  case noData
  /// A pre-built envelope, for the handful of routes that set their own status.
  case envelope(status: Int, ResponseEnvelope)
  /// Streamed from disk. Never buffered — a 500 MB video must not enter the heap.
  case file(path: String, filename: String?, contentType: String?)
  /// Raw bytes with a content type. Used by the avatar and blurhash routes.
  case bytes(Data, contentType: String)
}

public struct HTTPAPIConfiguration: Sendable {
  /// Matches the current server: wide open. Locking it down would break browser-based
  /// clients we cannot enumerate, so it stays as it is and is recorded as residual risk.
  public var allowedOrigin: String
  public var requestTimeout: Duration
  public var responseTimeout: Duration
  /// 100 MB, matching maxHttpBufferSize. An upload past this is rejected rather than
  /// buffered — the current chunked-upload path reassembles whole files in memory.
  public var maximumBodySize: Int

  public init(
    allowedOrigin: String = "*",
    requestTimeout: Duration = RouteTable.defaultRequestTimeout,
    responseTimeout: Duration = RouteTable.defaultResponseTimeout,
    maximumBodySize: Int = 100 * 1024 * 1024
  ) {
    self.allowedOrigin = allowedOrigin
    self.requestTimeout = requestTimeout
    self.responseTimeout = responseTimeout
    self.maximumBodySize = maximumBodySize
  }
}

/// Maps `HandlerID` to an implementation.
///
/// A route with no registered handler is a hard failure at mount time, not a 404 at runtime.
/// That is how the route table stays honest: adding a route to the table without writing its
/// controller refuses to start rather than quietly serving a 404 that looks like a client
/// bug.
public struct HandlerRegistry: Sendable {

  private var handlers: [HandlerID: RouteHandler] = [:]

  public init() {}

  public mutating func register(_ id: HandlerID, _ handler: @escaping RouteHandler) {
    handlers[id] = handler
  }

  public func handler(for id: HandlerID) -> RouteHandler? { handlers[id] }

  /// Handler IDs the table references that nothing has registered.
  public func missing(for groups: [RouteGroup]) -> [HandlerID] {
    var seen = Set<HandlerID>()
    for group in groups {
      for route in group.routes where handlers[route.handlerID] == nil {
        seen.insert(route.handlerID)
      }
    }
    return seen.sorted { $0.rawValue < $1.rawValue }
  }
}

public enum HTTPMountError: BBError, CustomStringConvertible {
  case unregisteredHandlers([HandlerID])
  case unrecognizedMethod(method: String, path: String)

  public var description: String {
    switch self {
    case .unregisteredHandlers(let ids):
      "No handler registered for: \(ids.map(\.rawValue).joined(separator: ", "))"
    case .unrecognizedMethod(let method, let path):
      "Route \(path) declares HTTP method '\(method)', which is not a valid method"
    }
  }
}

// MARK: - Request context

/// The router's context, carrying the connection's peer address.
///
/// `BasicRequestContext` drops it: it is handed the channel at construction and keeps only
/// the logger. Without this type `APIRequestContext.peerAddress` is always nil, every client
/// resolves as `.unresolved`, and the per-client half of `AccessControlService` — the block
/// list, the lockout escalation, the `X-Forwarded-For` trust rules — never engages at all.
/// That is silent: nothing fails, the throttle just never fires.
///
/// `RemoteAddressRequestContext` is Hummingbird's own protocol for this, so conforming to it
/// also gives the framework's tracing middleware the address for free.
public struct BBRequestContext: RequestContext, RemoteAddressRequestContext {
  public var coreContext: CoreRequestContextStorage
  /// nil for a request that did not arrive over a socket with an address — a UNIX-domain
  /// or in-process channel. Treated as unresolved rather than as a client, which is the
  /// safe direction: unresolved never blocks anyone.
  public let remoteAddress: SocketAddress?

  public init(source: ApplicationRequestContextSource) {
    self.coreContext = .init(source: source)
    self.remoteAddress = source.channel.remoteAddress
  }
}

extension SocketAddress {
  /// The address alone, without the port.
  ///
  /// The port must not be part of client identity: every request from one client arrives
  /// on a different ephemeral port, so keying on it would give each request its own
  /// counter and no failure would ever accumulate.
  public var bbClientAddress: String? {
    switch self {
    case .v4, .v6: ipAddress
    case .unixDomainSocket: nil
    }
  }
}

// MARK: - Mounting

public struct HTTPAPIBuilder: Sendable {

  private let configuration: HTTPAPIConfiguration
  private let authentication: AuthenticationStage
  private let privateAPI: PrivateAPIStage
  private let metrics: RequestMetrics
  /// Called when an AUTHENTICATED request arrives, which is the server's only evidence that
  /// a real client is around right now.
  ///
  /// Two things downstream need it and neither can observe it for itself: the proxy, so a
  /// tunnel is not recycled while somebody is using it, and the Firebase restart poll, which
  /// runs every five seconds while a client is active and every minute when none is. Both
  /// read from a timestamp nothing was setting — so the tunnel treated a busy server as idle
  /// and the restart button took up to a minute to do anything.
  ///
  /// Deliberately after authentication: an unauthenticated probe, including a port scanner,
  /// is not a client and must not hold either behaviour open.
  private let onClientActivity: @Sendable () async -> Void
  private let logger: Logger

  public init(
    configuration: HTTPAPIConfiguration,
    authentication: AuthenticationStage,
    privateAPI: PrivateAPIStage,
    metrics: RequestMetrics = RequestMetrics(),
    onClientActivity: @escaping @Sendable () async -> Void = {},
    logger: Logger = Logger(label: "bluebubbles.http")
  ) {
    self.configuration = configuration
    self.authentication = authentication
    self.privateAPI = privateAPI
    self.metrics = metrics
    self.onClientActivity = onClientActivity
    self.logger = logger
  }

  /// Builds the router from the table.
  ///
  /// `additionalGroups` is where AdditiveRoutes enter, and it is a parameter rather than
  /// being folded into RouteTable.groups so that the parity harness can mount ONLY the
  /// table and diff it against the Node server's route list. Anything additive has to be
  /// passed in explicitly by the composition root.
  public func buildRouter(
    registry: HandlerRegistry,
    additionalGroups: [RouteGroup] = []
  ) throws -> Router<BBRequestContext> {
    let groups = RouteTable.alwaysMounted + additionalGroups

    // Strict for the API surface, tolerant for the root.
    //
    // An API route with no controller must refuse to start: it is in the contract, and a
    // 404 there reads to a client as a client bug. The landing page is not in the
    // contract — it is a page for a browser — so a router assembled without it (which is
    // every test that builds its own registry) mounts what it has rather than throwing.
    // In production it is always present: `PlaceholderHandlers` fills anything the
    // composition root did not register, and reports the count at startup.
    let contractGroups = groups.filter { !$0.mountsAtRoot }
    let missing = registry.missing(for: contractGroups)
    guard missing.isEmpty else { throw HTTPMountError.unregisteredHandlers(missing) }

    let router = Router(context: BBRequestContext.self)
    router.add(middleware: CORSMiddleware(allowedOrigin: configuration.allowedOrigin))

    for group in groups {
      for route in group.routes {
        let path = RouteTable.path(of: route, in: group)

        guard let handler = registry.handler(for: route.handlerID) else { continue }

        // Registration order follows declaration order, which is what preserves the
        // literal-before-parameter precedence the table encodes.
        // Failable, and a failure here means the route table names a method that
        // does not exist. Throwing beats dropping the route: a silently unmounted
        // endpoint would show up as a 404 in production and diff against the Node
        // route table only if someone happened to re-run the comparison.
        guard let method = HTTPRequest.Method(rawValue: route.method.rawValue) else {
          throw HTTPMountError.unrecognizedMethod(
            method: route.method.rawValue, path: path
          )
        }

        router.on(RouterPath(path), method: method) { request, requestContext in
          try await self.dispatch(
            request: request, group: group, route: route,
            template: path,
            // Taken from the router's own match rather than re-parsed from the
            // path. Re-deriving them here would be a second, subtly different
            // implementation of the matching the router already did — and the
            // one place they disagreed would be a route that 404s or, worse,
            // reads the wrong segment.
            pathParameters: Self.pathParameters(from: requestContext),
            peerAddress: requestContext.remoteAddress?.bbClientAddress,
            handler: handler
          )
        }
      }
    }

    return router
  }

  /// The `:name` segments the router captured.
  ///
  /// Percent-decoding is left to the caller (`requirePathParameter`), not done here: a
  /// handful of routes want the raw value, and decoding twice would turn a literal `%2F`
  /// in an address into a path separator.
  private static func pathParameters(
    from context: BBRequestContext
  ) -> [String: String] {
    var parameters: [String: String] = [:]
    for (key, value) in context.parameters {
      parameters[String(key)] = String(value)
    }
    return parameters
  }

  private func dispatch(
    request: Request,
    group: RouteGroup,
    route: RouteDefinition,
    template: String,
    pathParameters: [String: String],
    peerAddress: String?,
    handler: @escaping RouteHandler
  ) async throws -> Response {
    let started = ContinuousClock.now
    var failed = true
    defer {
      let elapsed = ContinuousClock.now - started
      // Read `failed` here, not inside the Task. The defer body runs after the last
      // mutation, so this captures the final value; capturing the var itself would
      // hand a mutable reference to a concurrently-running task.
      let didFail = failed
      Task { await metrics.record(routeTemplate: template, duration: elapsed, failed: didFail) }
    }

    // Collected before anything else touches the request, and capped: the limit is what
    // stops an unauthenticated caller from making the server buffer arbitrary memory
    // before it has even been asked who it is.
    //
    // DELETE IS INCLUDED, and excluding it was a real bug rather than an optimisation. Four
    // handlers read a DELETE body — `chat.clearHistory` requires `{"confirm": true}` and
    // could therefore NEVER succeed, `chat.removeParticipant` takes the address, and
    // `contact.delete` and `facetime.invalidateLinks` take the batch to act on. Each of them
    // failed with "the field you sent is required", which reads as a client mistake.
    //
    // It survived because the fixtures for those routes were recorded against the Node
    // server, which collects them — so the corpus says what the contract is, and only a
    // parity run against THIS server would have disagreed.
    //
    // GET stays excluded: a GET body has no defined meaning and no handler reads one.
    var collected: Data?
    var bodyTooLarge = false
    var timedOut = false
    if route.method != .get {
      do {
        let buffer = try await Self.withTimeout(Self.requestTimeout(for: route)) {
          try await request.body.collect(upTo: configuration.maximumBodySize)
        }
        collected = Data(buffer.readableBytesView)
      } catch is TimedOut {
        timedOut = true
      } catch {
        // Reported, not swallowed. Treating an over-limit body as an ABSENT body —
        // which `try?` did — makes a 500 MB upload look to the handler exactly like a
        // request that forgot its payload, so the client gets "missing field" for a
        // request whose only problem is its size, and retries it forever.
        bodyTooLarge = true
      }
    }

    var context = APIRequestContext(
      method: route.method,
      path: request.uri.path,
      queryParameters: Self.queryParameters(from: request.uri),
      pathParameters: pathParameters,
      headers: Self.headers(from: request),
      peerAddress: peerAddress,
      body: collected
    )

    do {
      if bodyTooLarge {
        throw PayloadTooLarge(limit: configuration.maximumBodySize)
      }

      let requirements = group.requirements.union(route.requirements)

      if requirements.contains(.optionalAuthentication) {
        // Best effort. A caller with a valid password gets a principal and the handler can
        // act on it; one enrolling with a one-time code has no password to send and must
        // still reach the handler. Swallowing the failure is the whole point — the handler
        // decides, because only it knows which of the two doors this caller is using.
        try? await authentication.authenticate(&context)
        if context.principal != nil { await onClientActivity() }
      } else if !requirements.contains(.unauthenticated) {
        try await authentication.authenticate(&context)
        try authentication.authorize(context, scope: route.scope)
        await onClientActivity()
      }
      if requirements.contains(.privateAPI) {
        try await privateAPI.check()
      }

      if timedOut { throw TimedOut() }

      // Bound before the closure: `context` is a `var` because the auth stage mutates it
      // in place, and a concurrently-running task may not capture a mutable binding. The
      // value is Sendable and no longer changes past this point.
      let authenticated = context
      let result = try await Self.withTimeout(Self.responseTimeout(for: route, in: group)) {
        try await handler(authenticated)
      }
      failed = false
      return try Self.response(
        for: result, pretty: context.wantsPrettyJSON, handler: route.handlerID
      )

    } catch is TimedOut {
      // The documented 504 body, whose `message` embeds the elapsed milliseconds. Built by
      // hand rather than through `ErrorRenderer` for exactly that reason.
      let elapsed = ContinuousClock.now - started
      let milliseconds = Int(
        elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
      logger.warning(
        "Request timed out",
        metadata: [
          "path": .string(template),
          "ms": .stringConvertible(milliseconds),
        ])
      return try Self.jsonResponse(
        status: 504,
        envelope: GatewayTimeout.envelope(afterMilliseconds: milliseconds),
        pretty: context.wantsPrettyJSON
      )
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: logger)
      return try Self.jsonResponse(
        status: status, envelope: envelope, pretty: context.wantsPrettyJSON
      )
    }
  }

  // MARK: - Timeouts
  //
  // The route table has carried per-route timeouts since it was written, `HTTPAPIConfiguration`
  // stored them, and the OpenAPI document published them as `x-request-timeout-seconds` and
  // `x-response-timeout-seconds` — but nothing applied one, so a handler that hung hung
  // forever and the declared values described behaviour that did not exist.
  //
  // What this covers is producing the RouteResult. It does NOT cover streaming a `.file`
  // response, which happens after `dispatch` returns and is bounded by the client and the
  // connection instead. That is why the thirty-minute attachment values are harmless and the
  // thirty-second macOS group value is the one that bites: the point of the long ones was
  // never to police the transfer, it was to avoid policing it.

  /// Thrown internally when a stage outruns its limit. Not an `HTTPError`: the 504 body is
  /// built by hand because its `message` embeds the elapsed time.
  private struct TimedOut: Error {}

  /// Precedence, matching `OpenAPIDocument` exactly — the published document and the
  /// enforced behaviour have to come from one rule or they will disagree.
  static func requestTimeout(for route: RouteDefinition) -> Duration {
    route.requestTimeout ?? RouteTable.defaultRequestTimeout
  }

  static func responseTimeout(for route: RouteDefinition, in group: RouteGroup) -> Duration {
    route.responseTimeout ?? group.responseTimeout ?? RouteTable.defaultResponseTimeout
  }

  /// Runs `work`, or throws `TimedOut` if it has not finished within `limit`.
  ///
  /// The loser is cancelled, so a handler that honours cancellation stops; one that does not
  /// runs to completion in the background with nobody reading its result. That is the
  /// standard trade and it is strictly better than the previous behaviour, which was to wait
  /// for it indefinitely while holding the connection open.
  private static func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work() }
      group.addTask {
        try await Task.sleep(for: limit)
        throw TimedOut()
      }
      guard let first = try await group.next() else { throw TimedOut() }
      group.cancelAll()
      return first
    }
  }

  static func response(
    for result: RouteResult, pretty: Bool, handler: HandlerID? = nil
  ) throws -> Response {
    switch result {
    case .data(let data, let metadata, let message):
      // The handler's own string wins; otherwise the route's table entry; otherwise
      // "Success". Looked up here rather than passed in by forty call sites, so a new
      // handler cannot forget to.
      let envelopeMessage = message ?? handler.flatMap(SuccessMessages.message(for:))
      return try jsonResponse(
        status: 200,
        envelope: .success(data, metadata: metadata, message: envelopeMessage),
        pretty: pretty
      )
    case .noData:
      return try jsonResponse(status: 201, envelope: .noData(), pretty: pretty)
    case .envelope(let status, let envelope):
      return try jsonResponse(status: status, envelope: envelope, pretty: pretty)

    case .file(let path, let filename, let contentType):
      var headers = HTTPFields()
      headers[.contentType] = contentType ?? "application/octet-stream"
      if let filename {
        // Quoted, matching the current header exactly. Clients parse it for a name.
        headers[.contentDisposition] = "attachment; filename=\"\(filename)\""
      }
      // FileRegion / sendfile: the bytes never pass through the heap. This is what
      // keeps a large attachment download off the memory budget.
      return Response(
        status: .ok, headers: headers,
        body: .init(asyncSequence: FileBodySequence(path: path))
      )

    case .bytes(let data, let contentType):
      var headers = HTTPFields()
      headers[.contentType] = contentType
      return Response(status: .ok, headers: headers, body: .init(byteBuffer: .init(data: data)))
    }
  }

  static func jsonResponse(status: Int, envelope: ResponseEnvelope, pretty: Bool) throws -> Response
  {
    let data = try envelope.encoded(pretty: pretty)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(
      status: .init(code: status),
      headers: headers,
      body: .init(byteBuffer: .init(data: data))
    )
  }

  /// Parses the RAW query rather than using `uri.queryParameters`.
  ///
  /// Hummingbird's own parser percent-decodes but does not turn `+` into a space, which
  /// Koa's does — so a client that encoded a space in its password as `+` authenticated
  /// against the Node server and not against this one. More importantly, going through one
  /// shared decoder is what makes the HTTP and socket surfaces agree by construction: they
  /// had two decoders with two different sets of rules, and a password that worked on one
  /// failed on the other with no way for a user to tell why.
  ///
  /// See `QueryStringDecoder` for the rules and the bugs behind them.
  static func queryParameters(from uri: URI) -> [String: String] {
    // A valueless `?pretty` yields an empty value, which is exactly what
    // `wantsPrettyJSON` checks for — presence, not truthiness.
    QueryStringDecoder.parse(uri.query.map { String($0) } ?? "")
  }

  static func headers(from request: Request) -> [String: String] {
    var result: [String: String] = [:]
    for field in request.headers {
      result[field.name.canonicalName] = field.value
    }
    return result
  }
}

// MARK: - CORS

/// Wide open, matching the current server.
///
/// This is on the deferred list rather than the fixed list: restricting it requires knowing
/// which origins real clients use, and getting that wrong locks people out. Recorded in
/// `.claude/docs/decisions.md` § "2. Security work that shipped, and what it deliberately
/// did not close".
struct CORSMiddleware<Context: RequestContext>: RouterMiddleware {

  let allowedOrigin: String

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    if request.method == .options {
      var headers = HTTPFields()
      headers[.accessControlAllowOrigin] = allowedOrigin
      headers[.accessControlAllowMethods] = "GET, POST, PUT, DELETE, OPTIONS"
      headers[.accessControlAllowHeaders] = "*"
      return Response(status: .noContent, headers: headers)
    }

    var response = try await next(request, context)
    response.headers[.accessControlAllowOrigin] = allowedOrigin
    response.headers[.accessControlAllowHeaders] = "*"
    return response
  }
}

// MARK: - File streaming

/// Streams a file in fixed-size chunks.
///
/// A `FileHandle` read loop rather than NIO's `FileRegion`/`sendfile` path, so these bytes
/// do pass through the heap. The contract it keeps either way is that peak memory is the
/// chunk size and not the file size.
struct FileBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  let path: String
  let chunkSize: Int = 64 * 1024

  struct AsyncIterator: AsyncIteratorProtocol {
    let handle: FileHandle?
    let chunkSize: Int

    mutating func next() async throws -> ByteBuffer? {
      // The route checks existence and returns NotFound before reaching here, so a nil
      // handle means the file vanished between the check and the read — plausible,
      // since attachments get purged to iCloud. It ends the stream rather than
      // trapping: crashing the server over one missing file is never the right call.
      guard let handle else { return nil }
      let data = try handle.read(upToCount: chunkSize)
      guard let data, !data.isEmpty else {
        try handle.close()
        return nil
      }
      return ByteBuffer(data: data)
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(handle: FileHandle(forReadingAtPath: path), chunkSize: chunkSize)
  }
}

extension HTTPMountError {
  public var code: String {
    switch self {
    case .unregisteredHandlers: "http.unregistered_handlers"
    case .unrecognizedMethod: "http.unrecognized_method"
    }
  }

  public var domain: String { "HTTP" }

  /// A programming error caught at mount time. It stops the server starting, which is the
  /// point — a route in the contract with no controller behind it reads to a client as a
  /// client bug.
  public var severity: Severity { .critical }

  public var title: String { "The route table and the controllers disagree" }

  public var body: String { description }
}

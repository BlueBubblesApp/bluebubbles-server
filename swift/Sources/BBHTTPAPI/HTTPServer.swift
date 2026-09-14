//  HTTPServer
//  The Hummingbird binding. Deliberately thin.
//
//  Everything that decides behavior (the route table, the middleware stages, the error
//  envelope) lives in files that do not import Hummingbird, so it can all be tested without
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
import NIOPosix

/// Signature every controller implements. Returning a `JSONValue` rather than a
/// `ResponseEnvelope` keeps controllers from having to know about the envelope at all:
/// wrapping happens once, here, which is how the shape stays consistent across ~90 routes.
public typealias RouteHandler = @Sendable (APIRequestContext) async throws -> RouteResult

public enum RouteResult: Sendable {
  /// Wrapped in the standard envelope with status 200.
  ///
  /// `message` overrides the route's entry in `SuccessMessages`, for the handful of routes
  /// whose string depends on what they found: the reference's theme and settings reads say
  /// "No saved themes!" for an empty list and "Successfully fetched theme(s)!" otherwise,
  /// and only the handler knows which.
  case data(JSONValue?, metadata: JSONValue? = nil, message: String? = nil)
  /// 201 "No Data". POST /facetime/leave/:call_uuid, and nothing else.
  case noData
  /// A pre-built envelope, for the handful of routes that set their own status.
  case envelope(status: Int, ResponseEnvelope)
  /// Streamed from disk. Never buffered: a 500 MB video must not enter the heap.
  case file(path: String, filename: String?, contentType: String?)
  /// Raw bytes with a content type. Used by the avatar and blurhash routes.
  case bytes(Data, contentType: String)
}

public struct HTTPAPIConfiguration: Sendable {
  /// Matches the reference: wide open. Locking it down would break browser-based
  /// clients we cannot enumerate, so it stays as it is and is recorded as residual risk.
  public var allowedOrigin: String
  public var requestTimeout: Duration
  public var responseTimeout: Duration
  /// 100 MB, matching maxHttpBufferSize. An upload past this is rejected rather than
  /// buffered: the reference's chunked-upload path reassembles whole files in memory.
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
/// resolves as `.unresolved`, and the per-client half of `AccessControlService` (the block
/// list, the lockout escalation, the `X-Forwarded-For` trust rules) never engages at all.
/// That is silent: nothing fails, the throttle just never fires.
///
/// `RemoteAddressRequestContext` is Hummingbird's own protocol for this, so conforming to it
/// also gives the framework's tracing middleware the address for free.
public struct BBRequestContext: RequestContext, RemoteAddressRequestContext {
  public var coreContext: CoreRequestContextStorage
  /// nil for a request that did not arrive over a socket with an address: a UNIX-domain
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
  /// read this timestamp; without it the tunnel would treat a busy server as idle and the
  /// restart button would take up to a minute to do anything.
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
    // contract: it is a page for a browser, so a router assembled without it (which is
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
            // implementation of the matching the router already did, and the
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
    var status = 500
    defer {
      let elapsed = ContinuousClock.now - started
      // Read `failed` here, not inside the Task. The defer body runs after the last
      // mutation, so this captures the final value; capturing the var itself would
      // hand a mutable reference to a concurrently-running task.
      let didFail = failed
      Task { await metrics.record(routeTemplate: template, duration: elapsed, failed: didFail) }
      // The access line. The route TEMPLATE, never the resolved path or the query: a
      // handle route's path is a phone number and the query is where `?password=` lives.
      logger.debug(
        "Request",
        metadata: [
          "method": .string(route.method.rawValue),
          "path": .string(template),
          "status": .stringConvertible(status),
          "ms": .stringConvertible(elapsed.milliseconds),
          "client": .string(peerAddress ?? "-"),
        ])
    }

    // The body is collected AFTER authentication, not before it. See the collection step
    // below the auth stages.
    var bodyFailure: (any Error)?
    var timedOut = false

    var context = APIRequestContext(
      method: route.method,
      path: request.uri.path,
      queryParameters: Self.queryParameters(from: request.uri),
      pathParameters: pathParameters,
      headers: Self.headers(from: request),
      peerAddress: peerAddress,
      // Carried so a failure is recorded against the ROUTE rather than against the path the
      // caller sent, which on a chat or handle route is somebody's address. The access line
      // in the `defer` above has always used the template for the same reason; the auth
      // failure record did not. See `APIRequestContext.auditPath`.
      routeTemplate: template,
      body: nil
    )

    do {

      let requirements = group.requirements.union(route.requirements)

      if requirements.contains(.optionalAuthentication) {
        // The blocklist is never optional. A blocked address is refused here, on the same
        // terms as everywhere else, before the credential question is even asked.
        try await authentication.admit(&context)

        // The CREDENTIAL is best effort. A caller with a valid password gets a principal
        // and the handler can act on it; one enrolling with a one-time code has no password
        // to send and must still reach the handler. Swallowing that failure is the whole
        // point: the handler decides, because only it knows which of the two doors this
        // caller is using.
        try? await authentication.verifyCredential(&context)
        if context.principal != nil { await onClientActivity() }
      } else if !requirements.contains(.unauthenticated) {
        try await authentication.authenticate(&context)
        try authentication.authorize(context, scope: route.scope)
        await onClientActivity()
      }
      if requirements.contains(.privateAPI) {
        try await privateAPI.check()
      }

      // THE BODY, now that we know who is asking.
      //
      // This used to run first, under a comment claiming the cap is what "stops an
      // unauthenticated caller from making the server buffer arbitrary memory before it has
      // even been asked who it is". The cap bounds ONE request; nothing bounds how many
      // arrive at once, so N unauthenticated connections cost N times the cap for as long
      // as the request timeout allows. Every stage above reads only the query, the headers
      // and the peer address, so none of them needed the body and the ordering bought
      // nothing.
      //
      // The two `.optionalAuthentication` routes are unaffected: their credential lives in
      // the body as `client_secret`, which the auth chain does not read either way, and the
      // handler still gets the body below.
      //
      // DELETE IS INCLUDED. Four handlers read a DELETE body: `chat.clearHistory` requires
      // `{"confirm": true}`, `chat.removeParticipant` takes the address, and `contact.delete`
      // and `facetime.invalidateLinks` take the batch to act on, and the reference collects
      // it.
      //
      // GET stays excluded: a GET body has no defined meaning and no handler reads one.
      if route.method != .get {
        do {
          let buffer = try await withTimeout(Self.requestTimeout(for: route)) {
            try await request.body.collect(upTo: configuration.maximumBodySize)
          }
          context.body = Data(buffer.readableBytesView)
        } catch is TimedOut {
          timedOut = true
        } catch is NIOTooManyBytesError {
          // Reported, not swallowed. Treating an over-limit body as an ABSENT body, which
          // `try?` did, makes a 500 MB upload look to the handler exactly like a request
          // that forgot its payload, so the client gets "missing field" for a request whose
          // only problem is its size, and retries it forever.
          bodyFailure = PayloadTooLarge(limit: configuration.maximumBodySize)
        } catch {
          // MATCHED ON THE TYPE, because this used to be a bare `catch` that called
          // everything a 413. A client that disconnected mid-body, a malformed chunked
          // encoding, or any transport failure was answered "your payload is too large",
          // which is a diagnosis the client acts on: it shrinks the file and tries again,
          // for a request whose size was never the problem. `NIOTooManyBytesError` is the
          // one `collect(upTo:)` raises for the limit; everything else goes to the renderer
          // to be reported as what it is.
          bodyFailure = error
        }
      }
      if let bodyFailure { throw bodyFailure }

      if timedOut { throw TimedOut() }

      // VALIDATION, after the body and before the handler, which is where the reference runs
      // it: its validators are middleware sitting between the router and the controller, so a
      // refusal here never reaches a handler and never touches Messages.
      //
      // It runs for every route the reference validates and is a no-op for the rest. A
      // refusal is the reference's 400, and `RequestValues`' leniency downstream is
      // deliberately untouched: everything that passes this gate reads exactly as it did
      // before, which is what keeps `{"limit": "100"}` (a number as a string, which real
      // clients send) working.
      try Self.validate(context, for: route, logger: logger)

      // Bound before the closure: `context` is a `var` because the auth stage mutates it
      // in place, and a concurrently-running task may not capture a mutable binding. The
      // value is Sendable and no longer changes past this point.
      let authenticated = context
      let result = try await withTimeout(Self.responseTimeout(for: route, in: group)) {
        try await handler(authenticated)
      }
      failed = false
      let response = try Self.response(
        for: result,
        pretty: context.wantsPrettyJSON,
        handler: route.handlerID,
        acceptsGzip: context.acceptsGzipEncoding
      )
      status = Int(response.status.code)
      return response

    } catch is TimedOut {
      // The documented 504 body, whose `message` embeds the elapsed milliseconds. Built by
      // hand rather than through `ErrorRenderer` for exactly that reason.
      let milliseconds = (ContinuousClock.now - started).milliseconds
      status = 504
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
      let (rendered, envelope) = ErrorRenderer.render(error, logger: logger)
      status = rendered
      return try Self.jsonResponse(
        status: rendered, envelope: envelope, pretty: context.wantsPrettyJSON
      )
    }
  }

  // MARK: - Validation

  /// Runs the route's rule set, if the reference has one for it.
  ///
  /// Three sources, because the reference's validators read three different things and the
  /// shapes differ in a way the rules can see: a JSON body has real types, while query and
  /// path values are always strings (`after=5` is `"5"`, which passes `numeric` by coercion).
  ///
  /// A multipart body is read as its FORM FIELDS rather than as JSON. `POST /message/attachment`
  /// and `POST /message/attachment/chunk` are both `multipart/form-data`, and the reference
  /// validates `ctx.request.body`, which formidable has already populated with the text fields.
  /// Parsing one as JSON would fail, leave every field absent, and 400 every attachment send on
  /// its `required` chatGuid: the exact client break this layer exists to avoid causing.
  private static func validate(
    _ context: APIRequestContext, for route: RouteDefinition, logger: Logger
  ) throws {
    guard let ruleSet = ValidationRules.ruleSet(for: route.handlerID) else { return }

    let input: JSONValue
    switch ruleSet.source {
    case .query:
      input = .object(context.queryParameters.mapValues { .string($0) })
    case .path:
      input = .object(context.pathParameters.mapValues { .string($0) })
    case .body:
      if let contentType = context.header("Content-Type"),
        contentType.lowercased().contains("multipart/form-data")
      {
        // A body that will not parse is left empty rather than refused here: the handler
        // reports a malformed upload with its own message, and pre-empting it would change
        // which error a client sees for a broken multipart.
        let form = context.body.flatMap {
          try? MultipartForm.parse(body: $0, contentType: contentType)
        }
        let fields = form?.parts.reduce(into: [String: JSONValue]()) { fields, part in
          // File parts are not form values. The reference sees them on `ctx.request.files`,
          // which its rule sets never name.
          guard part.filename == nil, let text = part.text else { return }
          fields[part.name] = .string(text)
        }
        input = .object(fields ?? [:])
      } else {
        // Same rule as `RequestValues`: an absent or unparsable body is an empty object, so
        // the rule set decides whether that is acceptable rather than the parser.
        input = (try? context.jsonBody()) ?? .object([:])
      }
    }

    do {
      try RequestValidator.validate(input, against: ruleSet)
    } catch let refusal as BadRequest {
      // `info`, not `debug`: this is a request that used to be answered and now is not, so a
      // support log wants it by default. The FIELD and the rule are in the sentence; the
      // value is not logged, because it is client content.
      logger.info(
        "Refused a request that failed validation",
        metadata: [
          "handler": .string(route.handlerID.rawValue),
          "reason": .string(refusal.errorMessage),
        ])
      throw refusal
    }
  }

  // MARK: - Timeouts
  //
  // The route table declares per-route timeouts and the OpenAPI document publishes them as
  // `x-request-timeout-seconds` and `x-response-timeout-seconds`. This is where they are
  // applied.
  //
  // What this covers is producing the RouteResult. It does NOT cover streaming a `.file`
  // response, which happens after `dispatch` returns and is bounded by the client and the
  // connection instead. That is why the thirty-minute attachment values are harmless and the
  // thirty-second macOS group value is the one that bites: the point of the long ones was
  // never to police the transfer, it was to avoid policing it.

  /// Thrown internally when a stage outruns its limit. Not an `HTTPError`: the 504 body is
  /// built by hand because its `message` embeds the elapsed time.

  /// Precedence, matching `OpenAPIDocument` exactly: the published document and the
  /// enforced behaviour have to come from one rule or they will disagree.
  static func requestTimeout(for route: RouteDefinition) -> Duration {
    route.requestTimeout ?? RouteTable.defaultRequestTimeout
  }

  static func responseTimeout(for route: RouteDefinition, in group: RouteGroup) -> Duration {
    route.responseTimeout ?? group.responseTimeout ?? RouteTable.defaultResponseTimeout
  }

  /// - Parameter acceptsGzip: threaded from the request. Only the JSON cases honour it; a
  ///   file or byte stream is served as-is, because those bodies are already-compressed media
  ///   and gzipping one would cost CPU, grow it slightly, and force the whole file into the
  ///   heap that `FileBodySequence` exists to keep it out of.
  static func response(
    for result: RouteResult, pretty: Bool, handler: HandlerID? = nil, acceptsGzip: Bool = false
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
        pretty: pretty,
        acceptsGzip: acceptsGzip
      )
    case .noData:
      return try jsonResponse(status: 201, envelope: .noData(), pretty: pretty)
    case .envelope(let status, let envelope):
      return try jsonResponse(
        status: status, envelope: envelope, pretty: pretty, acceptsGzip: acceptsGzip)

    case .file(let path, let filename, let contentType):
      var headers = HTTPFields()
      headers[.contentType] = contentType ?? "application/octet-stream"
      if let filename {
        // Quoted, matching the reference's header exactly. Clients parse it for a name.
        headers[.contentDisposition] = "attachment; filename=\"\(filename)\""
      }
      // Content-Length, which the reference sets and this did not. Its own comment says why:
      // "so that clients can show download progress". Without it the response is chunked,
      // the client has no total, and the progress bar on a 500MB video sits at zero until it
      // finishes. One `stat`, not `attributesOfItem`, which builds a whole dictionary to
      // answer one question.
      //
      // Absent rather than wrong when the file cannot be stat'd: the stream below ends
      // cleanly on a file that has vanished, and claiming a length we then fail to send
      // would be worse than claiming none.
      if let size = FileBodySequence.size(ofFileAt: path) {
        headers[.contentLength] = String(size)
      }
      // Streamed in chunks, so peak memory is the chunk size rather than the file size. NOT
      // sendfile: a comment here used to claim `FileRegion`, and another comment 120 lines
      // below it said the opposite. The bytes do pass through the heap; what holds is the
      // bound, not the mechanism.
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

  /// - Parameter acceptsGzip: whether the REQUEST asked for it. Never inferred here: a
  ///   response is compressed only because a client said it could read one.
  static func jsonResponse(
    status: Int, envelope: ResponseEnvelope, pretty: Bool, acceptsGzip: Bool = false
  ) throws -> Response {
    let data = try envelope.encoded(pretty: pretty)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    // On every JSON response, compressed or not: without it a cache in front of this server
    // can hand a compressed body to a client that never asked for one.
    headers[.vary] = "Accept-Encoding"

    if acceptsGzip, let compressed = ResponseCompression.gzip(data) {
      headers[.contentEncoding] = "gzip"
      return Response(
        status: .init(code: status), headers: headers, body: .init(byteBuffer: compressed))
    }

    return Response(
      status: .init(code: status),
      headers: headers,
      body: .init(byteBuffer: .init(data: data))
    )
  }

  /// Parses the RAW query rather than using `uri.queryParameters`.
  ///
  /// Hummingbird's own parser percent-decodes but does not turn `+` into a space, which
  /// Koa's does, so a client that encoded a space in its password as `+` authenticated
  /// against the Node server and not against this one. More importantly, going through one
  /// shared decoder is what makes the HTTP and socket surfaces agree by construction: they
  /// had two decoders with two different sets of rules, and a password that worked on one
  /// failed on the other with no way for a user to tell why.
  ///
  /// See `QueryStringDecoder` for the rules and the bugs behind them.
  static func queryParameters(from uri: URI) -> [String: String] {
    // A valueless `?pretty` yields an empty value, which is exactly what
    // `wantsPrettyJSON` checks for: presence, not truthiness.
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

/// Wide open on ORIGIN, matching the reference. Not wide open on headers.
///
/// The origin stays `*`: restricting it requires knowing which origins real clients use, and
/// getting that wrong locks people out. That is on the deferred list rather than the fixed
/// list, and is recorded in `.claude/docs/decisions.md` § "2. Security work that shipped,
/// and what it deliberately did not close".
///
/// **`Access-Control-Allow-Headers: *` was a different decision wearing the same clothes,
/// and it made the origin policy matter more than it should.** A wildcard there tells a
/// browser that a cross-origin request may carry ANY header, which includes
/// `X-Forwarded-For`. Loopback is a trusted proxy by default (the bundled tunnels all run
/// here), so a page in the operator's browser could send a failed login with a forwarding
/// header of its choosing and have the failure attributed to an address it picked: blocking
/// third parties, and growing a map an attacker then supplies the keys for.
///
/// So the reflected set is what the request actually asked for, minus the headers that must
/// never be browser-settable. A client sending `Authorization` or `Content-Type` is
/// unaffected, which is every real client; the forwarding headers are the ones this refuses,
/// and no legitimate browser client sets those.
/// The header policy, outside the generic middleware so it can be tested without standing
/// one up over a request context.
public enum CORSHeaderPolicy {

  /// Headers a browser may never assert on this server, because something here believes
  /// them. They are set by a reverse proxy, not by a caller.
  public static let forbidden: Set<String> = [
    "x-forwarded-for", "x-real-ip", "forwarded", "x-forwarded-host", "x-forwarded-proto",
  ]

  /// What was asked for, minus what may not be asserted.
  ///
  /// Absent or empty means the preflight named nothing, and the answer is nothing rather
  /// than everything.
  public static func allowedHeaders(requested: String?) -> String {
    guard let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
      return ""
    }
    return
      requested
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !forbidden.contains($0.lowercased()) }
      .joined(separator: ", ")
  }
}

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
      let allowed = CORSHeaderPolicy.allowedHeaders(
        requested: request.headers[.accessControlRequestHeaders])
      if !allowed.isEmpty { headers[.accessControlAllowHeaders] = allowed }
      return Response(status: .noContent, headers: headers)
    }

    var response = try await next(request, context)
    response.headers[.accessControlAllowOrigin] = allowedOrigin
    return response
  }
}

// MARK: - File streaming

/// Streams a file in fixed-size chunks, off the request executor.
///
/// NOT NIO's `FileRegion`/`sendfile` path: these bytes pass through the heap. The contract
/// this keeps is that peak memory is the CHUNK size and not the file size, which is true of
/// both mechanisms and is the thing that matters; the file's own comment used to claim
/// sendfile in one place and deny it in another.
///
/// Reads run on the NIO thread pool rather than inline. `read(2)` is a blocking syscall, and
/// a 500MB download issues about eight thousand of them: inline, each one parks a cooperative
/// thread until the disk answers, and the runtime's answer to that is to make more threads.
/// Measured elsewhere in this audit: 64 concurrent blocking tasks grew the pool to 58 threads,
/// about 30MB of stacks on a machine that may have 4GB. A spinning disk makes each of those
/// waits far longer.
///
/// `pread` rather than a `FileHandle`: it takes the offset as an argument instead of keeping
/// one on a shared object, so the iterator carries nothing across threads but an integer, and
/// `FileHandle` is not `Sendable`.
struct FileBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  let path: String
  let chunkSize: Int = 64 * 1024

  /// A file's size, without building an attribute dictionary to find it.
  static func size(ofFileAt path: String) -> Int64? {
    var status = stat()
    guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
    return Int64(status.st_size)
  }

  /// What a read failed with, as distinct from reaching the end.
  struct ReadFailure: Error {
    let errorNumber: CInt
    var localizedDescription: String { String(cString: strerror(errorNumber)) }
  }

  /// Owns the descriptor, so abandoning the stream closes it.
  ///
  /// A class, and this is the whole reason for one: the iterator is a struct, and a struct
  /// holding a raw descriptor has nowhere to put a `deinit`. A client that disconnects
  /// mid-download abandons the sequence without reaching the end, and every one of those
  /// leaked a descriptor -- measured at exactly one per abandoned download, until the
  /// process runs out and can no longer open a socket or the database. `FileHandle`, which
  /// this replaced, closed on dealloc and did not have the problem.
  final class OpenFile {
    let descriptor: CInt

    init(path: String) { descriptor = open(path, O_RDONLY) }

    deinit { if descriptor >= 0 { close(descriptor) } }
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let file: OpenFile
    let chunkSize: Int
    var offset: off_t = 0
    var isFinished = false

    mutating func next() async throws -> ByteBuffer? {
      // The route checks existence and returns NotFound before reaching here, so a failed
      // open means the file vanished between the check and the read: plausible, since
      // attachments get purged to iCloud. It ends the stream rather than trapping:
      // crashing the server over one missing file is never the right call.
      guard file.descriptor >= 0, !isFinished else { return nil }
      let start = offset
      let size = chunkSize
      let descriptor = file.descriptor
      let bytes = try await NIOThreadPool.singleton.runIfActive { () -> [UInt8] in
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
          let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return pread(descriptor, base, size, start)
          }
          // A FAILURE is not the end of the file, and conflating them is how a download
          // silently truncates. `read < 0` means errno: `EINTR` is a signal arriving
          // mid-read and is simply retried, anything else is real and is thrown, so the
          // response fails visibly rather than ending short of the Content-Length it
          // already promised.
          if read < 0 {
            if errno == EINTR { continue }
            throw ReadFailure(errorNumber: errno)
          }
          if read == 0 { return [] }
          buffer.removeLast(size - read)
          return buffer
        }
      }
      guard !bytes.isEmpty else {
        isFinished = true
        return nil
      }
      offset += off_t(bytes.count)
      return ByteBuffer(bytes: bytes)
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(file: OpenFile(path: path), chunkSize: chunkSize)
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
  /// point: a route in the contract with no controller behind it reads to a client as a
  /// client bug.
  public var severity: Severity { .critical }

  public var title: String { "The route table and the controllers disagree" }

  public var body: String { description }
}

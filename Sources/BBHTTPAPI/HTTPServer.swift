//  HTTPServer
//  The Hummingbird binding. Deliberately thin.
//
//  Everything that decides behavior (the route table, the middleware stages, the error
//  envelope) lives in files that do not import Hummingbird, so it can all be tested without
//  standing up a server and so swapping the HTTP layer would touch these files and no others.
//
//  This file mounts the table and runs a request through its stages, in order (`dispatch`).
//  The framework-shaped details clients can observe sit beside it: `?pretty`, gzip and the
//  envelope in `HTTPAPIBuilder+Response`, Content-Disposition and file streaming in
//  `FileResponse`, wide-open CORS in `CORS`. The 504 body is built here.
//
//  See `.claude/docs/api.md`.

import BBAuth
import BBCore
import BBLicense
import BBSerialization
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import NIOPosix

/// What the listener is configured with beyond the route table.
///
/// No timeouts: those are per route, declared in `RouteTable` and applied by
/// `HTTPAPIBuilder.requestTimeout(for:)` and `responseTimeout(for:in:)`. A server-wide value
/// here would be a second source nothing reads.
public struct HTTPAPIConfiguration: Sendable {
  /// Which browser origins may read a response. `*` by default, which is what the reference
  /// sends; `cors_allowed_origin` is the setting behind it. See `CORSPolicy`, including why
  /// narrowing this cannot refuse a non-browser client.
  public var allowedOrigin: String

  /// The parsed form of `allowedOrigin`. A computed property rather than a stored one so the
  /// two cannot be set independently and disagree.
  public var corsPolicy: CORSPolicy { CORSPolicy(configured: allowedOrigin) }
  /// 100 MB, matching maxHttpBufferSize. An upload past this is rejected rather than
  /// buffered: the reference's chunked-upload path reassembles whole files in memory.
  public var maximumBodySize: Int

  public init(
    allowedOrigin: String = "*",
    maximumBodySize: Int = 100 * 1024 * 1024
  ) {
    self.allowedOrigin = allowedOrigin
    self.maximumBodySize = maximumBodySize
  }
}

// MARK: - Mounting

public struct HTTPAPIBuilder: Sendable {

  private let configuration: HTTPAPIConfiguration
  private let authentication: AuthenticationStage
  private let privateAPI: PrivateAPIStage
  /// The switches a route declares with `requiring:`. See `RouteGateStage`.
  private let gates: RouteGateStage
  private let license: LicenseStage
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
  /// Called once per request, on the way out, with what the audit log needs to know: the
  /// route, the method, the status and who asked. Synchronous and never awaited: it runs in
  /// the request's `defer`, and the audit recorder hands the record on without waiting.
  private let onRequestCompleted: @Sendable (RequestAuditRecord) -> Void
  private let logger: Logger

  public init(
    configuration: HTTPAPIConfiguration,
    authentication: AuthenticationStage,
    privateAPI: PrivateAPIStage,
    gates: RouteGateStage,
    license: LicenseStage = .unenforced,
    metrics: RequestMetrics = RequestMetrics(),
    onClientActivity: @escaping @Sendable () async -> Void = {},
    onRequestCompleted: @escaping @Sendable (RequestAuditRecord) -> Void = { _ in },
    logger: Logger = Logger(label: "bluebubbles.http")
  ) {
    self.configuration = configuration
    self.authentication = authentication
    self.privateAPI = privateAPI
    self.gates = gates
    self.license = license
    self.metrics = metrics
    self.onClientActivity = onClientActivity
    self.onRequestCompleted = onRequestCompleted
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
    router.add(middleware: CORSMiddleware(policy: configuration.corsPolicy))

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

  // MARK: - Dispatch

  /// One request, through every stage in order: admission and the credential, the licence,
  /// the helper and the route's gates, the body, validation, the handler, and the response. Each stage is its own
  /// function below; this one owns the order and the two things every outcome shares, the 504
  /// and the record written on the way out.
  private func dispatch(
    request: Request,
    group: RouteGroup,
    route: RouteDefinition,
    template: String,
    pathParameters: [String: String],
    peerAddress: String?,
    handler: @escaping RouteHandler
  ) async throws -> Response {
    var trace = RequestTrace(peerAddress: peerAddress)
    defer { finish(trace, route: route, template: template) }

    var context = APIRequestContext(
      method: route.method,
      path: request.uri.path,
      queryParameters: Self.queryParameters(from: request.uri),
      pathParameters: pathParameters,
      headers: Self.headers(from: request),
      peerAddress: peerAddress,
      // Carried so a failure is recorded against the ROUTE rather than against the path the
      // caller sent, which on a chat or handle route is somebody's address. The access line
      // uses the template for the same reason. See `APIRequestContext.auditPath`.
      routeTemplate: template,
      body: nil
    )

    do {
      try await authenticate(&context, route: route, in: group, trace: &trace, template: template)
      try await checkEntitlements(context, route: route, in: group)
      context.body = try await collectBody(of: request, for: route)
      // VALIDATION, after the body and before the handler, which is where the reference runs
      // it: its validators are middleware between the router and the controller, so a
      // refusal here never reaches a handler and never touches Messages. A no-op for a route
      // the reference does not validate.
      try Self.validate(context, for: route, logger: logger)

      let result = try await run(
        handler, for: context, route: route, in: group, trace: trace, template: template)
      // Building the response can still fail (a file that can no longer be opened), so the
      // request has not succeeded until it is built.
      let response = try Self.response(
        for: result,
        pretty: context.wantsPrettyJSON,
        handler: route.handlerID,
        acceptsGzip: context.acceptsGzipEncoding
      )
      trace.failed = false
      trace.status = Int(response.status.code)
      return response

    } catch is TimedOut {
      // The documented 504 body, whose `message` embeds the elapsed milliseconds. Built by
      // hand rather than through `ErrorRenderer` for exactly that reason.
      let milliseconds = (ContinuousClock.now - trace.started).milliseconds
      trace.status = 504
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
      trace.status = rendered
      return try Self.jsonResponse(
        status: rendered, envelope: envelope, pretty: context.wantsPrettyJSON
      )
    }
  }

  /// What `dispatch` learns about a request as its stages run, read once on the way out.
  ///
  /// One value the stages update in place, because the record has to be built from whatever
  /// was known when the request ended, success or failure: a refused request is recorded with
  /// its 401 beside the ones that succeeded.
  struct RequestTrace {
    let started = ContinuousClock.now
    /// One identifier per request, so the audit log can join this request's transport record
    /// to the domain records written while it was handled. Minted before anything can throw,
    /// so a refused request has one too.
    let requestID = UUID().uuidString.lowercased()
    /// The connection's peer, as it arrived. The access line names this.
    let peerAddress: String?
    /// The peer until access control resolves an identity, which honours a trusted proxy's
    /// forwarding header and so names the client rather than the tunnel in front of it. The
    /// audit record names this.
    var resolvedClient: String?
    /// Whether the credential stages completed with a principal. A scope refusal leaves it
    /// false although a credential was accepted: the request was not admitted.
    var isAuthenticated = false
    var failed = true
    var status = 500

    init(peerAddress: String?) {
      self.peerAddress = peerAddress
      self.resolvedClient = peerAddress
    }
  }

  /// The metrics sample, the audit record and the access line, once per request.
  ///
  /// Synchronous: it runs in `dispatch`'s `defer`. The audit recorder hands the record on
  /// without waiting, and the metrics sample is a fire-and-forget hop to its actor.
  private func finish(_ trace: RequestTrace, route: RouteDefinition, template: String) {
    let elapsed = ContinuousClock.now - trace.started
    let failed = trace.failed
    Task { await metrics.record(routeTemplate: template, duration: elapsed, failed: failed) }
    onRequestCompleted(
      RequestAuditRecord(
        requestID: trace.requestID, method: route.method, routeTemplate: template,
        handlerID: route.handlerID, status: trace.status, duration: elapsed,
        clientAddress: trace.resolvedClient, isAuthenticated: trace.isAuthenticated
      ))
    // The route TEMPLATE, never the resolved path or the query: a handle route's path is a
    // phone number and the query is where `?password=` lives.
    logger.debug(
      "Request",
      metadata: [
        "method": .string(route.method.rawValue),
        "path": .string(template),
        "status": .stringConvertible(trace.status),
        "ms": .stringConvertible(elapsed.milliseconds),
        "client": .string(trace.peerAddress ?? "-"),
      ])
  }

  /// Admission, then the credential and its scope.
  ///
  /// ADMIT RUNS FOR EVERY ROUTE, including `.unauthenticated` ones. The blocklist is a
  /// property of the CALLER, not of the credential, and a route that asks for no credential
  /// is not a route that wants to serve someone who has been blocked: `GET /` reads a file
  /// off disk and returns it. It also resolves `context.identity`, which every route wants.
  /// Cheap: an address lookup and a map read, no credential work.
  ///
  /// The stages run under this request's audit context, so a refusal they record joins the
  /// transport record by request id. The actor is the PEER here; the resolved identity is not
  /// known until `admit` has run.
  private func authenticate(
    _ context: inout APIRequestContext,
    route: RouteDefinition,
    in group: RouteGroup,
    trace: inout RequestTrace,
    template: String
  ) async throws {
    let requirements = group.requirements.union(route.requirements)
    let preliminary = AuditContext(
      actor: .client(address: trace.peerAddress), source: .http,
      requestID: trace.requestID, route: template)
    try await AuditContext.with(preliminary) {
      try await authentication.admit(&context)
      if case .address(let resolved) = context.identity { trace.resolvedClient = resolved }

      if requirements.contains(.optionalAuthentication) {
        // The CREDENTIAL is best effort. A caller with a valid password gets a principal and
        // the handler can act on it; one enrolling with a one-time code has no password to
        // send and must still reach the handler. Swallowing that failure is the whole point:
        // the handler decides, because only it knows which of the two doors this caller is
        // using.
        try? await authentication.verifyCredential(&context)
        if context.principal != nil { await onClientActivity() }
      } else if !requirements.contains(.unauthenticated) {
        try await authentication.verifyCredential(&context)
        try authentication.authorize(context, scope: route.scope)
        await onClientActivity()
      }
    }
    trace.isAuthenticated = context.principal != nil
  }

  /// The licence, then the Private API, then the route's gates.
  ///
  /// AFTER authentication and scope, so an unauthenticated prober learns nothing about what
  /// this server pays for. The licence BEFORE the helper, because a licence problem is the
  /// more actionable of the two: it is true whether or not a helper happens to be connected,
  /// and it is the one the user can fix by deciding something.
  ///
  /// The gates AFTER the helper, the order a check at the top of the handler would have: a
  /// FaceTime route with the helper down and the switch off answers the helper's 500.
  /// BEFORE the body, so a refusal costs no upload.
  private func checkEntitlements(
    _ context: APIRequestContext, route: RouteDefinition, in group: RouteGroup
  ) async throws {
    try await license.check(group.tierFloor(for: route), context: context)
    if group.requirements.union(route.requirements).contains(.privateAPI) {
      try await privateAPI.check()
    }
    try await gates.check(group.gates(for: route))
  }

  /// The body, read only once the caller has been admitted.
  ///
  /// The cap bounds ONE request and nothing bounds how many arrive at once, so reading bodies
  /// before admission would let N unauthenticated connections cost N times the cap for as
  /// long as the request timeout allows. No earlier stage reads the body: the auth chain
  /// reads the query, the headers and the peer, and the two `.optionalAuthentication` routes
  /// carry their `client_secret` in the body for the handler to check.
  ///
  /// DELETE IS INCLUDED: `chat.clearHistory` requires `{"confirm": true}`,
  /// `chat.removeParticipant` takes the address, and `contact.delete` and
  /// `facetime.invalidateLinks` take the batch to act on. GET is not: a GET body has no
  /// defined meaning and no handler reads one.
  ///
  /// A body slower than the route's request timeout throws `TimedOut`, which `dispatch`
  /// answers with its 504.
  private func collectBody(
    of request: Request, for route: RouteDefinition
  ) async throws -> Data? {
    guard route.method != .get else { return nil }
    do {
      var buffer = try await withTimeout(Self.requestTimeout(for: route)) {
        try await request.body.collect(upTo: configuration.maximumBodySize)
      }
      // `.noCopy` hands back a `Data` that REFERENCES the buffer's storage rather than a
      // second copy of it, which halves what a large upload costs: copying while the buffer
      // is still live peaks a 100 MB video at 200 MB. Safe because nothing writes to the
      // buffer afterwards: the handler reads it once and it is released with the request.
      return buffer.readData(length: buffer.readableBytes, byteTransferStrategy: .noCopy)
    } catch is NIOTooManyBytesError {
      // MATCHED ON THE TYPE. `NIOTooManyBytesError` is the one `collect(upTo:)` raises for
      // the limit; anything else (a client that disconnected mid-body, a malformed chunked
      // encoding) propagates to the renderer as what it is. A 413 is a diagnosis the client
      // acts on, shrinking the file and retrying a request whose size was never the problem.
      throw PayloadTooLarge(limit: configuration.maximumBodySize)
    }
  }

  /// The handler, AS THIS CLIENT, under the route's response timeout.
  ///
  /// Anything it writes (a setting, a webhook, a scheduled message) is recorded against the
  /// caller and joined to this request. See `AuditContext`.
  private func run(
    _ handler: @escaping RouteHandler,
    for context: APIRequestContext,
    route: RouteDefinition,
    in group: RouteGroup,
    trace: RequestTrace,
    template: String
  ) async throws -> RouteResult {
    let auditContext = AuditContext(
      actor: .client(address: trace.resolvedClient), source: .http,
      requestID: trace.requestID, route: template)
    return try await withTimeout(Self.responseTimeout(for: route, in: group)) {
      try await AuditContext.with(auditContext) { try await handler(context) }
    }
  }
}

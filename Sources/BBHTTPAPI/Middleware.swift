//  Middleware
//  The request pipeline, in the order the reference runs it.
//
//  Order is: Metrics -> Error -> Auth -> [License] -> [PrivateAPI] -> [Gates] -> validator ->
//  controller. The gates (`RouteGateStage`) are this server's; the reference has no stage for
//  them.
//  It matters that Error sits OUTSIDE Auth: an auth rejection has to come back as the JSON
//  envelope, not as a framework-generated 401 body, because clients parse the envelope.
//  The reference's Log stage is not a stage here: the access line is written by
//  `HTTPServer.dispatch` on the way out, once the status is known.
//
//  Access control wraps auth rather than replacing it. The ordering is deliberate: a
//  blocked client is rejected before the password comparison runs, so a brute-force attempt
//  costs nothing after the block lands.
//
//  See `.claude/docs/api.md` and `docs/AUTH.md`.

import BBAuth
import BBCore
import BBDiagnostics
import BBLicense
import BBSerialization
import Foundation
import Logging

// MARK: - Request context

/// What the middleware chain carries. Transport-agnostic so the socket handshake can reuse
/// the auth and access-control stages without pulling in Hummingbird types.
public struct APIRequestContext: Sendable {
  public let method: HTTPMethod
  public let path: String
  public let queryParameters: [String: String]
  public let pathParameters: [String: String]
  public let headers: [String: String]
  public let peerAddress: String?
  /// The route this request matched, as the table declares it (`/api/v1/chat/:guid/read`).
  ///
  /// Distinct from `path`, which is what the caller sent. Nil only for a context built
  /// outside the router, which today means a test.
  public let routeTemplate: String?
  /// The request body, already collected.
  ///
  /// Collected rather than streamed, and the size ceiling is enforced as it is collected.
  ///
  /// This used to say the two routes that move real volume — attachment upload and download —
  /// both stream and neither goes through here. **Download does; upload does not.**
  /// `UploadHandlers` reads exactly this property, so the upload path was the one carrying a
  /// whole file through the field documented as never seeing one, which is how a 100 MB body
  /// came to be buffered and then COPIED into a second allocation.
  ///
  /// It is a `.noCopy` `Data` referencing the collected `ByteBuffer` now, so a body costs one
  /// allocation rather than two, and the listener caps concurrent connections so the per-request
  /// ceiling bounds a total. Streaming multipart to disk is still the better answer for upload
  /// and is not done: see `.claude/docs/performance.md`.
  /// `var` so the body can be attached AFTER authentication rather than before it. See
  /// the collection step in `HTTPServer.dispatch`: nothing in the auth chain reads a body,
  /// and collecting one first meant an unauthenticated caller could make the server buffer
  /// up to the cap before being asked who it was.
  public var body: Data?
  public var principal: AuthenticatedPrincipal?
  public var identity: ClientIdentity

  public init(
    method: HTTPMethod,
    path: String,
    queryParameters: [String: String] = [:],
    pathParameters: [String: String] = [:],
    headers: [String: String] = [:],
    peerAddress: String? = nil,
    routeTemplate: String? = nil,
    body: Data? = nil
  ) {
    self.method = method
    self.path = path
    self.queryParameters = queryParameters
    self.pathParameters = pathParameters
    self.headers = headers
    self.peerAddress = peerAddress
    self.routeTemplate = routeTemplate
    self.body = body
    self.principal = nil
    self.identity = .unresolved
  }

  /// What an authentication failure is recorded against: the route TEMPLATE, never the
  /// resolved path.
  ///
  /// A resolved path is `/api/v1/chat/iMessage;-;+12025550143/read` — a phone number, and one
  /// an UNAUTHENTICATED caller chooses. It was going straight into `AuthFailureRecord.path`,
  /// which `GET /api/v1/server/security/failures` serialises verbatim and the Security page
  /// renders verbatim, so anyone who can reach the port could write an address into the
  /// operator's screen and into the server's own API.
  ///
  /// `AuthenticationStage.admit` already refuses to put this value in a LOG, and says why in
  /// place. The failure record is the same value on a longer journey, and no scanner covers
  /// it: `LogRedactionPolicyTests` reads `logger.<level>` calls, and this is not one.
  ///
  /// The template is also the more useful answer. "Which route is being guessed at" is the
  /// question that list exists to answer, and every caller of one route shares an entry
  /// instead of producing a distinct-looking row per GUID.
  public var auditPath: String {
    // Never `path` as the fallback: that is the leak. A context with no template did not
    // come from the router, so there is no route to name.
    routeTemplate ?? "(unmatched)"
  }

  /// The address a refusal is recorded against: the identity access control RESOLVED, which
  /// honours a trusted proxy's forwarding header and so names the client rather than the
  /// tunnel in front of it; the peer when `admit` has not run yet. Nil when nothing identified
  /// the caller. The rule is `AuthenticationGate.Caller.auditAddress`, so a license refusal
  /// names the same client an authentication refusal does.
  public var auditClientAddress: String? {
    AuthenticationGate.Caller(identity: identity, peerAddress: peerAddress, route: auditPath)
      .auditAddress
  }

  /// Decodes the body as JSON.
  ///
  /// Returns nil rather than throwing for an absent body, so a handler can tell "no body"
  /// from "malformed body": the first is a client that forgot a field, the second is a
  /// client sending something else entirely, and they deserve different messages.
  public func jsonBody() throws -> JSONValue? {
    guard let body, !body.isEmpty else { return nil }
    return try JSONValue.parse(body)
  }

  /// Case-insensitive, because header casing is not guaranteed across HTTP versions.
  public func header(_ name: String) -> String? {
    let lowered = name.lowercased()
    for (key, value) in headers where key.lowercased() == lowered {
      return value
    }
    return nil
  }

  /// `?pretty` with any value (including empty) turns on pretty-printed JSON. Presence,
  /// not truthiness, which is what the reference does.
  public var wantsPrettyJSON: Bool { queryParameters.keys.contains("pretty") }

  /// Whether this client said it can read a gzip-encoded response.
  ///
  /// The only thing that turns compression on. A response is never compressed because it is
  /// large, or because a route looks expensive: it is compressed because the caller sent
  /// `Accept-Encoding` naming gzip, which is what makes the change unobservable to a client
  /// that did not. See `ResponseCompression`.
  public var acceptsGzipEncoding: Bool {
    ResponseCompression.accepts(header("Accept-Encoding"))
  }
}

// MARK: - Authentication stage

public struct AuthenticationStage: Sendable {

  private let chain: AuthenticationChain
  /// The sequence both transports share: identify, admit, settle. This stage is the HTTP
  /// caller of it, and says only what HTTP answers.
  private let gate: AuthenticationGate
  private let logger: Logger

  /// - Parameter auditor: Told about every refusal. Optional because the stage is built in
  ///   tests with nothing behind it; production wires the audit log.
  public init(
    chain: AuthenticationChain,
    accessControl: AccessControlService,
    auditor: (any AuthenticationAuditing)? = nil,
    logger: Logger = Logger(label: "bluebubbles.http.auth")
  ) {
    self.chain = chain
    self.gate = AuthenticationGate(accessControl: accessControl, auditor: auditor, transport: .http)
    self.logger = logger
  }

  /// The caller as the gate sees it. The route is the template, for the reason `auditPath`
  /// gives, and the identity is whatever `admit` resolved.
  private func caller(_ context: APIRequestContext) -> AuthenticationGate.Caller {
    AuthenticationGate.Caller(
      identity: context.identity, peerAddress: context.peerAddress, route: context.auditPath)
  }

  // There is deliberately no `authenticate(_:)` convenience combining the two calls below.
  //
  // `HTTPServer.dispatch` runs `admit` for EVERY route and `verifyCredential` only for the
  // ones that take a credential, which is the ordering that puts `.unauthenticated` routes
  // behind the blocklist. A wrapper that did both is a wrapper someone reaches for on the next
  // route, and reaching for it is how `GET /` came to serve a blocked address.

  /// Resolves who is calling and applies the blocklist and rate limiter.
  ///
  /// Split out from the credential check because the two halves are optional in different
  /// ways. A route marked `.optionalAuthentication` deliberately tolerates a caller with no
  /// credential (that is what enrolment means) but it must NOT tolerate a caller the
  /// access controller has blocked. Running both halves under one `try?` let a blocked
  /// address keep guessing the server password against `auth/register` for as long as it
  /// liked, with every guess counted and none of them enforced.
  ///
  /// What it refuses is `.blocked` and only `.blocked`. Global throttling is advisory; see
  /// `AccessDecision.refusesBeforeCredential`.
  public func admit(_ context: inout APIRequestContext) async throws {
    let caller = await gate.identify(
      peerAddress: context.peerAddress,
      forwardedFor: context.header("X-Forwarded-For"),
      route: context.auditPath
    )
    context.identity = caller.identity

    guard await gate.admit(caller) else {
      // 401, not 403 or 429. A blocked caller gets the same response as a wrong
      // password: telling an attacker their guessing is being counted is free
      // information, and clients do not expect a 429 from the auth path.
      // No path here or below: `context.path` is the resolved path, which on a handle
      // route is a phone number. The access line carries the route template.
      logger.debug(
        "Rejected a request from a blocked client",
        metadata: ["client": .string(context.peerAddress ?? "-")])
      throw Unauthorized()
    }
  }

  /// Checks the presented credential and records the attempt.
  ///
  /// Reads `context.identity`, so `admit` runs first: it is what resolves the identity a
  /// failure is counted against.
  public func verifyCredential(_ context: inout APIRequestContext) async throws {
    let presentation = CredentialPresentation(
      queryParameters: context.queryParameters,
      authorizationHeader: context.header("Authorization"),
      clientAddress: context.peerAddress,
      path: context.path
    )

    let outcome = await chain.authenticate(presentation)
    // Counted and audited by the HTTP rules: a missing credential is a probe and is not
    // counted, and a server fault is neither counted nor audited. See `AttemptRules`.
    await gate.settle(outcome, for: caller(context), under: .http)

    switch outcome {
    case .authenticated(let principal):
      context.principal = principal

    case .noCredential:
      logger.debug(
        "Request without a credential",
        metadata: ["client": .string(context.peerAddress ?? "-")])
      throw Unauthorized("Missing server password!")

    case .failed(let failure):
      // The one line a wrong password writes. Whether it also counts toward a block is
      // the access controller's decision, and that is logged when the block lands.
      logger.debug(
        "Rejected a credential",
        metadata: [
          "reason": .string(failure.code),
          "client": .string(context.peerAddress ?? "-"),
        ])
      if let reason = failure.serverFault {
        // The server's fault, so it reports as one, and does not count against the
        // client, who did nothing wrong.
        throw ServerError(reason)
      }
      throw Unauthorized()
    }
  }

  /// Scope enforcement, run from the route's metadata rather than as its own middleware.
  ///
  /// A no-op under the default `auth_mode = password`: that principal holds every scope.
  public func authorize(_ context: APIRequestContext, scope: Scope) throws {
    guard let principal = context.principal else { throw Unauthorized() }
    guard principal.hasScope(scope) else {
      gate.record(.scopeRefused(scope: scope.rawValue), for: caller(context))
      throw Forbidden("This credential is not permitted to \(scope.rawValue)")
    }
  }
}

// MARK: - Private API stage

/// Gate for routes that cannot work without the helper.
///
/// Note the response: HTTP 500 with `iMessage Error` and the exact message the current
/// middleware emits. A 503 would be more correct and would break clients that branch on the
/// message text, so it stays a 500.
public struct PrivateAPIStage: Sendable {

  private let isConnected: @Sendable () async -> Bool

  public init(isConnected: @escaping @Sendable () async -> Bool) {
    self.isConnected = isConnected
  }

  public func check() async throws {
    guard await isConnected() else {
      throw IMessageError.helperUnavailable()
    }
  }
}

/// Refuses a route whose declared `RouteGate` is closed.
///
/// Shaped like `PrivateAPIStage`: a switch can be flipped while the server runs, so each gate
/// is evaluated per request rather than captured when the router is built. What a gate means
/// is the composer's (`RouteGates` in `BBHandlers`), and so is the refusal: it throws
/// whatever the gate's own error is, and the renderer answers it as it would the same throw
/// from a handler.
///
/// **No default.** The builder takes one explicitly, so a composition that forgot it fails
/// to compile rather than serving every gated route open.
public struct RouteGateStage: Sendable {

  private let evaluate: @Sendable (RouteGate) async throws -> Void

  /// - Parameter evaluate: Returns when `gate` is open; throws the refusal when it is not.
  public init(evaluate: @escaping @Sendable (RouteGate) async throws -> Void) {
    self.evaluate = evaluate
  }

  /// Each gate in order, stopping at the first that is closed: a route behind two switches
  /// names the outer one when both are off.
  public func check(_ gates: [RouteGate]) async throws {
    for gate in gates {
      try await evaluate(gate)
    }
  }
}

/// Refuses a route whose declared tier this server's license does not satisfy.
///
/// Shaped like `PrivateAPIStage` above and for the same reason: the answer changes while the
/// server runs — a key is entered, a subscription lapses, a refresh succeeds — so the status is
/// resolved at call time rather than captured once at construction.
///
/// **No I/O.** The closure reads an already-verified in-memory value. A license check that
/// could block or fail on the request path would put every gated request behind the network,
/// which is exactly what the token design exists to avoid.
///
/// **Absent, not disabled.** A composition with no licensing subsystem passes `.unenforced`,
/// and then nothing is gated at all — rather than a stand-in status that claims to be a
/// license and is not.
///
/// **A refusal is reported before it is thrown.** The 402 tells the client; the auditor is
/// the second reader of the same fact and the one whose record leaves the machine, so it
/// gets the route TEMPLATE and the resolved client address, the way `AuthenticationStage`
/// reports a refused credential, and never the resolved path.
public struct LicenseStage: Sendable {

  private let status: (@Sendable () async -> LicenseStatus)?
  private let auditor: (any LicenseRefusalAuditing)?

  public init(
    status: (@Sendable () async -> LicenseStatus)?,
    auditor: (any LicenseRefusalAuditing)? = nil
  ) {
    self.status = status
    self.auditor = auditor
  }

  /// No licensing subsystem composed. Every route is free surface.
  public static let unenforced = LicenseStage(status: nil)

  /// Returns immediately when the route declares no tier, which is the overwhelming majority
  /// of the table and the entire v1 surface.
  public func check(_ floor: SubscriptionTier?, context: APIRequestContext) async throws {
    guard let floor, let status else { return }
    let current = await status()
    guard let refusal = current.refusal(forRequired: floor) else { return }
    auditor?.record(
      LicenseRefusalRecord(
        refusal: refusal, required: floor, held: current.tier,
        clientAddress: context.auditClientAddress, route: context.auditPath))
    throw PaymentRequired(refusal: refusal, required: floor, held: current.tier)
  }
}

/// A gated route refused for want of a subscription, as the stage reports it.
///
/// Declared here rather than in the audit module for the reason `RequestAuditRecord` is: this
/// module may not import `BBAudit`, so it describes the fact in its own vocabulary and the
/// composition root translates.
public struct LicenseRefusalRecord: Sendable, Equatable {
  public let refusal: LicenseRefusal
  public let required: SubscriptionTier
  /// The tier this server holds, or nil when it holds no entitlement at all.
  public let held: SubscriptionTier?
  /// The resolved client address, or nil when nothing identified the caller.
  public let clientAddress: String?
  /// The route template. Never the resolved path; see `APIRequestContext.auditPath`.
  public let route: String

  public init(
    refusal: LicenseRefusal, required: SubscriptionTier, held: SubscriptionTier?,
    clientAddress: String?, route: String
  ) {
    self.refusal = refusal
    self.required = required
    self.held = held
    self.clientAddress = clientAddress
    self.route = route
  }
}

public protocol LicenseRefusalAuditing: Sendable {
  /// Returns at once; the implementation decides what, if anything, to keep.
  func record(_ record: LicenseRefusalRecord)
}

// MARK: - Error rendering

public enum ErrorRenderer {

  /// The most human-readable sentence an arbitrary error can offer.
  ///
  /// One line, and deliberately: the rule lives in `DiagnosticText.sentence(for:)` and this
  /// is the transport layer's name for it. The steps are documented there and are NOT
  /// restated here, so they cannot fall out of date.
  ///
  /// Public because the interfaces layer needs the same sentence when it translates a
  /// backend failure into an `IMessageError`. Two rules for one question would drift, and
  /// the drift would only ever show up in somebody's error report.
  public static func message(for error: any Error) -> String {
    DiagnosticText.sentence(for: error)
  }

  /// Turns anything thrown into the envelope clients expect.
  ///
  /// An unrecognised error becomes a 500 whose `error.message` is the best sentence
  /// `message(for:)` can find. Anything that must not leak has to be a typed HTTPError with
  /// a deliberate message; there is no automatic redaction of the MESSAGE here, because a
  /// truncated or scrubbed one would make real failures undiagnosable from a client log.
  ///
  /// **A `BBError` is not mapped onto a status.** It is tempting: the protocol carries a
  /// `severity`, but severity answers "how bad is this", not "whose fault is it", and those
  /// are different questions: a `.warning` is not a 400, and guessing would silently move
  /// responses that clients have been reading as 500s since the Node server. So the status
  /// and the error type stay exactly where they were, and what the bridge recovers is the
  /// part that was being thrown away outright: the readable `body` on the wire, and `code`,
  /// `domain`, `severity` and the REDACTED `context` in the log. A `BBError` that wants a
  /// different status says so by being an `HTTPError` too, which is checked first.
  public static func render(_ error: any Error, logger: Logger) -> (
    status: Int, envelope: ResponseEnvelope
  ) {
    if let httpError = error as? any HTTPError {
      if httpError.status >= 500 {
        logger.error(
          "Request failed",
          metadata: [
            "status": .stringConvertible(httpError.status),
            "error": .string(httpError.errorMessage),
          ])
      }
      return (httpError.status, httpError.envelope())
    }

    logger.error("Unhandled error", metadata: diagnostics(for: error))
    // NOT `ServerError`'s own sentence. An exception that reaches here was never given a
    // status by anybody, and the reference says so in the envelope: its error middleware
    // answers "An unhandled error has occurred!" while a deliberately thrown `ServerError`
    // says "The server has encountered an error". A client can tell "this route decided to
    // fail" from "this server fell over" only because those two differ.
    let fallback = ServerError.unhandled(message(for: error))
    return (fallback.status, fallback.envelope())
  }

  /// What the log gets, which is strictly more than the client does.
  ///
  /// The full `String(describing:)` is always present: the client-facing message may be the
  /// friendly one, and a diagnosis needs the type. A `BBError` adds its structured fields,
  /// which is the whole reason the protocol carries them and the reason `DiagnosticValue`
  /// exists: `redactedDescription` renders a `.secret` as `••••`, so context can be logged
  /// without each call site having to remember what is sensitive.
  private static func diagnostics(for error: any Error) -> Logger.Metadata {
    var metadata: Logger.Metadata = ["error": .string(String(describing: error))]
    guard let bbError = error as? any BBError else { return metadata }
    metadata["code"] = .string(bbError.code)
    metadata["domain"] = .string(bbError.domain)
    metadata["severity"] = .string(bbError.severity.rawValue)
    for (key, value) in bbError.context {
      metadata["context.\(key)"] = .string(value.redactedDescription)
    }
    return metadata
  }
}

// MARK: - Metrics

/// Per-route counters, kept in memory for the life of the process and read by the
/// composition's `ServerMetrics` for the app's dashboard. Not on the wire.
///
/// Bounded by the route table, which is a fixed size: deliberately keyed by the route
/// TEMPLATE rather than the resolved path, so `/message/abc` and `/message/def` are one
/// counter and an attacker cannot grow this by varying a path parameter.
public actor RequestMetrics {

  public struct Snapshot: Sendable {
    public let requests: Int
    public let errors: Int
    public let totalDuration: Duration
  }

  private var counters: [String: (requests: Int, errors: Int, duration: Duration)] = [:]

  public init() {}

  public func record(routeTemplate: String, duration: Duration, failed: Bool) {
    var entry = counters[routeTemplate] ?? (0, 0, .zero)
    entry.requests += 1
    if failed { entry.errors += 1 }
    entry.duration += duration
    counters[routeTemplate] = entry
  }

  public func snapshot() -> [String: Snapshot] {
    counters.mapValues {
      Snapshot(requests: $0.requests, errors: $0.errors, totalDuration: $0.duration)
    }
  }
}

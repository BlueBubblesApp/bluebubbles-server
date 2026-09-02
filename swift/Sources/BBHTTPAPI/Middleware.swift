//  Middleware
//  The request pipeline, in the order the current server runs it.
//
//  Order is: Metrics -> Error -> Log -> Auth -> [PrivateAPI] -> validator -> controller.
//  It matters that Error sits OUTSIDE Auth: an auth rejection has to come back as the JSON
//  envelope, not as a framework-generated 401 body, because clients parse the envelope.
//
//  Access control wraps auth rather than replacing it. The ordering is deliberate — a
//  blocked client is rejected before the password comparison runs, so a brute-force attempt
//  costs nothing after the block lands.
//
//  See `.claude/docs/api.md` and `docs/AUTH.md`.

import BBAuth
import BBCore
import BBDiagnostics
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
  /// The request body, already collected.
  ///
  /// Collected rather than streamed because every route that takes a body takes a small
  /// JSON one, and the size ceiling is enforced before this is populated. The two routes
  /// that move real volume — attachment upload and download — stream, and neither goes
  /// through here.
  public let body: Data?
  public var principal: AuthenticatedPrincipal?
  public var identity: ClientIdentity

  public init(
    method: HTTPMethod,
    path: String,
    queryParameters: [String: String] = [:],
    pathParameters: [String: String] = [:],
    headers: [String: String] = [:],
    peerAddress: String? = nil,
    body: Data? = nil
  ) {
    self.method = method
    self.path = path
    self.queryParameters = queryParameters
    self.pathParameters = pathParameters
    self.headers = headers
    self.peerAddress = peerAddress
    self.body = body
    self.principal = nil
    self.identity = .unresolved
  }

  /// Decodes the body as JSON.
  ///
  /// Returns nil rather than throwing for an absent body, so a handler can tell "no body"
  /// from "malformed body" — the first is a client that forgot a field, the second is a
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

  /// `?pretty` with any value — including empty — turns on pretty-printed JSON. Presence,
  /// not truthiness, which is what the current implementation does.
  public var wantsPrettyJSON: Bool { queryParameters.keys.contains("pretty") }
}

// MARK: - Authentication stage

public struct AuthenticationStage: Sendable {

  private let chain: AuthenticationChain
  private let accessControl: AccessControlService
  private let logger: Logger

  public init(
    chain: AuthenticationChain,
    accessControl: AccessControlService,
    logger: Logger = Logger(label: "bluebubbles.http.auth")
  ) {
    self.chain = chain
    self.accessControl = accessControl
    self.logger = logger
  }

  public func authenticate(_ context: inout APIRequestContext) async throws {
    try await admit(&context)
    try await verifyCredential(&context)
  }

  /// Resolves who is calling and applies the blocklist and rate limiter.
  ///
  /// Split out from the credential check because the two halves are optional in different
  /// ways. A route marked `.optionalAuthentication` deliberately tolerates a caller with no
  /// credential — that is what enrolment means — but it must NOT tolerate a caller the
  /// access controller has blocked. Running both halves under one `try?` let a blocked
  /// address keep guessing the server password against `auth/register` for as long as it
  /// liked, with every guess counted and none of them enforced.
  public func admit(_ context: inout APIRequestContext) async throws {
    let identity = await accessControl.identity(
      peerAddress: context.peerAddress,
      forwardedFor: context.header("X-Forwarded-For")
    )
    context.identity = identity

    switch await accessControl.evaluate(identity) {
    case .allow:
      break
    case .blocked, .throttled:
      // 401, not 403 or 429. A blocked caller gets the same response as a wrong
      // password — telling an attacker their guessing is being counted is free
      // information, and clients do not expect a 429 from the auth path.
      logger.debug(
        "Rejected a request from a rate-limited client",
        metadata: [
          "path": .string(context.path)
        ])
      throw Unauthorized()
    }
  }

  /// Checks the presented credential and records the attempt.
  ///
  /// Reads `context.identity`, so `admit` runs first — it is what resolves the identity a
  /// failure is counted against.
  public func verifyCredential(_ context: inout APIRequestContext) async throws {
    let identity = context.identity

    let presentation = CredentialPresentation(
      queryParameters: context.queryParameters,
      authorizationHeader: context.header("Authorization"),
      clientAddress: context.peerAddress,
      path: context.path
    )

    switch await chain.authenticate(presentation) {
    case .authenticated(let principal):
      await accessControl.recordSuccess(identity)
      context.principal = principal

    case .noCredential:
      // No credential at all. Not counted — an unauthenticated probe is not a guess,
      // and counting it lets someone lock out a whole tunnel with empty requests.
      logger.debug("Request without a token", metadata: ["path": .string(context.path)])
      throw Unauthorized("Missing server password!")

    case .failed(let failure):
      if failure.countsAsAttempt {
        await accessControl.recordFailure(
          identity, path: context.path, reason: String(describing: failure)
        )
      }
      if case .serverMisconfigured(let reason) = failure {
        // The server's fault, so it reports as one — and does not count against the
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

// MARK: - Error rendering

public enum ErrorRenderer {

  /// The most human-readable sentence an arbitrary error can offer.
  ///
  /// `BBError.body` first: the protocol requires it to be "one or two sentences a
  /// non-developer can act on", so it beats anything that could be inferred. `LocalizedError`
  /// next, for the types that wrote an explanation without adopting `BBError`.
  /// `String(describing:)` last, because on an enum it renders the CASE —
  /// `scriptFailed(number: -1728, message: "Messages got an error: …")`, escaped quotes and
  /// all — which reads to a client like a crash rather than like the clear explanation it
  /// actually contains.
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
  /// **A `BBError` is not mapped onto a status.** It is tempting — the protocol carries a
  /// `severity` — but severity answers "how bad is this", not "whose fault is it", and those
  /// are different questions: a `.warning` is not a 400, and guessing would silently move
  /// responses that clients have been reading as 500s since the Node server. So the status
  /// and the error type stay exactly where they were, and what the bridge recovers is the
  /// part that was being thrown away outright — the readable `body` on the wire, and `code`,
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
  /// The full `String(describing:)` is always present — the client-facing message may be the
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

/// Per-route counters, kept in memory and surfaced on `GET /api/v1/server/info`.
///
/// Bounded by the route table, which is a fixed size — deliberately keyed by the route
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

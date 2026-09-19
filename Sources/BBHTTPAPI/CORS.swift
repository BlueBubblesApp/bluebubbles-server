//  CORS
//  Which browser origins may talk to this server, and what they may send.
//
//  **CORS is a browser mechanism and nothing else.** A native client never sends `Origin` and
//  never reads `Access-Control-Allow-Origin`: the app, `curl`, another server, anything behind
//  any tunnel. So nothing here can refuse a non-browser client on any deployment, and that is
//  what makes narrowing the origin safe to offer at all — it only ever removes reach a WEB PAGE
//  has, never reach a client has.
//
//  What the default grants is worth stating plainly, because `*` reads as harmless: any page
//  the user happens to have open can issue requests to their server from their browser and READ
//  the responses. Without the password those are 401s. With it — and the password is routinely
//  in browser history, because v1 puts it in the query string — that page holds the whole API.
//
//  So the origin is a setting (`cors_allowed_origin`) and its default is `*`, which is
//  byte-for-byte what the reference sends and what every client has always seen.
//
//  See `.claude/docs/api.md`.

import Foundation
import HTTPTypes
import Hummingbird

/// Which origins are allowed, and what to answer a given request with.
public struct CORSPolicy: Sendable, Equatable {

  /// The configured value that means "every origin", and the default.
  public static let wildcard = "*"

  /// Empty means wildcard. Origins are stored normalized for comparison; the value ECHOED is
  /// the one the client sent, because an origin is opaque to us and a normalized spelling is
  /// not guaranteed to be one the browser will accept back.
  private let allowed: Set<String>

  public var isWildcard: Bool { allowed.isEmpty }

  /// Parses the setting.
  ///
  /// A comma-separated list, because `Access-Control-Allow-Origin` may carry exactly one
  /// origin or `*` — never a list. Several origins are expressed by ECHOING the request's own
  /// when it is one of them, which is the only way the header can say "these three", and is
  /// why `Vary: Origin` below is not optional.
  ///
  /// An empty or all-whitespace value is the wildcard rather than "nothing allowed". A setting
  /// someone cleared by selecting and deleting must not silently lock every browser out of a
  /// server they can no longer reach to fix it.
  public init(configured: String) {
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != Self.wildcard else {
      allowed = []
      return
    }
    allowed = Set(
      trimmed
        .split(separator: ",")
        .map { Self.normalize(String($0)) }
        .filter { !$0.isEmpty }
    )
    // Not a `guard` above: a value that is entirely separators (`","`) parses to nothing, and
    // an empty set is the wildcard by the rule stated there.
  }

  /// A scheme and authority, lowercased, with any trailing slash dropped.
  ///
  /// `https://Example.com/` and `https://example.com` are one origin; a browser sends the
  /// second spelling, and an operator types either.
  static func normalize(_ origin: String) -> String {
    var value = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  /// What `Access-Control-Allow-Origin` should say, or nil for "send no such header".
  ///
  /// Nil is a refusal, and it is the whole of one: a browser that receives no header blocks
  /// the response itself. There is no status to return and nothing for the server to do
  /// differently — the request is served normally, and the page is not allowed to read it.
  public func allowOriginHeader(for requestOrigin: String?) -> String? {
    guard !isWildcard else { return Self.wildcard }
    guard let requestOrigin, allowed.contains(Self.normalize(requestOrigin)) else { return nil }
    // The client's own spelling, not our normalized one: a browser compares this against the
    // origin it sent, and `https://example.com` answered to `https://Example.com` is a
    // mismatch on a comparison we do not control.
    return requestOrigin
  }

  /// Whether the answer depends on the request's `Origin`, and so must not be cached across
  /// origins. True for every non-wildcard policy — a shared cache in front of this server
  /// would otherwise hand one origin's allowance to another.
  public var variesByOrigin: Bool { !isWildcard }
}

/// Headers a browser may never assert on this server, because something here believes them.
/// They are set by a reverse proxy, not by a caller.
///
/// **`Access-Control-Allow-Headers: *` was a decision wearing the origin policy's clothes.** A
/// wildcard there tells a browser that a cross-origin request may carry ANY header, which
/// includes `X-Forwarded-For`. Loopback is a trusted proxy by default (the bundled tunnels all
/// run here), so a page in the operator's browser could send a failed login with a forwarding
/// header of its choosing and have the failure attributed to an address it picked: blocking
/// third parties, and growing a map an attacker then supplies the keys for.
///
/// So the reflected set is what the request actually asked for, minus these. A client sending
/// `Authorization` or `Content-Type` is unaffected, which is every real client.
public enum CORSHeaderPolicy {

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

  let policy: CORSPolicy

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    let origin = request.headers[.origin]

    if request.method == .options {
      var headers = HTTPFields()
      CORSPolicy.apply(policy, origin: origin, to: &headers)
      headers[.accessControlAllowMethods] = "GET, POST, PUT, DELETE, OPTIONS"
      let allowed = CORSHeaderPolicy.allowedHeaders(
        requested: request.headers[.accessControlRequestHeaders])
      if !allowed.isEmpty { headers[.accessControlAllowHeaders] = allowed }
      return Response(status: .noContent, headers: headers)
    }

    var response = try await next(request, context)
    CORSPolicy.apply(policy, origin: origin, to: &response.headers)
    return response
  }
}

extension CORSPolicy {

  /// Writes the origin headers onto a response.
  ///
  /// Shared by the middleware and by `SocketIOTransport`, which builds its own responses on
  /// the same listener: one server, one answer about who may reach it from a browser. Two
  /// implementations would mean narrowing the origin left the socket wide open, which is the
  /// half of the API a browser client actually streams from.
  public static func apply(_ policy: CORSPolicy, origin: String?, to headers: inout HTTPFields) {
    if let allow = policy.allowOriginHeader(for: origin) {
      headers[.accessControlAllowOrigin] = allow
    }
    // On every response, INCLUDING the ones with no allow header: what a cache must not do is
    // reuse this answer for a different origin, and that is just as true of an answer that
    // allowed nobody.
    if policy.variesByOrigin {
      headers[.vary] = headers[.vary].map { "\($0), Origin" } ?? "Origin"
    }
  }
}

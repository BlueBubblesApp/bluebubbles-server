//  APIDocsRelay
//  The native half of the API reference's "Try it" button.
//
//  WHY THE PAGE DOES NOT SEND ITS OWN REQUESTS. Scalar's client is a browser client: it
//  calls `fetch` from the page, and the page is a `file://` document whose CSP is
//  `connect-src 'none'`. Making the client work by relaxing that directive is the obvious
//  move and the wrong one, for three separate reasons:
//
//    1. `connect-src` would have to name the server's origin, which is a runtime value —
//       a port, or whatever tunnel `server_address` currently points at. A CSP that has to
//       be templated is a CSP someone can template wrong, and the reason the directive is
//       worth having is that it is the ONE lock in `index.html` that a config edit cannot
//       pick. See the header comment there.
//    2. A `file://` page has a `null` origin, so every request is cross-origin. It works
//       today only because this server answers `Access-Control-Allow-Origin: *`, which
//       `HTTPServer.swift` documents as a deferred decision rather than a settled one. The
//       reference window should not be the thing that makes tightening it a breaking change.
//    3. App Transport Security applies to `WKWebView`. `http://localhost` is exempt;
//       `http://192.168.1.50:1234` is not. A LAN address in `server_address` would make
//       "Try it" fail in a way that looks like a server bug and is not.
//
//  So the page keeps `connect-src 'none'` and hands every request to this class over
//  `WKScriptMessageHandlerWithReply`, which is not subject to CSP at all. Scalar takes a
//  `customFetch` in its configuration (1.67.0; verified against the bundled build), so this
//  needs no patching of the vendored JavaScript — `index.html` supplies a `fetch` shim that
//  marshals to here and rebuilds a `Response` from the reply.
//
//  What that buys, beyond the three problems above: no CORS preflight, no `null` origin, no
//  ATS, no proxy, and the server password never leaves this process by any route the page
//  controls.

import BBCore
import BBHTTPAPI
import Foundation
import WebKit

// MARK: - Policy

/// The rules a relayed request is held to, with no web view attached.
///
/// Separate from the handler so they can be tested against strings rather than against a
/// `WKWebView`, a run loop, and a server that answers.
enum APIDocsRelayPolicy {

  /// The relay refuses a response larger than this.
  ///
  /// The reply crosses the JavaScript bridge as base64, so the cost of a large body is paid
  /// about 2.4x over — the `Data`, the base64 string, and the `Uint8Array` the page rebuilds.
  /// `/api/v1/attachment/:guid/download` can serve half a gigabyte, and a console is not a
  /// download manager: the honest answer to that request is a refusal with a reason, not a
  /// window that hangs and then dies. The cap is enforced as the bytes arrive rather than
  /// after, so a 500MB attachment is never resident.
  static let maximumResponseBytes = 8 * 1024 * 1024

  /// Headers the page may not assert, because something on the other end believes them.
  ///
  /// A browser enforces this for a cross-origin `fetch` and `CORSMiddleware` enforces it on
  /// arrival; a native relay is neither, so the same list has to be applied here by hand.
  /// It is `CORSHeaderPolicy.forbidden` itself and not a copy of it, because the failure
  /// mode of a copy is that one of them grows an entry and the other does not — and the
  /// entry that matters is `X-Forwarded-For`, which loopback is trusted to have set. A page
  /// that could set it could make a failed login count against an address it picked.
  ///
  /// `host`, `content-length` and `connection` are added because URLSession derives all
  /// three, and a caller-supplied value either contradicts the request or is a Host-header
  /// trick. A browser would not let the page set them either; this does not rely on that.
  static let forbiddenRequestHeaders: Set<String> =
    CORSHeaderPolicy.forbidden.union(["host", "content-length", "connection"])

  /// Scheme, host and port, with the default port made explicit so `http://x` and
  /// `http://x:80` compare equal.
  ///
  /// `nil` for anything that is not an absolute `http`/`https` URL, which is what makes
  /// `file:`, `data:` and a bare path fail the allowlist rather than slip past it.
  static func origin(of url: URL) -> String? {
    guard
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(),
      !host.isEmpty
    else { return nil }
    return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
  }

  /// Where the relay will dial.
  ///
  /// NOT "wherever the page asked": Scalar's client puts the URL in an editable address bar,
  /// so the request URL is operator input, and operator input that arrives through a web
  /// view is still input. The set is the address this install advertises in the document's
  /// `servers` block, plus loopback at the listening port.
  ///
  /// Loopback is in the set even when `server_address` names a tunnel. Otherwise every
  /// "Try it" on a proxied install would leave the machine, cross the public internet and
  /// come back — slow, and broken outright whenever the tunnel is down, for a request whose
  /// destination is a process on this Mac.
  static func allowedOrigins(serverURL: String, loopbackPort: Int) -> Set<String> {
    var origins: Set<String> = []
    if let url = URL(string: serverURL), let origin = origin(of: url) {
      origins.insert(origin)
    }
    // Built through `origin(of:)` rather than by interpolation so both sides of the
    // comparison are normalized by the same code. `[::1]` in particular does not survive a
    // round trip through `URL.host` with its brackets on.
    for host in ["localhost", "127.0.0.1", "[::1]"] {
      if let url = URL(string: "http://\(host):\(loopbackPort)"), let origin = origin(of: url) {
        origins.insert(origin)
      }
    }
    return origins
  }

  static func isAllowed(_ url: URL, origins: Set<String>) -> Bool {
    guard let origin = origin(of: url) else { return false }
    return origins.contains(origin)
  }

  /// The request headers, minus the ones above. Names arrive lowercased from `Headers`.
  static func sanitized(requestHeaders headers: [(name: String, value: String)])
    -> [(name: String, value: String)]
  {
    headers.filter { !forbiddenRequestHeaders.contains($0.name.lowercased()) }
  }

  /// The response headers, minus the two that describe bytes the page will never see.
  ///
  /// URLSession negotiates and undoes content encoding on its own, so it hands back decoded
  /// bytes under a `Content-Encoding: gzip` the server really did send. Forwarding that pair
  /// would have the console display a length and an encoding for a body that has neither,
  /// and someone would eventually spend an afternoon on it.
  static func sanitized(responseHeaders headers: [(name: String, value: String)])
    -> [(name: String, value: String)]
  {
    let dropped: Set<String> = ["content-encoding", "content-length"]
    return headers.filter { !dropped.contains($0.name.lowercased()) }
  }
}

// MARK: - Prefill

/// What the page is handed before its own script runs.
///
/// Here rather than on the view for the reason every other decision in this app is: a
/// `static func` on a SwiftUI `View` cannot be called from a test process without trapping,
/// and this one escapes a secret into a `<script>`.
enum APIDocsPagePrefill {

  /// Scalar's `authentication` config, as a JavaScript literal.
  ///
  /// `passwordQuery` of the five spellings this API accepts, for no reason beyond it being
  /// the one the documentation uses. Prefilled at all because the window beside this one
  /// already knows the password, and a console that makes the operator go and look it up is
  /// a console they use once.
  ///
  /// Built with `JSONSerialization` rather than interpolated. A password is a value a person
  /// typed: a quote in it ends the statement early, which is a syntax error on a good day
  /// and an injection into this page's own script on a bad one. An empty password yields
  /// `null`, so a server with none set opens an empty Auth panel rather than one prefilled
  /// with nothing, which reads as a bug.
  static func authentication(password: String) -> String {
    guard !password.isEmpty else { return "null" }
    let payload: [String: Any] = [
      "preferredSecurityScheme": "passwordQuery",
      "securitySchemes": ["passwordQuery": ["value": password]],
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else { return "null" }
    return json
  }
}

// MARK: - The handler

/// Performs the requests the reference's client asks for, and answers with what came back.
///
/// One instance per web view, owned by its `WKUserContentController`.
@MainActor
final class APIDocsRelay: NSObject, WKScriptMessageHandlerWithReply {

  /// The name the page posts to. Mirrored in `index.html`; changing one without the other
  /// turns every "Send" into "the app is not listening", which is at least a clear message.
  static let messageHandlerName = "bbAPIRelay"

  private let allowedOrigins: Set<String>
  private let session: URLSession
  private let redirects = RedirectRefusal()

  init(allowedOrigins: Set<String>) {
    self.allowedOrigins = allowedOrigins

    let configuration = URLSessionConfiguration.ephemeral
    // A console that quietly replayed a cached body would be worse than useless: the whole
    // point of pressing Send is to see what the server says now.
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    // No ambient credentials. Whatever authenticates the request is what the operator typed
    // into the Auth panel, visible in the request the console shows them.
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    // Long enough for a slow `/api/v1/message/query` on a large chat.db, short enough that a
    // wedged request eventually reports instead of spinning forever.
    configuration.timeoutIntervalForRequest = 60
    self.session = URLSession(configuration: configuration)

    super.init()
  }

  // MARK: WKScriptMessageHandlerWithReply

  nonisolated func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor (Any?, String?) -> Void
  ) {
    MainActor.assumeIsolated {
      guard message.name == Self.messageHandlerName else {
        replyHandler(nil, "Unexpected message.")
        return
      }
      let payload = message.body
      Task {
        do {
          replyHandler(try await self.perform(payload), nil)
        } catch {
          // The string is what Scalar renders in its error toast, so it is written to be
          // read by whoever pressed the button rather than by whoever wrote this file.
          replyHandler(nil, DiagnosticText.sentence(for: error))
        }
      }
    }
  }

  // MARK: The request

  private func perform(_ payload: Any) async throws -> [String: Any] {
    let relayed = try RelayedRequest(payload)

    guard APIDocsRelayPolicy.isAllowed(relayed.url, origins: allowedOrigins) else {
      throw RelayFailure.originNotAllowed(relayed.url, allowedOrigins)
    }

    var request = URLRequest(url: relayed.url)
    request.httpMethod = relayed.method
    for header in APIDocsRelayPolicy.sanitized(requestHeaders: relayed.headers) {
      request.setValue(header.value, forHTTPHeaderField: header.name)
    }
    request.httpBody = relayed.body

    let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
    guard let http = response as? HTTPURLResponse else {
      throw RelayFailure.notHTTP
    }

    // Read with the cap applied per byte rather than trusting `Content-Length`, which a
    // chunked response does not send and a lying one gets wrong. `AsyncBytes` reads from a
    // buffer underneath, so this is not a syscall per byte; it is a comparison per byte, and
    // the ceiling it enforces is the point.
    var body = Data()
    body.reserveCapacity(
      min(max(Int(http.expectedContentLength), 0), APIDocsRelayPolicy.maximumResponseBytes))
    for try await byte in bytes {
      guard body.count < APIDocsRelayPolicy.maximumResponseBytes else {
        throw RelayFailure.responseTooLarge
      }
      body.append(byte)
    }

    let headers: [(name: String, value: String)] = http.allHeaderFields.compactMap {
      guard let name = $0.key as? String, let value = $0.value as? String else { return nil }
      return (name, value)
    }

    return [
      "status": http.statusCode,
      // Empty on purpose: `HTTPURLResponse` does not keep the reason phrase, and
      // `localizedString(forStatusCode:)` returns prose ("not found") rather than the HTTP
      // one ("Not Found"). Scalar names the status from its own table when this is empty.
      "statusText": "",
      "headers": APIDocsRelayPolicy.sanitized(responseHeaders: headers).map {
        [$0.name, $0.value]
      },
      "body": body.base64EncodedString(),
    ]
  }
}

// MARK: - The message

/// What the page sent, checked.
private struct RelayedRequest {
  let url: URL
  let method: String
  let headers: [(name: String, value: String)]
  let body: Data?

  init(_ payload: Any) throws {
    guard let message = payload as? [String: Any] else { throw RelayFailure.malformed }
    guard
      let urlString = message["url"] as? String,
      let url = URL(string: urlString)
    else { throw RelayFailure.malformed }

    self.url = url
    self.method = (message["method"] as? String ?? "GET").uppercased()

    // `[[name, value], ...]` rather than an object, because HTTP allows a header to repeat
    // and a JavaScript object does not.
    let pairs = message["headers"] as? [[String]] ?? []
    self.headers = pairs.compactMap { pair in
      guard pair.count == 2, !pair[0].isEmpty else { return nil }
      return (pair[0], pair[1])
    }

    if let encoded = message["body"] as? String, !encoded.isEmpty {
      guard let data = Data(base64Encoded: encoded) else { throw RelayFailure.malformed }
      self.body = data
    } else {
      self.body = nil
    }
  }
}

// MARK: - Failures

private enum RelayFailure: LocalizedError {
  case malformed
  case notHTTP
  case responseTooLarge
  case originNotAllowed(URL, Set<String>)

  var errorDescription: String? {
    switch self {
    case .malformed:
      return "The reference sent a request this app could not read."
    case .notHTTP:
      return "The server answered with something that was not an HTTP response."
    case .responseTooLarge:
      let megabytes = APIDocsRelayPolicy.maximumResponseBytes / (1024 * 1024)
      return
        "The response is larger than \(megabytes) MB, which is more than this window will "
        + "load. Use curl for that endpoint."
    case .originNotAllowed(let url, let origins):
      let host = APIDocsRelayPolicy.origin(of: url) ?? url.absoluteString
      return
        "This window only sends requests to this server. It will not send one to \(host). "
        + "Allowed: \(origins.sorted().joined(separator: ", "))."
    }
  }
}

// MARK: - Redirects

/// Refuses to follow redirects, so the response the console shows is the one the server
/// actually returned.
///
/// It is also what keeps the allowlist meaningful: a followed redirect is a second request
/// to an address nothing checked, and `Location` is chosen by the other end.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

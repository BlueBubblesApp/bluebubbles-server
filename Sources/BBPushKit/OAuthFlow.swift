//  OAuthFlow
//  The browser hand-off that gets a Google token for provisioning.
//
//  The port number is not adjustable and the path is not ours to rename: `http://localhost:8641
//  /oauth/callback` is the redirect URI registered against the OAuth client in Google's
//  console, and Google rejects any redirect that does not match exactly. Changing either
//  would break setup for everyone until the client registration was updated, which is outside
//  this repository.
//
//  See `docs/EVENTS.md`.

import BBCore
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public enum OAuthFlowError: BBError, Equatable {
  case portUnavailable(port: Int)
  case timedOut
  case denied(reason: String)
}

public enum OAuthPurpose: String, Sendable {
  /// Creating and configuring a Firebase project. The only purpose there is.
  ///
  /// The current server also has a `contacts.readonly` flow, which does not exist here and
  /// should not: it is a workaround for `node-mac-contacts` being unable to see Google
  /// contacts, and the cause is that library enumerating CONTAINERS
  /// (`containersMatchingPredicate:nil` does not reliably list CardDAV accounts on macOS) so
  /// contacts in them were never queried. `ContactsIngestor` runs an unfiltered
  /// `CNContactFetchRequest` over the whole store, which includes every account configured
  /// in Contacts. Asking Google for contacts the address book already hands us would mean a
  /// second OAuth consent, a second copy of every contact, and two sources to disagree.
  case firebase

  var scopes: [String] {
    switch self {
    case .firebase:
      [
        "https://www.googleapis.com/auth/cloudplatformprojects",
        "https://www.googleapis.com/auth/service.management",
        "https://www.googleapis.com/auth/firebase",
        "https://www.googleapis.com/auth/datastore",
        "https://www.googleapis.com/auth/iam",
      ]
    }
  }
}

public struct OAuthConfiguration: Sendable {
  /// The public OAuth client. Not a secret: it identifies the application to Google, and
  /// it is embedded in every distributed copy of the reference too.
  public let clientId: String
  /// Fixed: it is what the redirect URI is registered as.
  public let port: Int

  public init(
    clientId: String = "500464701389-os4g4b8mfoj86vujg4i61dmh9827qbrv.apps.googleusercontent.com",
    port: Int = 8641
  ) {
    self.clientId = clientId
    self.port = port
  }

  public var redirectURI: String { "http://localhost:\(port)/oauth/callback" }

  /// The URL the user is sent to.
  ///
  /// The implicit flow (`response_type=token`). Not because the reference uses it: this
  /// exchange is between this server and Google, and no BlueBubbles client can see it, but
  /// because the OAuth client registration determines which flows are permitted, and that
  /// registration lives in a Google console outside this repository. It is not the flow one
  /// would choose today; the authorization-code flow with PKCE is better. Noted here so the
  /// choice is understood as
  /// inherited rather than made.
  /// The value carried in `state`, and checked when the token comes back.
  ///
  /// `state` used to be `purpose.rawValue`: a constant, set and never verified. That left
  /// the callback accepting any body containing an `access_token` from any local origin,
  /// for the five minutes the listener is up. The landing page posts with no content type,
  /// so a cross-origin `fetch` is a CORS-simple request needing no preflight — meaning any
  /// page open in the operator's browser, or any local process, could inject a token of its
  /// choosing and have Firebase provisioning run against the ATTACKER's project, routing the
  /// operator's notification payloads through infrastructure they do not control.
  ///
  /// A random nonce makes the callback answerable only by the flow that started it. Google
  /// returns `state` in the fragment for the implicit flow, so it arrives in the same body
  /// the token does, with nothing extra asked of the page.
  public func state(for purpose: OAuthPurpose, nonce: String) -> String {
    "\(purpose.rawValue).\(nonce)"
  }

  /// A fresh nonce. 128 bits from the system generator; this only has to be unguessable
  /// within a five-minute window.
  public static func makeNonce() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  public func authorizationURL(for purpose: OAuthPurpose, nonce: String) -> URL {
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "token"),
      URLQueryItem(name: "scope", value: purpose.scopes.joined(separator: " ")),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
      // Carried through the redirect so the landing page knows which flow finished.
      URLQueryItem(name: "state", value: state(for: purpose, nonce: nonce)),
    ]
    return components.url!
  }
}

/// Serves the landing page Google redirects to.
///
/// With the implicit flow the token arrives in the URL FRAGMENT, which a browser never sends
/// to the server, so this page cannot read it directly. A small script reads it client-side
/// and posts it back. That shape is forced by the fragment, not copied: a server cannot read
/// what a browser never sends it.
public actor OAuthCallbackServer {

  private let configuration: OAuthConfiguration
  private let logger: Logger
  private let group: any EventLoopGroup
  private let ownsGroup: Bool
  private var channel: (any Channel)?
  private var waiters: [CheckedContinuation<String, any Error>] = []

  public init(
    configuration: OAuthConfiguration = OAuthConfiguration(),
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.push.oauth")
  ) {
    self.configuration = configuration
    self.logger = logger
    if let group {
      self.group = group
      self.ownsGroup = false
    } else {
      self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      self.ownsGroup = true
    }
  }

  /// The nonce this server will accept, generated when it is constructed so the URL the
  /// caller opens and the body this listener accepts cannot disagree.
  public let nonce = OAuthConfiguration.makeNonce()

  public func authorizationURL(for purpose: OAuthPurpose) -> URL {
    configuration.authorizationURL(for: purpose, nonce: nonce)
  }

  /// - Parameter purpose: which flow this listener is answering. It is part of the `state`
  ///   the callback must echo, so the listener and the URL cannot disagree about it.
  public func start(for purpose: OAuthPurpose) async throws {
    guard channel == nil else { return }
    // Bound out of the actor before the closure, for the same reason `deliver` is: the
    // bootstrap's handler closure is `@Sendable` and cannot reach actor state.
    let expectedState = configuration.state(for: purpose, nonce: nonce)
    do {
      // Bound before the closure: capturing `self` inside a @Sendable initializer while
      // still inside the actor's own init path is what the concurrency checker rejects.
      let deliver: @Sendable (String) -> Void = { [weak self] token in
        Task { await self?.deliver(token: token) }
      }
      channel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
          channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(
              CallbackHandler(
                onToken: deliver,
                expectedState: expectedState))
          }
        }
        // localhost only: the redirect comes from the user's own browser, and binding
        // more widely would expose the token-receiving endpoint to the network.
        .bind(host: "127.0.0.1", port: configuration.port)
        .get()
    } catch {
      throw OAuthFlowError.portUnavailable(port: configuration.port)
    }
    logger.info(
      "OAuth callback server listening",
      metadata: [
        "port": .stringConvertible(configuration.port)
      ])
  }

  public func stop() async {
    for waiter in waiters { waiter.resume(throwing: OAuthFlowError.timedOut) }
    waiters.removeAll()
    if let channel {
      try? await channel.close().get()
      self.channel = nil
    }
    if ownsGroup { try? await group.shutdownGracefully() }
  }

  /// Waits for the browser to hand back a token.
  public func awaitToken(timeout: Duration = .seconds(300)) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          Task { await self.enqueue(continuation) }
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw OAuthFlowError.timedOut
      }
      defer { group.cancelAll() }
      guard let token = try await group.next() else { throw OAuthFlowError.timedOut }
      return token
    }
  }

  private func enqueue(_ continuation: CheckedContinuation<String, any Error>) {
    waiters.append(continuation)
  }

  private func deliver(token: String) {
    for waiter in waiters { waiter.resume(returning: token) }
    waiters.removeAll()
  }
}

// MARK: - HTTP

/// Answers the redirect, and accepts the token the page posts back.
private final class CallbackHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let onToken: @Sendable (String) -> Void
  /// The exact `state` this flow sent. A posted body whose state does not match it is not
  /// this flow's answer, whoever sent it.
  private let expectedState: String
  private var head: HTTPRequestHead?
  private var body = ByteBufferAllocator().buffer(capacity: 0)

  init(onToken: @escaping @Sendable (String) -> Void, expectedState: String) {
    self.onToken = onToken
    self.expectedState = expectedState
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      self.head = head
      body.clear()
    case .body(var buffer):
      body.writeBuffer(&buffer)
    case .end:
      respond(context: context)
    }
  }

  private func respond(context: ChannelHandlerContext) {
    guard let head else { return }
    let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

    switch (head.method, path) {
    case (.GET, "/oauth/callback"):
      write(context: context, status: .ok, body: Self.landingPage, contentType: "text/html")

    case (.POST, "/oauth/token"):
      // The fragment, read by the page's script and posted back here.
      let text = body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""
      // The nonce FIRST. A body that does not carry this flow's state is somebody else's,
      // and the token in it must not be looked at, let alone used.
      guard let state = OAuthCallbackParsing.value(named: "state", inFragment: text),
        OAuthCallbackParsing.constantTimeEquals(state, expectedState)
      else {
        write(
          context: context, status: .forbidden, body: "unexpected state",
          contentType: "text/plain")
        return
      }
      if let token = OAuthCallbackParsing.accessToken(inFragment: text) {
        onToken(token)
        write(context: context, status: .ok, body: "ok", contentType: "text/plain")
      } else {
        write(context: context, status: .badRequest, body: "no token", contentType: "text/plain")
      }

    default:
      write(context: context, status: .notFound, body: "Not found", contentType: "text/plain")
    }
  }

  private func write(
    context: ChannelHandlerContext,
    status: HTTPResponseStatus,
    body text: String,
    contentType: String
  ) {
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: contentType)
    headers.add(name: "Content-Length", value: String(text.utf8.count))
    // The page is served once to one browser and the server then stops; caching it would
    // only ever serve a stale hand-off.
    headers.add(name: "Cache-Control", value: "no-store")

    context.write(
      wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
      promise: nil
    )
    var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }

  /// The token lives in the fragment, so only the browser can see it. This reads it and
  /// hands it back, then clears it from the address bar so it does not sit in history.
  static let landingPage = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>BlueBubbles</title></head>
    <body style="font-family: -apple-system, sans-serif; padding: 3rem; text-align: center">
      <h2 id="status">Finishing sign-in…</h2>
      <p id="detail">You can close this window when it is done.</p>
      <script>
        (function () {
          var fragment = window.location.hash || "";
          if (!fragment) {
            document.getElementById("status").textContent = "No sign-in information was returned.";
            return;
          }
          fetch("/oauth/token", { method: "POST", body: fragment })
            .then(function () {
              document.getElementById("status").textContent = "Signed in.";
              document.getElementById("detail").textContent =
                "You can close this window and return to BlueBubbles.";
              // Keep the token out of browser history.
              history.replaceState(null, "", window.location.pathname);
            })
            .catch(function () {
              document.getElementById("status").textContent = "Could not complete sign-in.";
            });
        })();
      </script>
    </body></html>
    """
}

// MARK: - Test access

/// The pure parts of the callback handler, reachable by tests.
///
/// The handler itself stays private: it owns a channel pipeline and has no business being
/// constructed elsewhere, but fragment parsing and the landing page are worth pinning, and
/// both are pure.
enum CallbackHandlerAccess {
  static func accessToken(inFragment fragment: String) -> String? {
    OAuthCallbackParsing.accessToken(inFragment: fragment)
  }
  static var landingPage: String { CallbackHandler.landingPage }
}

// MARK: - Revocation

/// Hands a user access token back to Google once it has done its job.
///
/// The token from the provisioning flow carries `cloudplatformprojects` and `iam`: enough to
/// create projects and mint service-account keys on the user's whole Google Cloud account.
/// Provisioning needs it for a few minutes; nothing needs it afterwards, and it otherwise
/// stays valid for an hour. The reference server revokes it at the end of setup for exactly
/// this reason, and the port of that flow had dropped the step.
public enum GoogleTokenRevocation {

  /// Best-effort. A token that cannot be revoked is not a setup failure: it expires on its
  /// own within the hour, so this never throws over a provisioning run that succeeded.
  public static func revoke(
    _ token: String,
    using http: any HTTPPerforming,
    logger: Logger = Logger(label: "bluebubbles.push.oauth")
  ) async {
    guard !token.isEmpty else { return }
    do {
      // Form-encoded, per RFC 7009 and Google's implementation of it.
      let (status, _) = try await http.perform(
        method: "POST",
        url: "https://oauth2.googleapis.com/revoke",
        headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data("token=\(token)".utf8)
      )
      if (200...299).contains(status) {
        logger.info("Revoked the Google sign-in token used for setup")
      } else {
        logger.debug(
          "Google declined to revoke the setup token",
          metadata: [
            "status": .stringConvertible(status)
          ])
      }
    } catch {
      logger.debug(
        "Could not reach Google to revoke the setup token",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }
}

extension OAuthFlowError {
  public var code: String {
    switch self {
    case .portUnavailable: "oauth.port_unavailable"
    case .timedOut: "oauth.timed_out"
    case .denied: "oauth.denied"
    }
  }

  public var domain: String { "Push" }

  /// Every one of these happens while the user is watching a sign-in window.
  public var isUserFacing: Bool { true }

  public var title: String { "Google sign-in did not complete" }

  public var body: String {
    switch self {
    case .portUnavailable(let port):
      "The server could not listen on port \(port) to receive the sign-in reply. Another "
        + "program is using it."
    case .timedOut:
      "The sign-in window was not completed in time. Starting it again is safe."
    case .denied(let reason):
      "Google declined the sign-in: \(reason)"
    }
  }
}

/// The callback's parsing and comparison, outside the private channel handler so it can be
/// tested without standing up a listener.
public enum OAuthCallbackParsing {
  /// Pulls one named value out of a URL fragment.
  public static func value(named name: String, inFragment fragment: String) -> String? {
    let trimmed = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
    for pair in trimmed.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == name else { continue }
      return String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }
    return nil
  }

  /// Compared in constant time. The nonce is a secret for the life of the flow, and a
  /// timing oracle on a loopback listener is cheap to exploit.
  public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let left = Array(a.utf8)
    let right = Array(b.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(left, right) { difference |= x ^ y }
    return difference == 0
  }

  /// Pulls `access_token` out of a URL fragment.
  public static func accessToken(inFragment fragment: String) -> String? {
    let trimmed = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
    for pair in trimmed.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, parts[0] == "access_token" else { continue }
      return String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }
    return nil
  }
}

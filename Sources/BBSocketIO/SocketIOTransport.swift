//  SocketIOTransport
//  The Hummingbird binding: `/socket.io/` over long-polling and websocket.
//
//  Deliberately the only file in this module that imports Hummingbird, matching how the HTTP
//  layer is split: the protocol, the session model and the state machine are all testable
//  without binding a port, and swapping the web framework touches this file and no other.
//
//  Why the routes are mounted here rather than added to `RouteTable`: the table is the
//  parity contract for `/api/v1`, diffed route-by-route against the Node server's. `/socket.io/`
//  is not part of that surface, and putting it in the table would make the parity harness
//  report a route the Node server's REST table does not have.
//
//  See `docs/EVENTS.md`.

import BBAuth
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import NIOCore
import WSCore

public struct SocketIOTransport: Sendable {

  private let engine: EngineIOServer
  private let logger: Logger
  /// The CORS headers for a request carrying this `Origin`.
  ///
  /// A closure rather than a policy type, so this target gains no dependency on BBHTTPAPI for
  /// one value. The RULE (which origins are allowed, and that a narrowed one implies
  /// `Vary: Origin`) lives in `CORSPolicy` and is applied here by the composition root, which
  /// is the one place that already sees both — rather than being re-implemented against the
  /// same setting, which is how narrowing the origin would leave the event stream wide open.
  ///
  /// The default is the wide-open set this transport has always sent, so a caller that does
  /// not wire it — every test — behaves exactly as before.
  private let corsHeaders: @Sendable (String?) -> HTTPFields

  public init(
    engine: EngineIOServer,
    corsHeaders: @escaping @Sendable (String?) -> HTTPFields = { _ in
      SocketIOTransport.defaultCORSHeaders
    },
    logger: Logger = Logger(label: "bluebubbles.socket.transport")
  ) {
    self.engine = engine
    self.corsHeaders = corsHeaders
    self.logger = logger
  }

  /// The path both transports live on. Trailing slash included: that is what clients
  /// request, and Socket.IO's own default.
  public static let path = "/socket.io/"

  // MARK: - Polling

  /// Mounts the long-polling endpoints.
  ///
  /// Polling is not a fallback here. Every Socket.IO client OPENS on polling and upgrades
  /// afterwards, so this path is on the critical path for every single connection,
  /// including the ones that end up on a websocket a moment later.
  /// - Note: the context must carry the remote address. That is not a convenience: without
  ///   it every handshake resolves as `.unresolved`, and the access control the engine now
  ///   applies degrades to global throttling with no per-client blocking at all. The HTTP
  ///   layer's `BBRequestContext` conforms for the same reason.
  public func mount<Context: RequestContext & RemoteAddressRequestContext>(
    on router: Router<Context>
  ) {
    router.on(RouterPath(Self.path), method: .get) { request, context in
      // The address alone, never the port: every request from one client arrives on a
      // different ephemeral port, so keying on it would give each its own counter and no
      // failure would ever accumulate. Matches `SocketAddress.bbClientAddress` on the HTTP
      // side and the websocket upgrade in `HTTPListener`.
      await self.handleGet(request, peerAddress: context.remoteAddress?.ipAddress)
    }
    router.on(RouterPath(Self.path), method: .post) { request, _ in
      await self.handlePost(request)
    }
    // Clients send a CORS preflight before the POST when they are running in a browser.
    router.on(RouterPath(Self.path), method: .options) { request, _ in
      var headers = self.corsHeaders(request.headers[.origin])
      // Narrowed, exactly as the REST preflight narrows it. This used to answer
      // `Access-Control-Allow-Headers: *`, which tells a browser a cross-origin request may
      // carry ANY header — `X-Forwarded-For` included, and loopback is a trusted proxy by
      // default. The REST side closed that and the socket, on the same listener and the same
      // port, went on reflecting the wildcard. See `CORSHeaderPolicy`.
      let allowed = Self.allowedRequestHeaders(
        requested: request.headers[.accessControlRequestHeaders])
      if allowed.isEmpty {
        headers[.accessControlAllowHeaders] = nil
      } else {
        headers[.accessControlAllowHeaders] = allowed
      }
      return Response(status: .noContent, headers: headers)
    }
  }

  private func handleGet(_ request: Request, peerAddress: String?) async -> Response {
    let query = Self.queryParameters(from: request.uri)
    let origin = request.headers[.origin]

    // No sid means "open a session"; a sid means "give me what you have".
    guard let sid = query["sid"] else {
      // The CONNECTION's address, with the forwarding header passed alongside rather than
      // instead of it. This used to take `X-Forwarded-For` as the client address outright,
      // so the caller chose what was logged and, now that the handshake is rate limited,
      // would have chosen whose failures it was counted against. Which of the two to
      // believe is the access controller's decision and it already knows how to make it.
      switch await engine.open(
        query: query,
        clientAddress: peerAddress,
        forwardedFor: request.headers[.init("X-Forwarded-For")!]
      ) {
      case .established(_, let packets):
        return payloadResponse(packets, origin: origin)
      case .unknownSession:
        return unknownSessionResponse(origin: origin)
      }
    }

    switch await engine.poll(sid: sid) {
    case .established(_, let packets):
      return payloadResponse(packets, origin: origin)
    case .unknownSession:
      return unknownSessionResponse(origin: origin)
    }
  }

  /// The ceiling on an inbound long-poll body.
  ///
  /// NOT `maxPayload`. That number (100 MB) is the ceiling on a websocket FRAME and on what
  /// the server may batch back to a client; it was being applied here, to the request body, on
  /// the wrong side of the connection. What a client actually POSTs to `/socket.io/` is a
  /// handful of Engine.IO control packets — a CONNECT with an `auth` object, a PONG, a
  /// disconnect — none of which is close to a kilobyte. 256 KB is generous by orders of
  /// magnitude and still bounded.
  ///
  /// The size mattered because of where it sat. `collect` buffered up to 100 MB and
  /// `String(buffer:)` then copied it, so one request cost ~200 MB, and both happened before
  /// anything had checked the caller — on a server whose stated idle budget is 60 MB and whose
  /// target hardware has 4 GB. The comment above it justified the cap as what stopped an
  /// unauthenticated caller buffering arbitrary memory, which is the same reasoning
  /// `HTTPServer.dispatch` retracts in place: a cap bounds ONE request, and nothing bounded
  /// how many arrived at once.
  public static let maximumInboundBody = 256 * 1024

  private func handlePost(_ request: Request) async -> Response {
    let query = Self.queryParameters(from: request.uri)
    let origin = request.headers[.origin]
    guard let sid = query["sid"] else { return unknownSessionResponse(origin: origin) }

    // The session is resolved BEFORE the body is read. It used to be resolved after, so an
    // unknown or expired sid — anything at all, from anyone — still bought a full-size buffer
    // first and was only then rejected by `engine.receive`.
    guard await engine.session(sid) != nil else { return unknownSessionResponse(origin: origin) }

    guard let buffer = try? await request.body.collect(upTo: Self.maximumInboundBody) else {
      return Response(status: .contentTooLarge, headers: corsHeaders(origin))
    }
    // Still through a `String`, and deliberately left that way. Splitting on the buffer's
    // bytes would save one copy, but `EngineIOPayload` is a pure codec with no NIO dependency
    // and adding one to save a copy of at most 256 KB is the wrong trade. The size is what
    // made this worth changing; the copy never was.
    let reply = await engine.receive(
      sid: sid, packets: EngineIOPayload.decode(String(buffer: buffer)))
    // Anything the client's packets produced is QUEUED rather than returned: the POST's
    // own response body is `ok` and nothing else, and a client reading a packet out of
    // it would be reading it off the wrong request.
    if !reply.packets.isEmpty, let session = await engine.session(sid) {
      for packet in reply.packets { await session.send(packet) }
    }
    if reply.shouldClose {
      await engine.close(sid: sid)
    }

    var headers = corsHeaders(origin)
    headers[.contentType] = "text/plain; charset=UTF-8"
    return Response(
      status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: "ok"))
    )
  }

  // MARK: - WebSocket

  /// The channel-level upgrade decision.
  ///
  /// Made at the channel rather than through the router's `ws()` helper so the API's own
  /// request context does not have to conform to `WebSocketRequestContext`: the HTTP
  /// layer should not gain a websocket dependency to serve a path it does not own.
  public func shouldUpgrade(
    request: HTTPRequest
  ) -> Bool {
    guard let path = URLComponents(string: request.path ?? "")?.path else { return false }
    return path == Self.path || path == "/socket.io"
  }

  /// Drives one upgraded connection.
  ///
  /// Both directions run concurrently and either one ending tears down the other: a
  /// websocket where the reader has exited but the writer has not is a session that looks
  /// alive, keeps being broadcast to, and delivers nothing.
  public func handleWebSocket(
    sid: String,
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter
  ) async {
    guard let pending = await engine.beginWebSocket(sid: sid) else {
      logger.debug(
        "WebSocket upgrade for an unknown session",
        metadata: [
          "sid": .string(sid)
        ])
      return
    }

    // Queued while the upgrade was in flight. Dropping these loses an event exactly once
    // per connection, which is close to unreproducible after the fact.
    for packet in pending {
      try? await outbound.write(.text(packet))
    }

    guard let session = await engine.session(sid) else { return }

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        // Server → client.
        while await !session.isClosed {
          let packets = await session.drain(waitingUpTo: .seconds(30))
          guard !packets.isEmpty else { continue }
          for packet in packets {
            do {
              try await outbound.write(.text(packet))
            } catch {
              await session.close(.normal)
              return
            }
          }
        }
      }

      group.addTask {
        // Client → server. One Engine.IO packet per frame; the record separator is
        // a polling-only batching device and never appears here.
        do {
          for try await frame in inbound.messages(maxSize: 100 * 1024 * 1024) {
            guard case .text(let text) = frame else { continue }
            let reply = await self.engine.receive(sid: sid, packets: [text])
            for packet in reply.packets {
              try await outbound.write(.text(packet))
            }
            if reply.shouldClose { break }
          }
        } catch {
          // A dropped connection is ordinary. It is not worth an alert and barely
          // worth a log line.
        }
        await session.close(.normal)
      }

      // The first task to finish ends the connection; the other is cancelled.
      await group.next()
      group.cancelAll()
    }

    await engine.close(sid: sid)
  }

  /// Opens a session for a client that connected straight to the websocket.
  ///
  /// EIO3 clients can be configured websocket-only and never poll at all, so a websocket
  /// request with no `sid` is a handshake rather than an error.
  /// - Parameter forwardedFor: the upgrade request's `X-Forwarded-For`, threaded through
  ///   for the same reason the polling handshake threads it: the access controller decides
  ///   which of the two addresses to believe, and it cannot decide from one of them. Without
  ///   it a websocket-only client behind a loopback tunnel resolved as `.unresolved` — the
  ///   peer IS a trusted proxy and no header was offered — so per-client blocking never
  ///   engaged for it and only the degraded global throttle applied. Safe in direction, and
  ///   a real weakening of the control for a real client shape: EIO3 clients can be
  ///   configured websocket-only and never poll at all.
  public func openForWebSocket(
    query: [String: String],
    clientAddress: String?,
    forwardedFor: String? = nil,
    outbound: WebSocketOutboundWriter
  ) async -> String? {
    switch await engine.open(
      query: query, clientAddress: clientAddress, forwardedFor: forwardedFor
    ) {
    case .established(let sid, let packets):
      for packet in packets {
        try? await outbound.write(.text(packet))
      }
      guard let session = await engine.session(sid) else { return nil }
      _ = await session.upgrade()
      return sid
    case .unknownSession:
      return nil
    }
  }

  // MARK: - Responses

  /// What this transport sends when nothing has configured it: wide open, which is what it
  /// has always sent and what the reference sends.
  public static var defaultCORSHeaders: HTTPFields {
    var headers = HTTPFields()
    headers[.accessControlAllowOrigin] = "*"
    headers[.accessControlAllowMethods] = "GET, POST, OPTIONS"
    return headers
  }

  /// The headers a browser may assert on a socket request, from the ones it asked for.
  ///
  /// The forwarding headers are refused, for the reason `CORSHeaderPolicy` gives; transcribed
  /// rather than imported so this target keeps its dependency list. `SocketCORSPolicyTests`
  /// asserts the two sets are the same, so a header added there cannot be forgotten here.
  static func allowedRequestHeaders(requested: String?) -> String {
    guard let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
      return ""
    }
    let forbidden: Set<String> = [
      "x-forwarded-for", "x-real-ip", "forwarded", "x-forwarded-host", "x-forwarded-proto",
    ]
    return
      requested
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !forbidden.contains($0.lowercased()) }
      .joined(separator: ", ")
  }

  /// Instance methods, not statics, because the CORS headers now depend on the request's
  /// `Origin` and so on this transport's configured policy.
  func payloadResponse(_ packets: [String], origin: String?) -> Response {
    var headers = corsHeaders(origin)
    headers[.contentType] = "text/plain; charset=UTF-8"
    return Response(
      status: .ok,
      headers: headers,
      body: .init(byteBuffer: ByteBuffer(string: EngineIOPayload.encode(packets)))
    )
  }

  /// Engine.IO code 1: "Session ID unknown". The client's correct response is to open a
  /// new session, which is why this is a 400 with a body rather than a 404: a 404 reads
  /// as "no such endpoint" and clients stop retrying.
  func unknownSessionResponse(origin: String?) -> Response {
    var headers = corsHeaders(origin)
    headers[.contentType] = "application/json"
    return Response(
      status: .badRequest,
      headers: headers,
      body: .init(
        byteBuffer: ByteBuffer(
          string: #"{"code":1,"message":"Session ID unknown"}"#
        ))
    )
  }

  /// Parses a raw request target, for the channel-level upgrade decision, which sees an
  /// `HTTPRequest` and its path string rather than a routed `Request`.
  ///
  /// Both of these go through `QueryStringDecoder`, the same one the HTTP API uses, and
  /// both decode EXACTLY ONCE. Reading `URLComponents.queryItems` or Hummingbird's
  /// `uri.queryParameters` and then decoding the result again is the double-decode bug the
  /// current server has: a password containing a literal `%` followed by two hex digits
  /// comes out corrupted, and the user has no way to see why their password stopped
  /// working.
  public static func queryParameters(fromPath path: String) -> [String: String] {
    guard let separator = path.firstIndex(of: "?") else { return [:] }
    return QueryStringDecoder.parse(String(path[path.index(after: separator)...]))
  }

  static func queryParameters(from uri: URI) -> [String: String] {
    QueryStringDecoder.parse(uri.query.map { String($0) } ?? "")
  }
}

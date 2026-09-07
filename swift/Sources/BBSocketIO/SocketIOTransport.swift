//  SocketIOTransport
//  The Hummingbird binding: `/socket.io/` over long-polling and websocket.
//
//  Deliberately the only file in this module that imports Hummingbird, matching how the HTTP
//  layer is split — the protocol, the session model and the state machine are all testable
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

  public init(
    engine: EngineIOServer,
    logger: Logger = Logger(label: "bluebubbles.socket.transport")
  ) {
    self.engine = engine
    self.logger = logger
  }

  /// The path both transports live on. Trailing slash included: that is what clients
  /// request, and Socket.IO's own default.
  public static let path = "/socket.io/"

  // MARK: - Polling

  /// Mounts the long-polling endpoints.
  ///
  /// Polling is not a fallback here. Every Socket.IO client OPENS on polling and upgrades
  /// afterwards, so this path is on the critical path for every single connection —
  /// including the ones that end up on a websocket a moment later.
  public func mount<Context: RequestContext>(on router: Router<Context>) {
    router.on(RouterPath(Self.path), method: .get) { request, _ in
      await self.handleGet(request)
    }
    router.on(RouterPath(Self.path), method: .post) { request, _ in
      await self.handlePost(request)
    }
    // Clients send a CORS preflight before the POST when they are running in a browser.
    router.on(RouterPath(Self.path), method: .options) { _, _ in
      Response(status: .noContent, headers: Self.corsHeaders)
    }
  }

  private func handleGet(_ request: Request) async -> Response {
    let query = Self.queryParameters(from: request.uri)

    // No sid means "open a session"; a sid means "give me what you have".
    guard let sid = query["sid"] else {
      let peer = request.headers[.init("X-Forwarded-For")!]
      switch await engine.open(query: query, clientAddress: peer) {
      case .established(_, let packets):
        return Self.payloadResponse(packets)
      case .unknownSession:
        return Self.unknownSessionResponse()
      }
    }

    switch await engine.poll(sid: sid) {
    case .established(_, let packets):
      return Self.payloadResponse(packets)
    case .unknownSession:
      return Self.unknownSessionResponse()
    }
  }

  private func handlePost(_ request: Request) async -> Response {
    let query = Self.queryParameters(from: request.uri)
    guard let sid = query["sid"] else { return Self.unknownSessionResponse() }

    // Capped at the handshake's own `maxPayload`. An uncapped collect here would let an
    // unauthenticated caller make the server buffer arbitrary memory on a path that runs
    // before anything checks who they are.
    guard let buffer = try? await request.body.collect(upTo: 100 * 1024 * 1024) else {
      return Response(status: .contentTooLarge, headers: Self.corsHeaders)
    }
    let body = String(buffer: buffer)

    let reply = await engine.receive(sid: sid, packets: EngineIOPayload.decode(body))
    // Anything the client's packets produced is QUEUED rather than returned: the POST's
    // own response body is `ok` and nothing else, and a client reading a packet out of
    // it would be reading it off the wrong request.
    if !reply.packets.isEmpty, let session = await engine.session(sid) {
      for packet in reply.packets { await session.send(packet) }
    }
    if reply.shouldClose {
      await engine.close(sid: sid)
    }

    var headers = Self.corsHeaders
    headers[.contentType] = "text/plain; charset=UTF-8"
    return Response(
      status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: "ok"))
    )
  }

  // MARK: - WebSocket

  /// The channel-level upgrade decision.
  ///
  /// Made at the channel rather than through the router's `ws()` helper so the API's own
  /// request context does not have to conform to `WebSocketRequestContext` — the HTTP
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
  public func openForWebSocket(
    query: [String: String],
    clientAddress: String?,
    outbound: WebSocketOutboundWriter
  ) async -> String? {
    switch await engine.open(query: query, clientAddress: clientAddress) {
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

  /// Wide open, matching the REST API and the current Socket.IO configuration.
  static var corsHeaders: HTTPFields {
    var headers = HTTPFields()
    headers[.accessControlAllowOrigin] = "*"
    headers[.accessControlAllowMethods] = "GET, POST, OPTIONS"
    headers[.accessControlAllowHeaders] = "*"
    return headers
  }

  static func payloadResponse(_ packets: [String]) -> Response {
    var headers = corsHeaders
    headers[.contentType] = "text/plain; charset=UTF-8"
    return Response(
      status: .ok,
      headers: headers,
      body: .init(byteBuffer: ByteBuffer(string: EngineIOPayload.encode(packets)))
    )
  }

  /// Engine.IO code 1: "Session ID unknown". The client's correct response is to open a
  /// new session, which is why this is a 400 with a body rather than a 404 — a 404 reads
  /// as "no such endpoint" and clients stop retrying.
  static func unknownSessionResponse() -> Response {
    var headers = corsHeaders
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

  /// Parses a raw request target, for the channel-level upgrade decision — which sees an
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

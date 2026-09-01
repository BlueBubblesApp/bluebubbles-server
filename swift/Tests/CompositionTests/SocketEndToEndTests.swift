//  SocketEndToEndTests
//  A real client, a real port, over both transports.
//
//  Everything in SocketTransportTests drives the state machine directly. This drives it the
//  way a Socket.IO client does — an HTTP GET with no sid, then a POST carrying `40`, then a
//  GET that blocks until an event arrives — because the gap this closes was never in the
//  protocol logic. It was that nothing served the protocol at all: `/socket.io/` 404'd, and
//  every unit test in the module passed.

import BBAuth
import BBCore
import BBEvents
import BBSerialization
import BBSettings
import BBSocketIO
import Foundation
import Hummingbird
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Socket transport over the wire", .serialized)
struct SocketEndToEndTests {

  private static let password = "hunter2hunter2"

  private func withServer(
    password: String = SocketEndToEndTests.password,
    _ body: (Int, SocketServer, EngineIOServer) async throws -> Void
  ) async throws {
    // Port 0: the kernel picks a free port and never picks one it has already given
    // out. See `EphemeralPort`.
    let sockets = SocketServer()
    let engine = EngineIOServer(
      server: sockets,
      chain: {
        AuthenticationChain(schemes: [
          PasswordQueryScheme(
            passwordProvider: { PasswordDigest(password) }
          )
        ])
      }
    )

    var registry = HandlerRegistry()
    // A real handler for the one route the HTTP half of these tests calls, so a 200
    // means "authenticated and served" rather than "reached the 501 placeholder".
    registry.register("general.ping") { _ in .data(.string("pong")) }
    PlaceholderHandlers.fill(into: &registry, groups: RouteTable.groups)

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(host: "127.0.0.1", port: 0),
      authentication: AuthenticationStage(
        chain: AuthenticationChain(schemes: [
          PasswordQueryScheme(
            passwordProvider: { PasswordDigest(password) }
          )
        ]),
        accessControl: AccessControlService()
      ),
      privateAPI: PrivateAPIStage(isConnected: { true })
    )
    let router = try builder.buildRouter(registry: registry)

    let transport = SocketIOTransport(engine: engine)
    transport.mount(on: router)

    let listener = HTTPListener()
    try await listener.start(
      router: router, host: "127.0.0.1", port: 0, socket: transport
    )
    defer { Task { await listener.stop() } }
    let port = try await listener.boundPortOrFail()

    try await body(port, sockets, engine)
  }

  private static func get(port: Int, query: String) async throws -> (String, Int) {
    let url = URL(string: "http://127.0.0.1:\(port)/socket.io/?\(query)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    return (
      String(decoding: data, as: UTF8.self),
      (response as? HTTPURLResponse)?.statusCode ?? 0
    )
  }

  private static func post(port: Int, query: String, body: String) async throws -> String {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(port)/socket.io/?\(query)")!
    )
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    let (data, _) = try await URLSession.shared.data(for: request)
    return String(decoding: data, as: UTF8.self)
  }

  /// The sid out of an OPEN packet, the way a client reads it.
  private static func sessionID(from open: String) throws -> String {
    let json = try JSONValue.parse(Data(open.dropFirst().utf8))
    return try #require(json["sid"]?.stringValue)
  }

  @Test("A client completes a handshake over polling")
  func handshakeOverPolling() async throws {
    try await withServer { port, _, _ in
      let (body, status) = try await Self.get(
        port: port, query: "EIO=4&transport=polling&password=\(Self.password)"
      )
      #expect(status == 200)
      #expect(body.hasPrefix("0{"))
      let sid = try Self.sessionID(from: body)
      #expect(!sid.isEmpty)
    }
  }

  @Test("A full connect-and-receive cycle works over polling")
  func eventReachesAPollingClient() async throws {
    // The whole point of the module, asserted once end to end: an event emitted on the
    // server comes back out of a client's HTTP poll.
    try await withServer { port, sockets, _ in
      let (open, _) = try await Self.get(
        port: port, query: "EIO=4&transport=polling&password=\(Self.password)"
      )
      let sid = try Self.sessionID(from: open)
      let query = "EIO=4&transport=polling&sid=\(sid)"

      let ack = try await Self.post(port: port, query: query, body: "40")
      #expect(ack == "ok")

      // The CONNECT reply is QUEUED by the POST and collected by the next GET — the
      // POST's own body is `ok` and nothing else. A client reads it here.
      let (connect, _) = try await Self.get(port: port, query: query)
      #expect(connect.hasPrefix("40{\"sid\""))

      // Parked before the event exists, exactly as a client's poll would be.
      async let polled = Self.get(port: port, query: query)
      try await Task.sleep(for: .milliseconds(100))

      await sockets.broadcast(
        ServerEvent(
          name: .newMessage,
          fullPayload: .object(["guid": .string("MSG-E2E")]),
          notificationPayload: .null
        )
      )

      let (body, status) = try await polled
      #expect(status == 200)
      #expect(body.contains("new-message"))
      #expect(body.contains("MSG-E2E"))
      // Raw object, not envelope-wrapped.
      #expect(!body.contains("\"status\":200"))
    }
  }

  @Test("A wrong password is closed without an error packet")
  func wrongPasswordIsClosedSilently() async throws {
    try await withServer { port, sockets, _ in
      let (body, status) = try await Self.get(
        port: port, query: "EIO=4&transport=polling&password=wrong"
      )
      // A successful-looking handshake followed by a bare CLOSE, which is what
      // `socket.disconnect()` produces. Clients stop on this and retry a
      // CONNECT_ERROR, so the difference decides whether a wrong password is a
      // reconnect loop.
      #expect(status == 200)
      #expect(body.hasSuffix("\u{1e}1"))
      #expect(await sockets.connectionCount == 0)
    }
  }

  @Test("An unknown session is refused with Engine.IO code 1")
  func unknownSessionIsRefused() async throws {
    try await withServer { port, _, _ in
      let (body, status) = try await Self.get(
        port: port, query: "EIO=4&transport=polling&sid=nonexistent"
      )
      #expect(status == 400)
      #expect(body.contains("\"code\":1"))
    }
  }

  @Test("Several clients connect at once and all receive the same event")
  func concurrentClientsAllReceive() async throws {
    // The install this ships into serves a phone and two desktops simultaneously. One
    // client's session must not disturb another's, and a broadcast goes to every one.
    try await withServer { port, sockets, _ in
      var sids: [String] = []
      for _ in 0..<3 {
        let (open, _) = try await Self.get(
          port: port, query: "EIO=4&transport=polling&password=\(Self.password)"
        )
        let sid = try Self.sessionID(from: open)
        _ = try await Self.post(
          port: port, query: "EIO=4&transport=polling&sid=\(sid)", body: "40"
        )
        sids.append(sid)
      }
      #expect(Set(sids).count == 3, "sessions must be distinct")
      #expect(await sockets.connectionCount == 3)

      await sockets.broadcast(
        ServerEvent(
          name: .newMessage,
          fullPayload: .object(["guid": .string("FANOUT")]),
          notificationPayload: .null
        )
      )

      for sid in sids {
        let (body, _) = try await Self.get(
          port: port, query: "EIO=4&transport=polling&sid=\(sid)"
        )
        #expect(body.contains("FANOUT"), "client \(sid) missed the broadcast")
      }
    }
  }

  @Test("The REST API still answers on the same port")
  func restAndSocketShareThePort() async throws {
    // One port, both surfaces, as today. Mounting the socket must not shadow `/api/v1`,
    // and installing the websocket upgrade channel must not change ordinary responses.
    try await withServer { port, _, _ in
      let url = URL(string: "http://127.0.0.1:\(port)/api/v1/ping")!
      let (_, response) = try await URLSession.shared.data(from: url)
      let status = (response as? HTTPURLResponse)?.statusCode
      // 401 because this harness installs no auth scheme — the point is that it is
      // routed and answered, not 404.
      #expect(status == 401)
    }
  }

  /// The end-to-end version of ComplexPasswordTests: over a real socket, through the real
  /// query parser, on both surfaces at once.
  @Test("An awkward password authenticates over HTTP and the socket alike")
  func awkwardPasswordsWorkOnBothSurfaces() async throws {
    // `%20` and `+` are the two that have historically been mangled, and `&` is the one
    // that breaks query parsing outright if the client does not encode it.
    for password in ["p@ss word+1!", "a%20b", "you&me", "100%sure", "🔒emoji"] {
      let encoded =
        password.addingPercentEncoding(
          withAllowedCharacters: CharacterSet(
            charactersIn:
              "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
          )
        ) ?? password

      try await withServer(password: password) { port, _, _ in
        // The socket handshake must not be followed by a CLOSE.
        let (body, _) = try await Self.get(
          port: port, query: "EIO=4&transport=polling&password=\(encoded)"
        )
        #expect(
          !body.hasSuffix("\u{1e}1"),
          "the socket rejected \(password.debugDescription)"
        )

        // And the same value over HTTP.
        let url = URL(string: "http://127.0.0.1:\(port)/api/v1/ping?password=\(encoded)")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect(
          (response as? HTTPURLResponse)?.statusCode == 200,
          "HTTP rejected \(password.debugDescription)"
        )
      }
    }
  }

  @Test("A password can be supplied in the CONNECT auth payload instead of the URL")
  func connectAuthOverTheWire() async throws {
    // The recommended path for anything awkward: the password crosses as JSON in a
    // packet body and never touches a URL at all.
    let password = "p@ss word+1!%20&x=y"
    try await withServer(password: password) { port, sockets, _ in
      let (open, _) = try await Self.get(port: port, query: "EIO=4&transport=polling")
      let sid = try Self.sessionID(from: open)
      let query = "EIO=4&transport=polling&sid=\(sid)"

      // No credential in the handshake, so the session is deferred rather than closed.
      #expect(!open.hasSuffix("\u{1e}1"))

      let auth = #"40{"password":"p@ss word+1!%20&x=y"}"#
      _ = try await Self.post(port: port, query: query, body: auth)

      let (connect, _) = try await Self.get(port: port, query: query)
      #expect(connect.hasPrefix("40{\"sid\""), "auth payload was refused: \(connect)")
      #expect(await sockets.connectionCount == 1)
    }
  }

  @Test("A websocket client is upgraded and receives events")
  func eventReachesAWebSocketClient() async throws {
    // EIO3 clients can be configured websocket-only and never poll, so a websocket
    // request with no sid has to be a handshake rather than an error.
    try await withServer { port, sockets, engine in
      let client = try await RawWebSocket.connect(
        port: port,
        path: "/socket.io/?EIO=4&transport=websocket&password=\(Self.password)"
      )
      defer { client.close() }

      let open = try await client.receive()
      #expect(open.hasPrefix("0{"))

      try await client.send("40")
      let connect = try await client.receive()
      #expect(connect.hasPrefix("40{"))
      #expect(await sockets.connectionCount == 1)

      await sockets.broadcast(
        ServerEvent(
          name: .newMessage,
          fullPayload: .object(["guid": .string("WS-1")]),
          notificationPayload: .null
        )
      )

      let event = try await client.receive()
      #expect(event.hasPrefix("42"))
      #expect(event.contains("WS-1"))
      _ = engine
    }
  }
}

/// A minimal websocket client.
///
/// `URLSessionWebSocketTask` rather than a dependency: the test needs to speak RFC 6455 to
/// our own server, and pulling in a client library to prove the server works would test the
/// two against each other rather than against the protocol.
private final class RawWebSocket: @unchecked Sendable {

  private let task: URLSessionWebSocketTask

  private init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  static func connect(port: Int, path: String) async throws -> RawWebSocket {
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)\(path)"))
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    return RawWebSocket(task: task)
  }

  func send(_ text: String) async throws {
    try await task.send(.string(text))
  }

  func receive() async throws -> String {
    switch try await task.receive() {
    case .string(let text): text
    case .data(let data): String(decoding: data, as: UTF8.self)
    @unknown default: ""
    }
  }

  func close() {
    task.cancel(with: .normalClosure, reason: nil)
  }
}

//  SocketServer
//  Connection state, broadcast, and the opt-in replay ring.
//
//  The socket carries server->client events only; every client request goes over the HTTP
//  API. That asymmetry is what makes a native implementation tractable — the outbound half is
//  a handful of packet shapes, and the inbound half does not exist.
//
//  There is NO inbound command dispatch anywhere, and that is a decision rather than an
//  omission: the legacy socket API let clients request and post data over the socket, roughly
//  thirty commands duplicating the REST surface, and re-adding it would mean a second
//  implementation of every endpoint with its own auth and validation. Every shipping client
//  drives the server over `/api/v1`. See `EngineIOServer.handle(packet:)`, which drops
//  inbound event frames deliberately and says so.
//
//  Two behaviors here look wrong and are correct:
//    - A failed handshake DISCONNECTS SILENTLY. No error event, no CONNECT_ERROR packet.
//      Clients treat a connect error as retryable and a silent close as "wrong password",
//      so being helpful here changes reconnect behavior.
//    - Broadcast payloads are the RAW object, never envelope-wrapped, and carry no sequence
//      number unless the client asked for one. Adding `seq` to every frame would alter every
//      event body, which the compatibility contract forbids as a default.
//
//  See `docs/EVENTS.md`.

import BBAuth
import BBCore
import BBEvents
import BBSerialization
import Foundation
import Logging

public struct SocketID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What a client asked for at handshake time.
public struct SocketClientOptions: Sendable {
  /// Engine.IO 3 or 4. `allowEIO3` is load-bearing for older Flutter clients, so 3 is a
  /// supported version rather than a deprecation.
  public let engineIOVersion: Int
  /// Opt-in via `replay=1`. Without it the client receives no `seq` field at all and its
  /// frames stay byte-identical to today's.
  public let wantsReplay: Bool
  /// From `codecs=`, defaulting to legacy-v1.
  public let capabilities: TargetCapabilities
  public let transport: EngineIOTransport

  public init(
    engineIOVersion: Int = 4,
    wantsReplay: Bool = false,
    capabilities: TargetCapabilities = .legacy,
    transport: EngineIOTransport = .polling
  ) {
    self.engineIOVersion = engineIOVersion
    self.wantsReplay = wantsReplay
    self.capabilities = capabilities
    self.transport = transport
  }

  /// Parses the handshake query.
  public static func parse(_ query: [String: String]) -> SocketClientOptions {
    let version = query["EIO"].flatMap(Int.init) ?? 4
    let replay = ["1", "true"].contains(query["replay"]?.lowercased() ?? "")
    let transport =
      query["transport"] == "websocket"
      ? EngineIOTransport.webSocket : EngineIOTransport.polling

    var codecs: Set<CodecIdentifier> = [.legacyV1]
    if let declared = query["codecs"] {
      for name in declared.split(separator: ",") {
        codecs.insert(CodecIdentifier(String(name).trimmingCharacters(in: .whitespaces)))
      }
    }

    return SocketClientOptions(
      engineIOVersion: version,
      wantsReplay: replay,
      capabilities: TargetCapabilities(supportedCodecs: codecs),
      transport: transport
    )
  }
}

/// Which Engine.IO transport a client is connected over.
///
/// Named for Engine.IO rather than "socket" for two reasons: this module already has a
/// `SocketIOTransport`, which is the Hummingbird mount and a completely different thing,
/// and `BBPrivateAPI.SocketTransport` — the UNIX-domain listener the helper connects to —
/// is imported alongside this one by the composition layer.
///
/// The raw values are wire-facing: they are what the `transport=` query parameter carries.
public enum EngineIOTransport: String, Sendable {
  case polling
  case webSocket = "websocket"
}

/// One connected client.
public protocol SocketConnection: AnyObject, Sendable {
  var id: SocketID { get }
  var options: SocketClientOptions { get }
  func send(_ frame: String) async
  func close() async
}

// MARK: - The server

public actor SocketServer {

  private var connections: [SocketID: any SocketConnection] = [:]
  private let negotiator: CodecNegotiator
  private let logger: Logger

  /// Monotonic across the process lifetime. Only ever revealed to clients that asked.
  private var sequence: Int64 = 0
  private var replayRing: [(sequence: Int64, name: String, payload: JSONValue)] = []
  private let replayCapacity: Int

  public init(
    negotiator: CodecNegotiator = .legacyOnly(),
    replayCapacity: Int = 500,
    logger: Logger = Logger(label: "bluebubbles.socket")
  ) {
    self.negotiator = negotiator
    self.replayCapacity = replayCapacity
    self.logger = logger
  }

  // MARK: Connection lifecycle

  /// Authenticates a handshake.
  ///
  /// Returns nil on failure, and the caller CLOSES WITHOUT SENDING ANYTHING. Emitting a
  /// CONNECT_ERROR would be more informative and would change how clients treat a bad
  /// password — they retry a connect error and stop on a silent close.
  public func authenticate(
    query: [String: String],
    using chain: AuthenticationChain
  ) async -> AuthenticatedPrincipal? {
    // Normalized to the socket's own rules before the chain sees it: `password`/`guid`
    // only — never `token` — and percent-decoded. Both differences from HTTP are real
    // and shipped, so they are reproduced rather than harmonised. Handing the raw query
    // straight to the chain accepted a `token` the socket has never accepted, and failed
    // any password a client had to encode.
    let presentation = CredentialPresentation(
      queryParameters: SocketHandshakeScheme.normalize(query: query),
      path: "/socket.io/"
    )
    guard case .authenticated(let principal) = await chain.authenticate(presentation) else {
      return nil
    }
    return principal
  }

  public func register(_ connection: any SocketConnection) {
    connections[connection.id] = connection
    logger.debug(
      "Socket connected",
      metadata: [
        "id": .string(connection.id.rawValue),
        "transport": .string(connection.options.transport.rawValue),
        "eio": .stringConvertible(connection.options.engineIOVersion),
      ])
  }

  public func unregister(_ id: SocketID) {
    connections.removeValue(forKey: id)
  }

  public var connectionCount: Int { connections.count }

  /// Disconnects everyone. Used when the password changes, so a client holding the old one
  /// is forced to re-authenticate rather than continuing on an already-open socket.
  public func disconnectAll() async {
    let all = Array(connections.values)
    connections.removeAll()
    for connection in all {
      await connection.close()
    }
  }

  // MARK: Broadcast

  public func broadcast(_ event: ServerEvent) async {
    sequence += 1
    let current = sequence

    // Maintained regardless of whether anyone is using it: a client that reconnects with
    // `?since=` needs the events it missed while it was gone, which by definition
    // predate its asking.
    replayRing.append((current, event.name.rawValue, event.fullPayload))
    if replayRing.count > replayCapacity {
      replayRing.removeFirst(replayRing.count - replayCapacity)
    }

    for connection in connections.values {
      await send(event: event, sequence: current, to: connection)
    }
  }

  private func send(event: ServerEvent, sequence: Int64, to connection: any SocketConnection) async
  {
    do {
      let codec = negotiator.resolve(for: connection.options.capabilities)
      let encoded = try await codec.encode(
        event, projection: .full, capabilities: connection.options.capabilities
      )

      // The ONLY place a frame diverges from today's output, and only for a client
      // that asked. Everyone else gets the payload unmodified.
      var payload = encoded.body
      if connection.options.wantsReplay, case .object(var object) = payload {
        object["seq"] = .int64(sequence)
        payload = .object(object)
      }

      let packet = SocketIOPacket.event(name: event.name.rawValue, payload: payload)
      await connection.send(try WireFrame.encode(packet))

    } catch {
      logger.warning(
        "Failed to encode a socket frame",
        metadata: [
          "event": .string(event.name.rawValue),
          "error": .string(String(describing: error)),
        ])
    }
  }

  // MARK: Replay

  public enum ReplayOutcome: Sendable {
    case events([(sequence: Int64, name: String, payload: JSONValue)])
    /// The requested sequence is older than the ring, so the client must do a full
    /// fetch. Better than silently sending a partial history it would treat as complete.
    case resyncRequired
  }

  public func replay(since: Int64) -> ReplayOutcome {
    guard let oldest = replayRing.first else { return .events([]) }
    // `since` equal to the oldest is fine — the client has that one and wants what came
    // after. Older than it means the gap is unrecoverable.
    guard since >= oldest.sequence - 1 else { return .resyncRequired }
    return .events(replayRing.filter { $0.sequence > since })
  }

  public var currentSequence: Int64 { sequence }
}

// MARK: - The bus sink

/// Bridges the event bus to the socket server.
///
/// A separate type rather than making SocketServer itself an EventSink, so the server can be
/// driven directly — by tests, and by anything that needs to write to a connection without
/// going through the bus — without dragging in the sink protocol.
public struct SocketSink: EventSink {

  public let id = SinkID.socket
  public let routing = SinkRouting.socket
  /// The socket gets the FULL payload. FCM and webhooks get the trimmed one. Mixing these
  /// up is the single most likely way to break clients while every test still passes.
  public let projection = PayloadProjection.full

  private let server: SocketServer

  public init(server: SocketServer) {
    self.server = server
  }

  public func accepts(_ event: ServerEvent) async -> Bool {
    // Always. Suppression is EventRouting's job, applied by the bus before it gets here.
    true
  }

  public func deliver(_ event: ServerEvent) async throws {
    await server.broadcast(event)
  }
}

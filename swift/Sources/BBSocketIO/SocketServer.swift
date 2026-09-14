//  SocketServer
//  Connection state, broadcast, and the opt-in replay ring.
//
//  The socket carries server->client events only; every client request goes over the HTTP
//  API. That asymmetry is what makes a native implementation tractable: the outbound half is
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
/// and `BBPrivateAPI.SocketTransport` (the UNIX-domain listener the helper connects to)
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
  private var replayRing: [(sequence: Int64, name: String, payload: JSONValue, bytes: Int)] = []
  private let replayCapacity: Int
  /// Bytes currently held by `replayRing`, so the bound does not cost a walk per append.
  private var replayBytes = 0

  /// How much the replay ring may hold, whatever the event count.
  ///
  /// Bounded by COUNT alone it was measured at 2.69MB for 500 events -- 5,636 bytes each,
  /// four times their wire size, because it keeps the full projection. A count is the wrong
  /// unit for a bound whose purpose is memory: one message with twenty attachments is not
  /// the same as one typing indicator, and the ring has no say in which it gets.
  static let replayByteBudget = 512 * 1024

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
  /// password; they retry a connect error and stop on a silent close.
  public func authenticate(
    query: [String: String],
    using chain: AuthenticationChain
  ) async -> AuthenticatedPrincipal? {
    // Normalized to the socket's own rules before the chain sees it: `password`/`guid`
    // only, never `token`, and percent-decoded. Both differences from HTTP are real
    // and shipped, so they are reproduced rather than harmonised. Handing the raw query
    // straight to the chain would accept a `token` the socket has never accepted, and fail
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
    guard connections.removeValue(forKey: id) != nil else { return }
    logger.debug(
      "Socket disconnected",
      metadata: [
        "id": .string(id.rawValue),
        "connections": .stringConvertible(connections.count),
      ])
  }

  public var connectionCount: Int { connections.count }

  /// Disconnects everyone.
  ///
  /// **Nothing calls this, and the comment that used to sit here named a mechanism that is
  /// not the one in use.** It said "used when the password changes", and a password change
  /// goes through `SocketService.apply` returning `.restart`, which stops the service and
  /// calls `engineIO.closeAll()` — a different object closing different state. So the
  /// behaviour the comment described was real and was somebody else's.
  ///
  /// Kept rather than deleted because it is the only way to close the SocketServer's own
  /// connection table without a restart, which a future in-place credential rotation would
  /// want. If that never arrives, delete it; what must not happen again is it sitting here
  /// describing work another file does.
  public func disconnectAll() async {
    let all = Array(connections.values)
    connections.removeAll()
    logger.info(
      "Disconnecting every socket client",
      metadata: ["connections": .stringConvertible(all.count)])
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
    // Sized once, here, rather than walked on every append: this is the only place an
    // entry is added, and the encoder it uses is the same one the frames go through.
    let bytes = (try? event.fullPayload.serialize().count) ?? 0
    replayRing.append((current, event.name.rawValue, event.fullPayload, bytes))
    replayBytes += bytes
    while replayRing.count > replayCapacity || replayBytes > Self.replayByteBudget {
      guard let oldest = replayRing.first else { break }
      replayBytes -= oldest.bytes
      replayRing.removeFirst()
    }

    // Logged with zero connections too: "no phone was connected" is the usual answer to
    // "why did my phone not get it", and the line that says so has to exist.
    logger.debug(
      "Broadcasting to sockets",
      metadata: [
        "event": .string(event.name.rawValue),
        "seq": .stringConvertible(current),
        "connections": .stringConvertible(connections.count),
      ])
    // Encoded once per distinct FRAME SHAPE, not once per connection. Three phones on one
    // event used to mean three identical projections and three identical JSON encodings.
    //
    // Only the plaintext codecs are shared. A sealed frame is encrypted TO ONE CLIENT'S KEY
    // with a fresh ephemeral keypair per call, so reusing one across connections would be
    // both a different frame than the client expects and a change to a crypto path for a
    // saving measured in microseconds. `sealedV2` therefore always re-encodes.
    var plaintextFrames: [String: String] = [:]
    for connection in connections.values {
      await send(
        event: event, sequence: current, to: connection, sharedFrames: &plaintextFrames)
    }
  }

  /// - Parameter sharedFrames: frames already encoded for THIS broadcast, keyed by the only
  ///   two things a plaintext frame varies on: which codec was resolved, and whether the
  ///   client asked for a replay sequence to be added.
  private func send(
    event: ServerEvent, sequence: Int64, to connection: any SocketConnection,
    sharedFrames: inout [String: String]
  ) async {
    do {
      let codec = negotiator.resolve(for: connection.options.capabilities)
      let isShareable = codec.identifier != .sealedV2
      let key = "\(codec.identifier.rawValue)|\(connection.options.wantsReplay)"
      if isShareable, let cached = sharedFrames[key] {
        await connection.send(cached)
        return
      }
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
      let frame = try WireFrame.encode(packet)
      if isShareable { sharedFrames[key] = frame }
      await connection.send(frame)

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
    // `since` equal to the oldest is fine: the client has that one and wants what came
    // after. Older than it means the gap is unrecoverable.
    guard since >= oldest.sequence - 1 else {
      logger.debug(
        "Socket replay gap is older than the ring; the client must resync",
        metadata: [
          "since": .stringConvertible(since),
          "oldest": .stringConvertible(oldest.sequence),
        ])
      return .resyncRequired
    }
    return .events(
      replayRing.filter { $0.sequence > since }
        .map { (sequence: $0.sequence, name: $0.name, payload: $0.payload) })
  }

  public var currentSequence: Int64 { sequence }
}

// MARK: - The bus sink

/// Bridges the event bus to the socket server.
///
/// A separate type rather than making SocketServer itself an EventSink, so the server can be
/// driven directly (by tests, and by anything that needs to write to a connection without
/// going through the bus) without dragging in the sink protocol.
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

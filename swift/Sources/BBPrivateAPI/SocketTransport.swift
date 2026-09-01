//  SocketTransport
//  The Swift helper's transport: a Unix-domain socket with peer identity verification.
//
//  Why not the legacy TCP listener
//  ------------------------------
//  That listener binds a TCP port derived from the uid and accepts anything that connects to
//  it. Any local process — any sandboxed app, any script — can connect and drive the Private
//  API, which means sending messages as the user. It also has to do uid-to-port arithmetic to
//  avoid collisions between accounts, and it can provoke a firewall prompt.
//
//  A Unix-domain socket in a `0700` directory fixes reachability by filesystem permission:
//  only this user can open it. That is necessary but not sufficient, because "this user" also
//  covers every app the user runs. So the peer is additionally identified:
//
//    1. `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` gives the connecting process id — from the
//       kernel, not from anything the peer told us.
//    2. `SecCodeCopyGuestWithAttributes` turns that pid into a code object.
//    3. `SecCodeCheckValidity` checks it against a designated requirement.
//
//  Step 1 matters: a pid the peer *claims* is worthless, and a pid can be reused after exit.
//  Reading it from the socket the kernel gave us avoids both.
//
//  Framing is a 4-byte big-endian length prefix rather than newlines. Both sides are ours, so
//  there is no reason to keep a delimiter the payload has to avoid — and no reason to keep
//  the legacy inter-write pacing either.
//
//  See `.claude/docs/private-api.md`.

import BBCore
import BBPrivateAPIContract
import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix
import Security

public enum PeerValidationError: BBError, Equatable {
  case peerIdentityUnavailable
  case codeObjectUnavailable(pid: pid_t, status: OSStatus)
  case requirementNotMet(pid: pid_t, status: OSStatus)
  case invalidRequirement(String)
}

/// A connecting process's identity, as the kernel recorded it at connect time.
///
/// Carries the full `audit_token_t` rather than just a pid, and that distinction is the point
/// — see `CodeSignaturePeerValidator.validate`.
public struct PeerIdentity: Sendable {
  public let auditToken: audit_token_t
  public init(auditToken: audit_token_t) { self.auditToken = auditToken }

  /// Word 5 of the token. Useful for logging; NOT what identity is checked against.
  public var pid: pid_t {
    withUnsafeBytes(of: auditToken) {
      pid_t(bitPattern: $0.load(fromByteOffset: 20, as: UInt32.self))
    }
  }
}

/// Decides whether a connecting process may drive the Private API.
public protocol PeerValidating: Sendable {
  func validate(_ peer: PeerIdentity) throws
}

/// Checks the peer against a code-signing designated requirement.
public struct CodeSignaturePeerValidator: PeerValidating {

  /// The requirement the peer must satisfy.
  ///
  /// In development the helper is ad-hoc signed and cannot satisfy a team-identifier
  /// requirement, so the shipping default is supplied by the caller rather than hardcoded
  /// here — a wrong default would either lock out real users or accept anyone.
  public let requirement: String
  private let logger: Logger

  public init(requirement: String, logger: Logger = Logger(label: "bluebubbles.privateapi.peer")) {
    self.requirement = requirement
    self.logger = logger
  }

  /// Matches the apps a helper is injected into: Messages OR FaceTime, both Apple-anchored.
  ///
  /// The injected helper inherits the host app's signature, so a peer connecting from the
  /// FaceTime helper presents FaceTime.app's signature and one from the Messages helper
  /// presents Messages'. Accepting both — and NOTHING else — is what lets the two helpers
  /// share one socket while still rejecting any other local process. Apple-anchored is the
  /// load-bearing half: a random app named `com.apple.FaceTime` cannot forge Apple's anchor.
  public static func messagesApp(
    logger: Logger = Logger(label: "bluebubbles.privateapi.peer")
  ) -> CodeSignaturePeerValidator {
    CodeSignaturePeerValidator(
      requirement: "anchor apple and "
        + "(identifier \"com.apple.MobileSMS\" or identifier \"com.apple.FaceTime\")",
      logger: logger
    )
  }

  /// Checks the peer by AUDIT TOKEN, never by pid.
  ///
  /// A pid is not a stable identity. Between reading one and asking the Security framework
  /// about it, the process can exit and the kernel can reuse the number for a different
  /// one — so a check that passes may describe a process that no longer exists, and the
  /// connection now belongs to whatever took its place. That is a real
  /// time-of-check/time-of-use race, and it is the standard way peer validation is got
  /// wrong.
  ///
  /// An `audit_token_t` carries the pid *generation* alongside the pid, so a recycled
  /// number does not match. `kSecGuestAttributeAudit` takes the whole token, which is why
  /// the socket reads `LOCAL_PEERTOKEN` rather than `LOCAL_PEERPID`.
  public func validate(_ peer: PeerIdentity) throws {
    var requirementRef: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
      requirement as CFString, [], &requirementRef
    )
    guard requirementStatus == errSecSuccess, let requirementRef else {
      throw PeerValidationError.invalidRequirement(requirement)
    }

    var code: SecCode?
    let token = withUnsafeBytes(of: peer.auditToken) { Data($0) } as CFData
    let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
    let codeStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard codeStatus == errSecSuccess, let code else {
      throw PeerValidationError.codeObjectUnavailable(pid: peer.pid, status: codeStatus)
    }

    let validity = SecCodeCheckValidity(code, [], requirementRef)
    guard validity == errSecSuccess else {
      logger.warning(
        "Rejected a peer that failed code-signature validation",
        metadata: [
          "pid": .stringConvertible(peer.pid),
          "status": .stringConvertible(validity),
        ])
      throw PeerValidationError.requirementNotMet(pid: peer.pid, status: validity)
    }
  }
}

/// Accepts any local peer. For development only.
public struct PermissivePeerValidator: PeerValidating {
  public init() {}
  public func validate(_ peer: PeerIdentity) throws {}
}

// MARK: - Transport

public actor SocketTransport: PrivateAPITransport {

  private let socketPaths: [String]
  private let logger: Logger
  private let group: any EventLoopGroup
  private let ownsGroup: Bool
  private let validator: any PeerValidating

  private var serverChannels: [any Channel] = []
  private var clients: [ObjectIdentifier: any Channel] = [:]
  /// Registration order, oldest first. An action goes to the NEWEST live connection —
  /// see `write`, where broadcasting to all of them was double-sending every message.
  private var connectionOrder: [ObjectIdentifier] = []
  private var registeredProcesses: [String: ObjectIdentifier] = [:]

  private let transactions: TransactionStore
  private let eventStream: AsyncStream<PrivateAPIEvent>
  private let eventContinuation: AsyncStream<PrivateAPIEvent>.Continuation

  /// The default location: inside a `0700` directory under Application Support.
  /// Delegates to the shared derivation, which both the server and the injected helper
  /// use. They must agree exactly, and when this was computed independently on each side
  /// they did not — see SocketLocation.
  public static func defaultSocketPath() -> String {
    SocketLocation.privateAPISocket
  }

  /// Every path the server binds — one per app it injects into. See `SocketLocation`: a
  /// sandboxed app can only reach a socket inside its OWN container, so two helpers need
  /// two sockets.
  public static func defaultSocketPaths() -> [String] {
    SocketLocation.privateAPISockets
  }

  public init(
    socketPath: String? = nil,
    validator: any PeerValidating,
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.socket")
  ) {
    self.init(
      socketPaths: socketPath.map { [$0] } ?? Self.defaultSocketPaths(),
      validator: validator, group: group, logger: logger
    )
  }

  public init(
    socketPaths: [String],
    validator: any PeerValidating,
    group: (any EventLoopGroup)? = nil,
    logger: Logger = Logger(label: "bluebubbles.privateapi.socket")
  ) {
    self.socketPaths = socketPaths.isEmpty ? Self.defaultSocketPaths() : socketPaths
    self.validator = validator
    self.logger = logger
    if let group {
      self.group = group
      self.ownsGroup = false
    } else {
      self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      self.ownsGroup = true
    }
    self.transactions = TransactionStore(logger: logger)

    var continuation: AsyncStream<PrivateAPIEvent>.Continuation!
    self.eventStream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.eventContinuation = continuation
  }

  public var isConnected: Bool { !clients.isEmpty }
  public var connectedProcesses: Set<String> { Set(registeredProcesses.keys) }
  public var events: AsyncStream<PrivateAPIEvent> { eventStream }
  /// The primary path. Kept singular because callers report "where the socket is"; the
  /// full set is `paths`.
  public var path: String { socketPaths.first ?? "" }
  public var paths: [String] { socketPaths }

  // MARK: - Lifecycle

  public func start() async throws {
    guard serverChannels.isEmpty else { return }

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 64)
      .childChannelInitializer { [weak self] channel in
        guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
        let promise = channel.eventLoop.makePromise(of: Void.self)
        Task {
          do {
            try await self.accept(channel)
            promise.succeed(())
          } catch {
            // Closed before any frame is read, so an unauthorised peer never gets
            // to send us anything.
            try? await channel.close()
            promise.fail(error)
          }
        }
        return promise.futureResult
      }

    // One listener per app. A failure to bind ONE is not fatal: a Mac where FaceTime
    // has no container yet must still get a working Messages helper, so the failure is
    // reported and the others still come up.
    for path in socketPaths {
      do {
        try prepareSocketDirectory(for: path)
        let channel = try await bootstrap.bind(unixDomainSocketPath: path).get()
        serverChannels.append(channel)
        // Belt and braces alongside the 0700 directory: even if the directory
        // permissions are wrong, the socket itself is owner-only.
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: path
        )
        logger.info(
          "Private API socket listening", metadata: [.init("path"): .string(path)]
        )
      } catch {
        logger.warning(
          "Could not bind a Private API socket",
          metadata: [
            .init("path"): .string(path),
            .init("error"): .string(String(describing: error)),
          ])
      }
    }
    guard !serverChannels.isEmpty else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "no Private API socket could be bound (tried "
          + socketPaths.joined(separator: ", ") + ")"
      )
    }
  }

  /// Prepares the containing directory and clears any stale socket file.
  ///
  /// The directory is inside MESSAGES' container, not ours, and two things follow:
  ///
  ///   - Writing there requires Full Disk Access. The server already needs it to read
  ///     chat.db, so it is not a new prompt — but the Private API now depends on it, and a
  ///     refusal here must say so rather than surface as an opaque `bind` failure.
  ///   - The directory is Apple's. It is created if absent and its permissions are LEFT
  ///     ALONE — chmod-ing a system app's container to suit us would be overreach, and the
  ///     socket file's own `0600` is what protects it.
  ///
  /// A leftover socket from a crashed process makes `bind` fail with EADDRINUSE, which
  /// would otherwise look like "another server is running" when nothing is.
  private func prepareSocketDirectory(for socketPath: String) throws {
    guard SocketLocation.isUsableSocketPath(socketPath) else {
      throw PrivateAPIError.transportUnavailable(
        "the socket path is \(socketPath.utf8.count) bytes and the maximum is "
          + "\(SocketLocation.maximumSocketPathLength). This usually means a very "
          + "long user name or a network home directory. Set "
          + "BLUEBUBBLES_HELPER_SOCKET to a shorter path inside the app's container."
      )
    }

    let directory = (socketPath as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
      )
    } catch {
      throw PrivateAPIError.transportUnavailable(
        "could not create \(directory): \(error.localizedDescription). The Private "
          + "API needs Full Disk Access to place its socket inside the target "
          + "app's container. Grant it in System Settings > Privacy & Security."
      )
    }

    if FileManager.default.fileExists(atPath: socketPath) {
      try FileManager.default.removeItem(atPath: socketPath)
    }
  }

  public func stop() async {
    await transactions.failAll(with: PrivateAPIError.notConnected)
    for channel in clients.values {
      try? await channel.close().get()
    }
    clients.removeAll()
    registeredProcesses.removeAll()

    for channel in serverChannels {
      try? await channel.close().get()
    }
    serverChannels.removeAll()
    for path in socketPaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    if ownsGroup {
      try? await group.shutdownGracefully()
    }
    logger.info("Private API socket stopped")
  }

  // MARK: - Accepting

  private func accept(_ channel: any Channel) async throws {
    let peer = try await peerIdentity(of: channel)
    do {
      try validator.validate(peer)
    } catch {
      logger.warning(
        "Rejected an untrusted peer",
        metadata: [
          "pid": .stringConvertible(peer.pid)
        ])
      throw PrivateAPIError.untrustedPeer(pid: peer.pid)
    }

    try await channel.pipeline.addHandler(
      LengthPrefixedFrameHandler(
        onFrame: { [weak self] frame, channel in
          Task { await self?.handle(frame: frame, from: channel) }
        },
        onClose: { [weak self] channel in
          Task { await self?.remove(client: channel) }
        },
        logger: logger
      )
    )
    let key = ObjectIdentifier(channel)
    clients[key] = channel
    // Newest last. A reconnect supersedes the connection before it rather than joining
    // it — see `write`.
    connectionOrder.removeAll { $0 == key }
    connectionOrder.append(key)
    logger.info(
      "Verified helper connected",
      metadata: [
        "pid": .stringConvertible(peer.pid),
        "connections": .stringConvertible(clients.count),
      ])
  }

  /// Asks the kernel who is on the other end.
  ///
  /// `LOCAL_PEERTOKEN` on the accepted socket, never anything the peer tells us. The kernel
  /// recorded this at connect time, and unlike `LOCAL_PEERPID` the audit token includes the
  /// pid generation — so it still identifies the right process after the number has been
  /// recycled. See `CodeSignaturePeerValidator.validate`.
  private func peerIdentity(of channel: any Channel) async throws -> PeerIdentity {
    guard let provider = channel as? any SocketOptionProvider else {
      throw PeerValidationError.peerIdentityUnavailable
    }
    do {
      let token: audit_token_t = try await provider.unsafeGetSocketOption(
        level: NIOBSDSocket.OptionLevel(rawValue: SOL_LOCAL),
        name: NIOBSDSocket.Option(rawValue: LOCAL_PEERTOKEN)
      ).get()
      return PeerIdentity(auditToken: token)
    } catch {
      throw PeerValidationError.peerIdentityUnavailable
    }
  }

  private func remove(client channel: any Channel) {
    let key = ObjectIdentifier(channel)
    clients.removeValue(forKey: key)
    connectionOrder.removeAll { $0 == key }
    for (process, identifier) in registeredProcesses where identifier == key {
      registeredProcesses.removeValue(forKey: process)
    }
    if clients.isEmpty {
      Task { await transactions.failAll(with: PrivateAPIError.notConnected) }
    }
  }

  // MARK: - Sending

  @discardableResult
  public func request(
    action: String,
    data: WireJSON,
    timeout: Duration
  ) async throws -> WireJSON? {
    try await request(action: action, data: data, timeout: timeout, process: nil)
  }

  @discardableResult
  public func request(
    action: String,
    data: WireJSON,
    timeout: Duration,
    process: String?
  ) async throws -> WireJSON? {
    let transactionId = UUID().uuidString
    try await write(action: action, data: data, transactionId: transactionId, process: process)
    return try await transactions.await(id: transactionId, timeout: timeout)
  }

  public func send(action: String, data: WireJSON) async throws {
    try await write(action: action, data: data, transactionId: nil, process: nil)
  }

  /// Sends an action to exactly ONE helper.
  ///
  /// This used to write to every connected client, inherited from the legacy TCP bridge —
  /// where several different helpers could plausibly be attached at once, and a broadcast
  /// with "success if any write lands" was the only way to reach whichever was real.
  ///
  /// With a single verified helper that is a bug, and a damaging one. The helper reconnects
  /// whenever the server restarts while Messages keeps running, so a second live connection
  /// from the SAME Messages process is the ordinary state — and every action was then
  /// executed twice. Measured: three API calls produced six messages in chat.db, which
  /// means a real person received everything twice.
  ///
  /// The newest connection wins, because a reconnect means the older one is on its way out.
  /// Dead channels are pruned as they are found rather than swept separately.
  ///
  /// `process` targets a SPECIFIC helper by the bundle id it registered with. A FaceTime
  /// action must reach the FaceTime helper, not whichever registered most recently — with
  /// both a Messages and a FaceTime helper on one socket, "most recent" is a coin toss.
  /// When a target is named but not connected, this fails rather than misrouting to the
  /// wrong helper, because silently sending a FaceTime action to Messages produces a
  /// confusing "unavailable" rather than an honest "the FaceTime helper is not connected."
  private func write(
    action: String, data: WireJSON, transactionId: String?, process: String?
  ) async throws {
    let payload = try JSONEncoder().encode(
      HelperRequest(action: action, data: data, transactionId: transactionId)
    )
    guard payload.count <= LengthPrefixedFrameHandler.maximumFrameBytes else {
      throw PrivateAPIError.rejectedByMessages(reason: "request exceeds the frame limit")
    }

    // Targeted: exactly the named helper, or a clear failure.
    if let process {
      guard let key = registeredProcesses[process], let channel = clients[key] else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "the \(process) helper is not connected"
        )
      }
      var buffer = channel.allocator.buffer(capacity: payload.count + 4)
      buffer.writeInteger(UInt32(payload.count), endianness: .big)
      buffer.writeBytes(payload)
      do {
        try await channel.writeAndFlush(buffer).get()
        return
      } catch {
        clients.removeValue(forKey: key)
        connectionOrder.removeAll { $0 == key }
        registeredProcesses.removeValue(forKey: process)
        throw PrivateAPIError.rejectedByMessages(
          reason: "the \(process) helper connection dropped"
        )
      }
    }

    // UNTARGETED. Every inherited action — sending, reactions, availability, chat edits —
    // belongs to the Messages helper; only the FaceTime routes name a process, and they
    // always do. Falling through to "most recently connected" made those actions land on
    // whichever helper happened to register last, so with both injected a plain
    // `check-facetime-availability` came back as `unknown action` from the FaceTime
    // helper. Prefer Messages explicitly, and keep the most-recent chain only as the
    // fallback for a setup where Messages is not injected at all.
    logger.debug(
      "Routing untargeted request",
      metadata: [
        "action": .string(action),
        "registered": .string(registeredProcesses.keys.sorted().joined(separator: ",")),
        "clients": .stringConvertible(clients.count),
      ])
    if let key = registeredProcesses[HelperHost.messages], let channel = clients[key] {
      var buffer = channel.allocator.buffer(capacity: payload.count + 4)
      buffer.writeInteger(UInt32(payload.count), endianness: .big)
      buffer.writeBytes(payload)
      do {
        try await channel.writeAndFlush(buffer).get()
        return
      } catch {
        clients.removeValue(forKey: key)
        connectionOrder.removeAll { $0 == key }
        registeredProcesses.removeValue(forKey: HelperHost.messages)
      }
    }

    while let key = mostRecentClientKey {
      guard let channel = clients[key] else {
        connectionOrder.removeAll { $0 == key }
        continue
      }
      var buffer = channel.allocator.buffer(capacity: payload.count + 4)
      buffer.writeInteger(UInt32(payload.count), endianness: .big)
      buffer.writeBytes(payload)
      do {
        try await channel.writeAndFlush(buffer).get()
        return
      } catch {
        // That connection is gone. Drop it and try the next most recent rather than
        // failing — a helper mid-reconnect is a normal, recoverable state.
        logger.debug("Dropping a dead helper connection")
        clients.removeValue(forKey: key)
        connectionOrder.removeAll { $0 == key }
      }
    }
    throw PrivateAPIError.notConnected
  }

  /// The most recently registered live client, or nil.
  private var mostRecentClientKey: ObjectIdentifier? {
    connectionOrder.last(where: { clients[$0] != nil })
  }

  // MARK: - Receiving

  private func handle(frame: Data, from channel: any Channel) {
    guard let response = try? JSONDecoder().decode(HelperResponse.self, from: frame) else {
      logger.warning("Undecodable frame from helper")
      return
    }

    if let transactionId = response.transactionId {
      if let reason = response.failureReason {
        Task {
          await transactions.fail(
            id: transactionId,
            with: PrivateAPIError.rejectedByMessages(reason: reason)
          )
        }
      } else {
        let result = response.result
        Task { await transactions.resolve(id: transactionId, with: result) }
      }
      return
    }

    guard let name = response.event else { return }
    if name == HelperEventDecoder.Name.ping.rawValue,
      let process = response.remainder["process"]?.stringValue, !process.isEmpty
    {
      registeredProcesses[process] = ObjectIdentifier(channel)
      logger.info("Helper registered", metadata: ["process": .string(process)])
    }
    guard let event = HelperEventDecoder.decode(name: name, payload: response.remainder) else {
      logger.debug("Unhandled helper event", metadata: ["event": .string(name)])
      return
    }
    eventContinuation.yield(event)
  }
}

// MARK: - Framing

/// 4-byte big-endian length, then that many bytes of JSON.
///
/// Chosen over newline framing because both ends are ours: there is no delimiter for a
/// payload to accidentally contain, the length is known before the body is read, and an
/// oversized frame is rejected before it is buffered rather than after.
private final class LengthPrefixedFrameHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  static let maximumFrameBytes = 64 * 1024 * 1024

  private var buffer = Data()
  private let onFrame: @Sendable (Data, any Channel) -> Void
  private let onClose: @Sendable (any Channel) -> Void
  private let logger: Logger

  init(
    onFrame: @escaping @Sendable (Data, any Channel) -> Void,
    onClose: @escaping @Sendable (any Channel) -> Void,
    logger: Logger
  ) {
    self.onFrame = onFrame
    self.onClose = onClose
    self.logger = logger
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var incoming = unwrapInboundIn(data)
    buffer.append(contentsOf: incoming.readBytes(length: incoming.readableBytes) ?? [])

    while buffer.count >= 4 {
      let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard length <= Self.maximumFrameBytes else {
        logger.error(
          "Helper announced an oversized frame; closing the connection",
          metadata: [
            "bytes": .stringConvertible(length)
          ])
        context.close(promise: nil)
        return
      }
      let total = 4 + Int(length)
      guard buffer.count >= total else { return }

      let frame = buffer[
        buffer.index(
          buffer.startIndex, offsetBy: 4)..<buffer.index(buffer.startIndex, offsetBy: total)]
      buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: total))
      onFrame(Data(frame), context.channel)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    onClose(context.channel)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    logger.debug("Helper socket error", metadata: ["error": .string(String(describing: error))])
    context.close(promise: nil)
  }
}

extension PeerValidationError {
  public var code: String {
    switch self {
    case .peerIdentityUnavailable: "private_api.peer_identity_unavailable"
    case .codeObjectUnavailable: "private_api.code_object_unavailable"
    case .requirementNotMet: "private_api.requirement_not_met"
    case .invalidRequirement: "private_api.invalid_requirement"
    }
  }

  public var domain: String { "PrivateAPI" }

  public var severity: Severity { .critical }

  public var title: String { "A helper connection was refused" }

  public var body: String {
    switch self {
    case .peerIdentityUnavailable: "The connecting process could not be identified."
    case .codeObjectUnavailable(let pid, let status):
      "Process \(pid) has no verifiable code signature (status \(status))."
    case .requirementNotMet(let pid, let status):
      "Process \(pid) did not meet the code requirement (status \(status))."
    case .invalidRequirement(let detail): detail
    }
  }
}

//  SyslogForwarder
//  Delivers audit records to a syslog receiver, and keeps trying when it cannot.
//
//  An exporter holds its own queue, because the recorder hands over a batch and moves on:
//  the database is the record and forwarding is a copy of it, so a receiver that is down must
//  not hold up the write and must not lose what arrived while it was down. The queue is
//  bounded, oldest dropped first, and the drop is counted and recorded once the receiver is
//  back, so the gap is visible in the receiver's own copy.
//
//  One connection, opened on demand and reopened with backoff. TCP and TLS write RFC 6587
//  octet-counted frames down it; UDP sends one datagram per message from a socket bound once.
//  TLS is NIOSSL, the same library the HTTPS listener uses: the receiver's CA (or a
//  self-signed receiver certificate) goes in `trustRoots`, and a client certificate and key
//  make the connection mutually authenticated, which is what a receiver that refuses
//  anonymous senders needs. The PEM text comes from the Keychain by way of the manifest's
//  secret fields; this type never reads a store.
//
//  State transitions are reported, not polled: the service turns the first failure into an
//  alert and an audit record, and the recovery into another, and says nothing in between.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL

/// The PEM material a TLS receiver may need.
public struct SyslogTLSMaterial: Sendable, Hashable {
  /// The CA that signed the receiver's certificate, or the receiver's own self-signed
  /// certificate. Nil trusts the system roots.
  public var trustedCertificatePEM: String?
  /// A certificate the receiver has been told to expect from this server, with its key.
  /// Both or neither.
  public var clientCertificatePEM: String?
  public var clientPrivateKeyPEM: String?

  public init(
    trustedCertificatePEM: String? = nil,
    clientCertificatePEM: String? = nil,
    clientPrivateKeyPEM: String? = nil
  ) {
    self.trustedCertificatePEM = Self.nonEmpty(trustedCertificatePEM)
    self.clientCertificatePEM = Self.nonEmpty(clientCertificatePEM)
    self.clientPrivateKeyPEM = Self.nonEmpty(clientPrivateKeyPEM)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  public var hasClientIdentity: Bool { clientCertificatePEM != nil && clientPrivateKeyPEM != nil }
}

/// Where records go and how.
public struct SyslogDestination: Sendable, Hashable {
  public var host: String
  public var port: Int
  public var transport: SyslogTransportKind
  public var facility: SyslogFacility
  public var tls: SyslogTLSMaterial

  public init(
    host: String,
    port: Int? = nil,
    transport: SyslogTransportKind = .tls,
    facility: SyslogFacility = .local0,
    tls: SyslogTLSMaterial = SyslogTLSMaterial()
  ) {
    self.host = host.trimmingCharacters(in: .whitespaces)
    self.port = port ?? transport.defaultPort
    self.transport = transport
    self.facility = facility
    self.tls = tls
  }

  /// Whether the host is a literal address rather than a name. Decides SNI and hostname
  /// verification, both of which the TLS library refuses or fails for a literal.
  public var hostIsLiteralAddress: Bool {
    (try? SocketAddress(ipAddress: host, port: port)) != nil
  }
}

/// What the forwarder is doing, for the service that reports it.
public enum SyslogForwardingState: Sendable, Equatable {
  /// Nothing has been sent yet.
  case idle
  case connected
  case failing(reason: String)
}

public enum SyslogForwardingError: BBError, CustomStringConvertible {
  /// The PEM text could not be read. Never recovers on its own, so it is reported once and
  /// the forwarder stops trying to connect until it is reconfigured.
  case invalidTLSMaterial(String)
  case notConnected

  public var code: String {
    switch self {
    case .invalidTLSMaterial: "audit.syslog.invalid_tls_material"
    case .notConnected: "audit.syslog.not_connected"
    }
  }
  public var domain: String { "Audit" }
  public var title: String { "Audit records are not reaching the syslog receiver" }
  public var body: String { description }

  public var description: String {
    switch self {
    case .invalidTLSMaterial(let reason):
      "The syslog TLS certificate or key could not be read: \(reason)"
    case .notConnected:
      "The syslog receiver is not connected"
    }
  }
}

public actor SyslogForwarder: AuditExporter {

  /// How many formatted messages wait for the receiver before the oldest are dropped.
  public static let maximumQueued = 10_000
  /// Backoff between connection attempts: a second, doubling, capped at a minute.
  static let retryPolicy = RetryPolicy(
    maxAttempts: Int.max, initialDelay: .seconds(1), maxDelay: .seconds(60), multiplier: 2)
  static let connectTimeout: TimeAmount = .seconds(10)
  static let writeTimeout: Duration = .seconds(15)

  public nonisolated let id = "syslog"

  private let destination: SyslogDestination
  private let hostname: String
  private let processID: Int32
  private let softwareVersion: String?
  private let onStateChange: @Sendable (SyslogForwardingState) async -> Void
  private let logger: Logger
  private let group: any EventLoopGroup

  private var queue: [String] = []
  private var channel: (any Channel)?
  /// Resolved once per connection: the receiver's address, for datagrams.
  private var remoteAddress: SocketAddress?
  private var sslContext: NIOSSLContext?
  private var tlsRefused = false
  private var state: SyslogForwardingState = .idle
  private var sender: Task<Void, Never>?
  private var attempt = 1
  /// Messages dropped since the receiver last heard about it.
  private var droppedSinceReport = 0

  public init(
    destination: SyslogDestination,
    hostname: String,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier,
    softwareVersion: String? = nil,
    onStateChange: @escaping @Sendable (SyslogForwardingState) async -> Void = { _ in },
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    logger: Logger = Logger(label: "bluebubbles.audit.syslog")
  ) {
    self.destination = destination
    self.hostname = hostname
    self.processID = processID
    self.softwareVersion = softwareVersion
    self.onStateChange = onStateChange
    self.group = group
    self.logger = logger
  }

  public var currentState: SyslogForwardingState { state }
  public var queuedCount: Int { queue.count }

  // MARK: - AuditExporter

  public func export(_ events: [AuditEvent]) async {
    for event in events {
      queue.append(
        SyslogMessage.format(
          event, hostname: hostname, processID: processID, facility: destination.facility,
          softwareVersion: softwareVersion))
    }
    if queue.count > Self.maximumQueued {
      let excess = queue.count - Self.maximumQueued
      queue.removeFirst(excess)
      droppedSinceReport += excess
    }
    startSending()
  }

  public func stop() async {
    sender?.cancel()
    sender = nil
    await closeChannel()
    if !queue.isEmpty {
      logger.warning(
        "Stopping with audit records still queued for the syslog receiver",
        metadata: ["queued": .stringConvertible(queue.count)])
    }
    queue = []
  }

  /// Waits until the queue is empty or the sender has given up for now. For tests.
  public func settle() async {
    await sender?.value
  }

  // MARK: - Sending

  private func startSending() {
    guard sender == nil, !queue.isEmpty, !tlsRefused else { return }
    sender = Task { [weak self] in await self?.drainQueue() }
  }

  private func drainQueue() async {
    defer { sender = nil }
    while !Task.isCancelled, let next = queue.first {
      do {
        try await send(next)
        queue.removeFirst()
        attempt = 1
        await transition(to: .connected)
        await reportDropsIfNeeded()
      } catch let error as SyslogForwardingError {
        if case .invalidTLSMaterial = error {
          // Nothing short of new material fixes this, and a retry loop against it would
          // report the same sentence once a minute for ever.
          tlsRefused = true
          await transition(to: .failing(reason: DiagnosticText.sentence(for: error)))
          return
        }
        await backOff(after: error)
      } catch is CancellationError {
        return
      } catch {
        await backOff(after: error)
      }
    }
  }

  private func backOff(after error: any Error) async {
    await closeChannel()
    await transition(to: .failing(reason: DiagnosticText.sentence(for: error)))
    attempt += 1
    // Cancellation is the only error `Task.sleep` throws, and the loop checks it next.
    try? await Task.sleep(for: Self.retryPolicy.delay(forAttempt: attempt))
  }

  private func send(_ message: String) async throws {
    let channel = try await openChannelIfNeeded()
    switch destination.transport {
    case .udp:
      guard let remoteAddress else { throw SyslogForwardingError.notConnected }
      let envelope = AddressedEnvelope(
        remoteAddress: remoteAddress, data: ByteBuffer(string: message))
      try await withTimeout(Self.writeTimeout) {
        try await channel.writeAndFlush(envelope).get()
      }
    case .tcp, .tls:
      let frame = ByteBuffer(string: SyslogMessage.octetCountedFrame(message))
      try await withTimeout(Self.writeTimeout) {
        try await channel.writeAndFlush(frame).get()
      }
    }
  }

  // MARK: - Connecting

  private func openChannelIfNeeded() async throws -> any Channel {
    if let channel, channel.isActive { return channel }
    await closeChannel()

    let opened: any Channel
    switch destination.transport {
    case .udp:
      let address = try SocketAddress.makeAddressResolvingHost(
        destination.host, port: destination.port)
      remoteAddress = address
      opened = try await DatagramBootstrap(group: group)
        .bind(host: address.protocol == .inet6 ? "::" : "0.0.0.0", port: 0)
        .get()
    case .tcp:
      opened = try await ClientBootstrap(group: group)
        .connectTimeout(Self.connectTimeout)
        .connect(host: destination.host, port: destination.port)
        .get()
    case .tls:
      let context = try makeSSLContext()
      // SNI carries a name, never a literal address: the library refuses one.
      let serverName = destination.hostIsLiteralAddress ? nil : destination.host
      opened = try await ClientBootstrap(group: group)
        .connectTimeout(Self.connectTimeout)
        .channelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            let handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
            try channel.pipeline.syncOperations.addHandler(handler)
          }
        }
        .connect(host: destination.host, port: destination.port)
        .get()
    }

    channel = opened
    logger.info(
      "Connected to the syslog receiver",
      metadata: [
        "host": .string(destination.host),
        "port": .stringConvertible(destination.port),
        "transport": .string(destination.transport.rawValue),
      ])
    return opened
  }

  private func makeSSLContext() throws -> NIOSSLContext {
    if let sslContext { return sslContext }
    var configuration = TLSConfiguration.makeClientConfiguration()
    do {
      if let trusted = destination.tls.trustedCertificatePEM {
        configuration.trustRoots = .certificates(
          try NIOSSLCertificate.fromPEMBytes(Array(trusted.utf8)))
      }
      if let certificate = destination.tls.clientCertificatePEM,
        let key = destination.tls.clientPrivateKeyPEM
      {
        configuration.certificateChain = try NIOSSLCertificate.fromPEMBytes(
          Array(certificate.utf8)
        ).map { .certificate($0) }
        configuration.privateKey = .privateKey(
          try NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem))
      }
    } catch {
      throw SyslogForwardingError.invalidTLSMaterial(String(describing: error))
    }
    // A literal address cannot be checked against a certificate's names; the chain is still
    // verified against the trust roots.
    configuration.certificateVerification =
      destination.hostIsLiteralAddress ? .noHostnameVerification : .fullVerification
    let context: NIOSSLContext
    do {
      context = try NIOSSLContext(configuration: configuration)
    } catch {
      throw SyslogForwardingError.invalidTLSMaterial(String(describing: error))
    }
    sslContext = context
    return context
  }

  private func closeChannel() async {
    guard let channel else { return }
    self.channel = nil
    remoteAddress = nil
    // A close on a channel that already went is not an error worth hearing about.
    try? await channel.close().get()
  }

  // MARK: - Reporting

  private func transition(to newState: SyslogForwardingState) async {
    guard newState != state else { return }
    state = newState
    switch newState {
    case .failing(let reason):
      logger.warning(
        "Audit records are not reaching the syslog receiver",
        metadata: [
          "host": .string(destination.host),
          "transport": .string(destination.transport.rawValue),
          "queued": .stringConvertible(queue.count),
          "error": .string(reason),
        ])
    case .connected, .idle:
      break
    }
    await onStateChange(newState)
  }

  /// Once the receiver is reachable again, it is told what it missed. The record is formatted
  /// here rather than through the recorder, so the receiver's copy says so even when the
  /// local copy has already noted the same gap.
  private func reportDropsIfNeeded() async {
    guard droppedSinceReport > 0 else { return }
    let count = droppedSinceReport
    droppedSinceReport = 0
    let notice = AuditEvent(
      kind: .eventsDropped,
      outcome: .failure,
      actor: .system(component: "audit"),
      summary: "\(count) audit records were dropped before they reached the syslog receiver.",
      metadata: ["dropped_count": .int(count), "where": .string("forwarding_queue")]
    )
    queue.insert(
      SyslogMessage.format(
        notice, hostname: hostname, processID: processID, facility: destination.facility,
        softwareVersion: softwareVersion),
      at: 0)
  }
}

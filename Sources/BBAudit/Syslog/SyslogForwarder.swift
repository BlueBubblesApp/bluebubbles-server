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
  public static let defaultWriteTimeout: Duration = .seconds(15)
  /// How long `stop()` keeps delivering to a receiver that is answering. A stop must not wait
  /// on the network, and three seconds is a long time to a receiver on a working link.
  static let drainOnStop: Duration = .seconds(3)

  public nonisolated let id = "syslog"

  private let destination: SyslogDestination
  private let hostname: String
  private let processID: Int32
  private let softwareVersion: String?
  private let onStateChange: @Sendable (SyslogForwardingState) async -> Void
  private let logger: Logger
  private let group: any EventLoopGroup
  /// How long one write may stay unfinished before the connection is given up. Bounds the TLS
  /// handshake too: NIOSSL holds a write until the handshake completes, so a receiver that
  /// accepts the connection and never answers is caught here.
  private let writeTimeout: Duration

  /// A ring rather than an array: it is drained one message at a time from the front, which
  /// on an array shifts everything behind it, and a receiver back from an outage has up to
  /// `maximumQueued` waiting.
  private var queue = CircularBuffer<String>()
  private var channel: (any Channel)?
  /// Resolved once per connection: the receiver's address, for datagrams.
  private var remoteAddress: SocketAddress?
  private var sslContext: NIOSSLContext?
  private var tlsRefused = false
  private var state: SyslogForwardingState = .idle
  /// A `Task?` rather than an `OwnedTask`: the handle clears ON THE ACTOR as the drain finds
  /// the queue empty, so a record queued a moment later starts a new one. An `OwnedTask`
  /// clears only once its body has left the actor, and a record queued in that gap would
  /// find a sender apparently running and wait for the next record to be sent.
  private var sender: Task<Void, Never>?
  /// Which sender is current, so one `stop()` abandoned cannot clear the handle of the next.
  private var senderGeneration = 0
  private var attempt = 1
  /// Messages dropped since the receiver last heard about it.
  private var droppedSinceReport = 0
  /// Set once `stop()` has begun. Nothing is queued and no sender starts after it: a stop
  /// that returned with a sender still able to start would reopen a connection behind a
  /// service that says it has stopped.
  private var isStopped = false

  public init(
    destination: SyslogDestination,
    hostname: String,
    processID: Int32 = ProcessInfo.processInfo.processIdentifier,
    softwareVersion: String? = nil,
    onStateChange: @escaping @Sendable (SyslogForwardingState) async -> Void = { _ in },
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    writeTimeout: Duration = SyslogForwarder.defaultWriteTimeout,
    logger: Logger = Logger(label: "bluebubbles.audit.syslog")
  ) {
    self.writeTimeout = writeTimeout
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
    guard !isStopped else { return }
    // Cut to a datagram over UDP, where the kernel refuses anything larger every time; see
    // `SyslogMessage.datagramLimit`.
    let limit = destination.transport == .udp ? SyslogMessage.datagramLimit : nil
    for event in events {
      queue.append(
        SyslogMessage.format(
          event, hostname: hostname, processID: processID, facility: destination.facility,
          softwareVersion: softwareVersion, maximumBytes: limit))
    }
    if queue.count > Self.maximumQueued {
      let excess = queue.count - Self.maximumQueued
      queue.removeFirst(excess)
      droppedSinceReport += excess
    }
    startSending()
  }

  /// Delivers what is queued, for at most `drainOnStop`, then closes.
  ///
  /// The last records of a run are the ones a receiver most needs: `audit.recording_stopped`
  /// is queued last, and without it a clean stop and a cut feed look the same. So a receiver
  /// that is answering gets them. One that is not is not waited on: its records would only
  /// sit out a backoff, and the local copy has them either way.
  public func stop() async {
    if state == .connected, !queue.isEmpty {
      startSending()
      // Latched only after the drain has started its sender, and before the first await,
      // so an export arriving while this stop is suspended neither queues nor starts a
      // second one.
      isStopped = true
      if let sender {
        // Cancelling the WAIT would not stop the sender, and `withTimeout` waits for its
        // operation to finish; cancelling the sender is what makes the deadline real.
        _ = try? await withTimeout(Self.drainOnStop) {
          await withTaskCancellationHandler {
            await sender.value
          } onCancel: {
            sender.cancel()
          }
        }
      }
    }
    isStopped = true
    // Cancelled AND waited for. A send in flight has already taken its record off the queue,
    // and once the generation has moved on below it does not put it back. The channel is
    // closed first so a write in flight fails at once rather than at its deadline. Closed
    // again after, in case the sender had opened a fresh one before it saw the cancellation.
    let last = sender
    last?.cancel()
    sender = nil
    senderGeneration += 1
    await closeChannel()
    await last?.value
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
    guard sender == nil, !queue.isEmpty, !tlsRefused, !isStopped else { return }
    senderGeneration += 1
    let generation = senderGeneration
    sender = Task { [weak self] in await self?.drainQueue(generation) }
  }

  /// Sends from the front of the queue until it is empty, cancelled, or superseded.
  ///
  /// A record is taken off the queue BEFORE its send and put back on a failure that will be
  /// retried, never removed after the send returns. Removing afterwards removed whatever was
  /// at the front by then, which is not necessarily the record sent: the overflow trim in
  /// `export` can drop the head while its send is suspended, and `stop()` empties the queue,
  /// so the dequeue either took a record that was never sent or found nothing to take.
  private func drainQueue(_ generation: Int) async {
    defer { if generation == senderGeneration { sender = nil } }
    while !Task.isCancelled, let next = queue.popFirst() {
      // Put back for the retry only while this sender is still the current one: after a
      // `stop()` the queue is not this sender's any more.
      func requeue() { if generation == senderGeneration { queue.prepend(next) } }
      do {
        try await send(next)
        attempt = 1
        await transition(to: .connected)
        await reportDropsIfNeeded()
      } catch let error as SyslogForwardingError {
        if case .invalidTLSMaterial = error {
          // Nothing short of new material fixes this, and a retry loop against it would
          // report the same sentence once a minute for ever.
          tlsRefused = true
          requeue()
          await transition(to: .failing(reason: DiagnosticText.sentence(for: error)))
          return
        }
        requeue()
        await backOff(after: error)
      } catch is CancellationError {
        requeue()
        return
      } catch ChannelError.writeMessageTooLarge {
        // This message will be refused however often it is sent, and retrying it would hold
        // every record behind it. Dropped and counted, so the receiver is told; the record
        // itself is in the local copy. Past `datagramLimit` this needs a host whose
        // `net.inet.udp.maxdgram` is set below the default.
        droppedSinceReport += 1
        logger.warning(
          "Dropped an audit record too large for the syslog receiver's transport",
          metadata: ["transport": .string(destination.transport.rawValue)])
      } catch {
        requeue()
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
      try await Self.wait(for: channel.writeAndFlush(envelope), within: writeTimeout) {
        channel.close(promise: nil)
      }
    case .tcp, .tls:
      let frame = ByteBuffer(string: SyslogMessage.octetCountedFrame(message))
      try await Self.wait(for: channel.writeAndFlush(frame), within: writeTimeout) {
        channel.close(promise: nil)
      }
    }
  }

  /// Waits for a NIO future for at most `timeout`, and no longer than the calling task wants.
  ///
  /// Not `withTimeout`: `EventLoopFuture.get()` does not observe cancellation, and
  /// `withTimeout` waits for its operation to finish after cancelling it, so a write to a
  /// receiver that had stopped reading, or a TLS handshake that never completed, held the
  /// sender for good and the deadline bounded nothing. `awaitContinuation` stops waiting at
  /// the deadline or on cancellation whatever the future does, and `abandon` then closes
  /// the channel, which fails the write so nothing is left pending behind it. A result that
  /// arrives after the wait has ended is handed to `late`, so a connection that completes
  /// after its deadline is closed rather than leaked.
  static func wait<Value: Sendable>(
    for future: EventLoopFuture<Value>,
    within timeout: Duration,
    late: @escaping @Sendable (Value) -> Void = { _ in },
    abandon: @escaping @Sendable () -> Void = {}
  ) async throws -> Value {
    try await awaitContinuation(
      timeout: timeout,
      timeoutError: { TimedOut(after: timeout) },
      register: { handle in
        future.whenComplete { result in
          if !handle.resume(with: result), case .success(let value) = result { late(value) }
        }
      },
      abandon: { _ in abandon() }
    )
  }

  // MARK: - Connecting

  private func openChannelIfNeeded() async throws -> any Channel {
    if let channel, channel.isActive { return channel }
    await closeChannel()

    let opened: any Channel
    switch destination.transport {
    case .udp:
      let address = try await Self.resolve(destination.host, port: destination.port)
      remoteAddress = address
      opened = try await Self.waitForChannel(
        DatagramBootstrap(group: group)
          .bind(host: address.protocol == .inet6 ? "::" : "0.0.0.0", port: 0))
    case .tcp:
      opened = try await Self.waitForChannel(
        ClientBootstrap(group: group)
          .connectTimeout(Self.connectTimeout)
          .connect(host: destination.host, port: destination.port))
    case .tls:
      let context = try makeSSLContext()
      // SNI carries a name, never a literal address: the library refuses one.
      let serverName = destination.hostIsLiteralAddress ? nil : destination.host
      opened = try await Self.waitForChannel(
        ClientBootstrap(group: group)
          .connectTimeout(Self.connectTimeout)
          .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
              let handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
              try channel.pipeline.syncOperations.addHandler(handler)
            }
          }
          .connect(host: destination.host, port: destination.port))
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

  /// A connection or a bound socket, waited for no longer than `connectTimeout`.
  ///
  /// The bootstrap's own `connectTimeout` bounds the TCP connect on the event loop; this
  /// bounds the WAIT as well, so a cancelled sender (a `stop()`) is not held until the
  /// connect resolves. A channel that arrives after the wait gave up is closed.
  private static func waitForChannel(
    _ future: EventLoopFuture<any Channel>
  ) async throws -> any Channel {
    try await wait(
      for: future, within: .nanoseconds(connectTimeout.nanoseconds),
      late: { $0.close(promise: nil) })
  }

  /// The receiver's address, for datagrams.
  ///
  /// `makeAddressResolvingHost` is `getaddrinfo`, which blocks for as long as DNS takes. Run
  /// here, on the actor, it would hold one of the few threads every task in the server
  /// shares, for seconds when a resolver is slow, so it runs on NIO's pool for blocking work
  /// and this actor waits without holding anything. Not wrapped in `withTimeout`: the pool
  /// job cannot be cancelled, and `withTimeout` waits for its operation to finish, so it
  /// would bound nothing; the system resolver's own timeout does. (TCP and TLS resolve inside
  /// `ClientBootstrap.connect`, which does not block the caller.)
  private static func resolve(_ host: String, port: Int) async throws -> SocketAddress {
    try await NIOThreadPool.singleton.runIfActive {
      try SocketAddress.makeAddressResolvingHost(host, port: port)
    }
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
    // No task-local context, as for the recorder's own drop notice: the sender task inherits
    // whatever request happened to start it, and this record belongs to no request.
    let notice = AuditContext.$current.withValue(nil) {
      AuditEvent(
        kind: .eventsDropped,
        outcome: .failure,
        actor: .system(component: "audit"),
        summary: "\(count) audit records were dropped before they reached the syslog receiver.",
        metadata: ["dropped_count": .int(count), "where": .string("forwarding_queue")]
      )
    }
    queue.prepend(
      SyslogMessage.format(
        notice, hostname: hostname, processID: processID, facility: destination.facility,
        softwareVersion: softwareVersion))
  }
}

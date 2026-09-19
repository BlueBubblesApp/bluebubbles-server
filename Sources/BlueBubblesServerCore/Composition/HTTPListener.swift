//  HTTPListener
//  Actually binding the port.
//
//  Everything else in the HTTP layer (the route table, the middleware chain, mount-time
//  handler validation) lives elsewhere. This is the part that turns it into a socket
//  somebody can connect to, and it is deliberately separate from `HTTPService` so the
//  lifecycle (bind, wait, shut down) is readable on its own.
//
//  See `.claude/docs/api.md`.

import BBAuth
import BBCore
import BBHTTPAPI
import BBInterfaces
import BBSettings
import BBSocketIO
import BBSystem
import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import Logging
import NIOCore

/// Owns the running Hummingbird application.
public actor HTTPListener {

  public enum ListenerError: BBError, CustomStringConvertible {
    case bindFailed(port: Int, reason: String)
    case alreadyRunning
    /// The configured certificate could not be used. Deliberately fatal to the bind
    /// rather than a fallback to plaintext; see `start(router:host:port:socket:tls:)`.
    case tlsRejected(reason: String)
    /// Something else already holds the port. Separate from `bindFailed` because it has
    /// one likely cause and one obvious remedy, and neither is guessable from `errno 48`.
    case portInUse(port: Int)

    public var description: String {
      switch self {
      case .bindFailed(let port, let reason):
        "Could not bind port \(port): \(reason)"
      case .alreadyRunning:
        "The HTTP listener is already running"
      case .tlsRejected(let reason):
        "The TLS certificate was rejected: \(reason)"
      case .portInUse(let port):
        "Port \(port) is already in use. Another program has it, often another "
          + "macOS user on this Mac running their own BlueBubbles server, since "
          + "every account defaults to the same port. Change Local Port in "
          + "Settings to give this account its own."
      }
    }
  }

  private let logger: Logger
  private var runTask: Task<Void, Never>?
  private var boundPort: Int?

  /// Whether the run task ending is something we asked for.
  ///
  /// Set by `stop()`. Cleared at the top of every `start()`, so it describes the CURRENT run
  /// rather than the last one. Without it every ordinary shutdown would report itself as a
  /// crash, which is the fastest way to teach someone to ignore the report.
  private var isTerminating = false

  /// Whether this run ever reached a bound socket.
  ///
  /// The other half of the same question, and it is not redundant with `isTerminating`: a
  /// bind FAILURE resumes the waiter and ends the run task from the same `catch`, so the two
  /// race, and gating on the flag alone reported "the listener stopped on its own" for a port
  /// that was simply taken — a second, vaguer notice for a problem `start()` already throws a
  /// precise error about. Gating on "did it ever serve" has no race in it: before the bind the
  /// caller is told by that throw, and after it there is nobody else to tell.
  private var hasBound = false

  /// How many connections may be open at once. See the listener configuration below.
  static let maximumConnections = 128

  /// Told when the listener stops without being asked to. See `handleExit(_:)`.
  private var onUnexpectedExit: (@Sendable ((any Error)?) async -> Void)?

  public init(logger: Logger = Logger(label: "bluebubbles.http")) {
    self.logger = logger
  }

  public var isRunning: Bool { runTask != nil }
  public var port: Int? { boundPort }

  /// Binds and starts serving.
  ///
  /// Returns once the socket is actually bound, not once the task is spawned. That
  /// distinction is the whole reason for the continuation below: a service whose `start()`
  /// returns before the port is listening reports success while clients get connection
  /// refused, and the registry would then start the socket and the tunnel on top of it.
  /// - Parameters:
  ///   - socket: The Socket.IO transport, if one is being served. Passed here rather than
  ///     mounted on the router alone because the websocket UPGRADE is a channel-level
  ///     decision (it happens before the router sees the request) and the socket has to
  ///     share this port, as it does today.
  ///   - tls: TLS material, when the server is terminating TLS itself. Applied by WRAPPING
  ///     the channel the websocket upgrade is built on, so `wss://` works for free: one
  ///     configuration covers both surfaces, and there is no way to end up with an
  ///     encrypted API and a plaintext socket on the same port.
  ///   - onUnexpectedExit: Called if the listener stops without `stop()` having been asked
  ///     for. Not optional in spirit: a server process that is alive with no listening socket
  ///     is the worst state this component has, and for a long time it reached nobody.
  public func start(
    router: Router<BBRequestContext>,
    host: String,
    port: Int,
    socket: SocketIOTransport? = nil,
    tls: CertificateStore.Material? = nil,
    onUnexpectedExit: (@Sendable ((any Error)?) async -> Void)? = nil
  ) async throws {
    guard runTask == nil else { throw ListenerError.alreadyRunning }

    let logger = logger
    let bound = BindingSignal()
    isTerminating = false
    hasBound = false
    self.onUnexpectedExit = onUnexpectedExit

    // Only when a socket is being served. Installing the upgrade channel unconditionally
    // would add a websocket handshake path to a server that has nothing behind it, which
    // is a new surface for no gain.
    let base =
      socket.map { Self.webSocketServer(transport: $0, logger: logger) }
      ?? .http1()

    let server: HTTPServerBuilder
    if let tls {
      do {
        server = try .tls(base, tlsConfiguration: Self.tlsConfiguration(from: tls))
        logger.info("Serving over HTTPS")
      } catch {
        // A refused certificate must not be a silent downgrade to plaintext: someone
        // who configured TLS believes their traffic is encrypted, and quietly
        // serving `http://` while telling them nothing is worse than not starting.
        throw ListenerError.tlsRejected(reason: String(describing: error))
      }
    } else {
      server = base
    }

    let application = Application(
      responder: router.buildResponder(),
      server: server,
      configuration: ApplicationConfiguration(
        address: .hostname(host, port: port),
        serverName: "BlueBubbles",
        // A CEILING ON CONCURRENT CONNECTIONS, which nothing had.
        //
        // The body cap bounds one request; it says nothing about how many arrive together.
        // With a 100 MB maximum body, four concurrent uploads is 400 MB of buffer on hardware
        // targeted at 4 GB, and the comment in `HTTPServer.dispatch` that retracts the old
        // ordering argument says exactly this: "N unauthenticated connections cost N times the
        // cap". Moving body collection below authentication fixed WHO could do it and left
        // HOW MANY unbounded.
        //
        // 128 is far above what this server legitimately sees — a handful of clients, each
        // with one socket and one or two in-flight requests — and far below what the memory
        // budget can survive. Past it the listener stops ACCEPTING rather than failing
        // requests, so a client waits instead of being told something untrue.
        availableConnectionsDelegate: .maximum(Self.maximumConnections, logger: logger)
      ),
      // The authoritative did-bind signal. Probing the port by connecting to it is not
      // one.
      //
      // Inferring readiness from a successful connect cannot tell "I bound this port"
      // from "somebody else already has it". On a Mac with two users logged in, both
      // servers default to port 1234; the second one's bind fails, its probe connects
      // to the FIRST one's listener, and it reports itself as listening while serving
      // nothing. Fast user switching is an ordinary setup, so this is not a corner.
      onServerRunning: { channel in
        await bound.markBound(port: channel.localAddress?.port)
      },
      logger: logger
    )

    // Bound-or-failed, whichever happens first.
    let task = Task { [weak self] in
      do {
        // NO graceful-shutdown signals, and this is not a detail.
        //
        // `runService()` defaults to `[.sigterm, .sigint]`, and a ServiceGroup claims
        // those PROCESS-WIDE: it sets them to SIG_IGN and takes them over with its own
        // signal sources. In the app that produced a genuinely alarming state: a
        // SIGTERM from `pkill`, a script, or launchd shut the HTTP server down and
        // left everything else running, so the process stayed alive with no listening
        // socket, the UI still said "running", and every client silently lost the
        // server. Measured, not theorised: `lsof -iTCP -sTCP:LISTEN` on the surviving
        // process came back empty.
        //
        // Nothing is lost by declining them. `stop()` shuts this down by CANCELLING
        // this task, which is the path every other service uses and the one the
        // registry drives. Whoever owns the process (the app's delegate, the CLI's
        // `waitForTermination`) owns its signals.
        try await application.runService(gracefulShutdownSignals: [])
      } catch {
        // Still resumes anyone waiting on the bind, which is what this did before and is
        // how a bind failure becomes a thrown `start()`. What it did NOT do was tell anyone
        // once the waiters were gone: after `waitUntilBound` has returned, `fail` has no
        // continuations left, so it assigned the error to a field nothing reads and the
        // listener died in total silence. `handleExit` is the half that was missing.
        await bound.fail(error)
        await self?.handleExit(error)
        return
      }
      // `runService` returning is a graceful shutdown, which for us is `stop()` — but only
      // when we asked. Returning on its own is just as bad as throwing, and reaches the same
      // reporting path.
      await self?.handleExit(nil)
    }
    runTask = task

    do {
      try await bound.waitUntilBound(timeout: .seconds(10))
    } catch {
      // The caller is about to be told by a thrown error. `hasBound` is still false, so the
      // task's own exit cannot also be reported as an unexplained death.
      task.cancel()
      runTask = nil
      throw Self.bindError(error, port: port)
    }

    // What the kernel assigned, falling back to what was asked for. These differ only when
    // the request was port 0 ("any free port") and reporting the 0 back would make
    // `port` a value nothing can connect to.
    let listening = await bound.assignedPort ?? port
    boundPort = listening
    hasBound = true
    logger.info(
      "HTTP API listening",
      metadata: [
        "host": .string(host), "port": .stringConvertible(listening),
      ])
  }

  /// Turns a bind failure into something a person can act on.
  ///
  /// "Address already in use" is by far the most common one and has a specific cause worth
  /// naming: another process (very often this same server running under a DIFFERENT macOS
  /// user, since every user's server defaults to port 1234) already holds it. The generic
  /// error says `errno 48`, which sends the user to a search engine.
  static func bindError(_ error: any Error, port: Int) -> ListenerError {
    let description = String(describing: error)
    let isInUse =
      description.contains("addressInUse")
      || description.contains("Address already in use")
      || description.contains("errno: 48")

    guard isInUse else {
      return .bindFailed(port: port, reason: description)
    }
    return .portInUse(port: port)
  }

  /// Builds the HTTP1-with-websocket-upgrade channel.
  ///
  /// `shouldUpgrade` answers for `/socket.io/` only; every other path falls through to the
  /// ordinary HTTP responder untouched. The session is opened here, inside the upgrade
  /// decision, because a websocket-only EIO3 client never polls, so this request is both
  /// its handshake and its connection.
  private static func webSocketServer(
    transport: SocketIOTransport,
    logger: Logger
  ) -> HTTPServerBuilder {
    .http1WebSocketUpgrade(
      configuration: .init(
        // Matches `maxHttpBufferSize` in the reference's socketOpts. Engine.IO's own
        // `maxPayload` is advertised to the client; this is the frame ceiling that
        // enforces it.
        //
        // `autoPing` is OFF on purpose. Engine.IO carries its own heartbeat as
        // MESSAGE-level `2`/`3` packets, which `EngineIOServer` drives on the
        // schedule the client was told at handshake time. Layering RFC 6455 pings
        // underneath would keep a dead session's transport alive past its own
        // `pingTimeout`, so the reaper would never fire.
        ws: .init(maxFrameSize: 100 * 1024 * 1024, autoPing: .disabled)
      )
    ) { request, channel, _ in
      guard transport.shouldUpgrade(request: request) else { return .dontUpgrade }

      let query = SocketIOTransport.queryParameters(fromPath: request.path ?? "")
      let peer = channel.remoteAddress?.ipAddress
      // Read from the UPGRADE request, which is the only place it exists: once the socket
      // is a websocket there are no more HTTP headers. The polling handshake already
      // passes this; the websocket path did not, so a websocket-only client behind a
      // tunnel could not be blocked per-client.
      let forwardedFor = request.headerFields[.init("X-Forwarded-For")!]

      return .upgrade([:]) { inbound, outbound, _ in
        // An existing sid means the client is UPGRADING a polling session and the
        // session already exists; no sid means it connected straight to the
        // websocket and this is its handshake.
        let sid: String?
        if let existing = query["sid"] {
          sid = existing
        } else {
          sid = await transport.openForWebSocket(
            query: query, clientAddress: peer, forwardedFor: forwardedFor, outbound: outbound
          )
        }
        guard let sid else {
          logger.debug("Closing a websocket with no usable session")
          return
        }
        await transport.handleWebSocket(sid: sid, inbound: inbound, outbound: outbound)
      }
    }
  }

  /// Turns PEM text into a NIOSSL server configuration.
  ///
  /// The certificate file is read as a CHAIN, not a single certificate. A certificate
  /// issued by a real CA arrives with intermediates concatenated after it, and serving
  /// only the leaf produces the single most common TLS complaint there is: it works in a
  /// browser that happens to have cached the intermediate, and fails on a phone that has
  /// not, which reads to the user as "it works on my laptop".
  static func tlsConfiguration(
    from material: CertificateStore.Material
  ) throws -> TLSConfiguration {
    let chain = try NIOSSLCertificate.fromPEMBytes(Array(material.certificatePEM.utf8))
    let key = try NIOSSLPrivateKey(bytes: Array(material.privateKeyPEM.utf8), format: .pem)

    var configuration = TLSConfiguration.makeServerConfiguration(
      certificateChain: chain.map { .certificate($0) },
      privateKey: .privateKey(key)
    )
    // The server presents a certificate; it does not ask clients for one. Requiring
    // client certificates would lock out every existing client.
    configuration.certificateVerification = .none
    return configuration
  }

  /// The run task has ended. Decides whether that was a shutdown or a failure.
  ///
  /// Reached from inside the run task, which is safe while `stop()` is suspended on
  /// `runTask.value`: actors are reentrant at a suspension point, and this is the same hop
  /// `clearTask()` already made.
  ///
  /// The reporting half is the whole point of this method existing. A listener that stops on
  /// its own leaves the process alive with nothing on the port: every client gets connection
  /// refused, `health` flips to "not listening" — and nothing polls health on a headless
  /// install, so the single artefact anyone gets is the log. Which is why this logs at
  /// `error` unconditionally before anything else: whatever the handler does or does not do
  /// with it, the log bundle the user sends in has to contain the reason.
  private func handleExit(_ error: (any Error)?) async {
    let shouldReport = hasBound && !isTerminating
    runTask = nil
    boundPort = nil
    hasBound = false
    guard shouldReport else { return }

    if let error {
      logger.error(
        "The HTTP listener stopped on its own; the server is no longer reachable",
        metadata: ["error": .string(String(describing: error))])
    } else {
      // No error at all is the stranger of the two: the service returned as though it had
      // been asked to shut down, and it was not.
      logger.error("The HTTP listener returned without being asked to stop")
    }

    let report = onUnexpectedExit
    onUnexpectedExit = nil
    await report?(error)
  }

  /// Ends the run task without going through `stop()`, and waits for the fallout.
  ///
  /// Not a simulation: this drives the real path. Cancelling the task makes `runService`
  /// throw, which lands in the same `catch` a spontaneous failure lands in, with
  /// `isTerminating` false — which is precisely the condition `handleExit` exists to detect.
  /// The genuine cause (Hummingbird's service returning or throwing on its own) cannot be
  /// provoked from outside the library, and the observable this actor reacts to is identical.
  ///
  /// Internal because `HTTPListenerExitTests` is the only caller; it also leaves the port
  /// released, so a test using it does not strand a listener.
  func endRunTaskWithoutStopping() async {
    guard let runTask else { return }
    runTask.cancel()
    _ = await runTask.value
  }

  public func stop() async {
    guard let runTask else { return }
    // Set BEFORE the cancellation, because the task can reach `handleExit` the moment it is
    // cancelled and the flag is what tells it this was asked for.
    isTerminating = true
    // Cancellation is how Hummingbird's service is asked to shut down gracefully; it
    // stops accepting, drains in-flight requests, and returns.
    runTask.cancel()
    _ = await runTask.value
    self.runTask = nil
    boundPort = nil
    hasBound = false
    onUnexpectedExit = nil
    logger.info("HTTP API stopped")
  }
}

/// Waits for the listener to bind, or for the server task to fail first.
///
/// Driven by Hummingbird's `onServerRunning` callback rather than by probing the port. A
/// probe cannot distinguish this server binding from ANOTHER process already holding the
/// port, which on a multi-user Mac is exactly what happens, since every user's server
/// defaults to the same port.
actor BindingSignal {

  private var failure: (any Error)?
  private var isBound = false
  /// The port the socket is actually on, read off the bound channel.
  ///
  /// Not the same as the port that was REQUESTED whenever that was 0, which asks the kernel
  /// to choose. Carrying it here is what lets `HTTPListener.port` answer truthfully in that
  /// case instead of reporting the 0 it was handed.
  private(set) var assignedPort: Int?
  private var waiters: [CheckedContinuation<Void, any Error>] = []

  func fail(_ error: any Error) {
    failure = error
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume(throwing: error) }
  }

  func markBound(port: Int? = nil) {
    isBound = true
    assignedPort = port
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }

  func waitUntilBound(timeout: Duration) async throws {
    struct BindTimeout: Error, CustomStringConvertible {
      var description: String { "the listener did not bind in time" }
    }

    if let failure { throw failure }
    if isBound { return }

    // A deadline as well as the callback: a bind that neither succeeds nor reports a
    // failure would otherwise hang startup forever, and the registry has nothing to
    // time out against.
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      await self?.fail(BindTimeout())
    }
    defer { timeoutTask.cancel() }

    try await withCheckedThrowingContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

extension HTTPListener.ListenerError {
  public var code: String {
    switch self {
    case .bindFailed: "http.bind_failed"
    case .alreadyRunning: "http.already_running"
    case .tlsRejected: "http.tls_rejected"
    case .portInUse: "http.port_in_use"
    }
  }

  public var domain: String { "HTTP" }

  public var isUserFacing: Bool { true }

  public var title: String { "The server could not start listening" }

  public var body: String { description }
}

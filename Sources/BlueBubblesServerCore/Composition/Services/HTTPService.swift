//  HTTPService
//  The REST API and the socket transport, on one listener.
//
//  This is the one service whose host is a purpose-built value rather than a composition of
//  capabilities. The things it needs are not independent capabilities that one service
//  happens to want: they are, between them, everything required to stand up the
//  listener, and a protocol naming all of them would be `AppContext` under another name.
//  `HTTPServiceHost` names the job instead. It is also what lets this service be constructed
//  in a test from values rather than from a whole server.

import BBAudit
import BBAuth
import BBBuiltIns
import BBCore
import BBDiagnostics
import BBHTTPAPI
import BBHandlers
import BBLicense
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import Hummingbird
import Logging

/// Everything needed to build and run the listener, and nothing else.
///
/// Two members are functions rather than values, and each for a reason that would otherwise
/// be a bug. `handlers` is late-bound: the registry is populated by `AppContext.finishWiring`
/// after the container exists, and `isHelperConnected` changes over the life of the process
/// as the injected helper connects and drops.
struct HTTPServiceHost: Sendable {
  /// Narrowed to what `BuiltInManifests.http` declares: port, bind address, TLS and the
  /// published address the certificate's SAN needs.
  let settings: ScopedSettings
  let alerts: AlertCenter
  let logger: Logger
  let accessControl: AccessControlService
  let tokenAuth: TokenAuthService
  let passwordDigests: PasswordDigestCache
  let engineIO: EngineIOServer
  let additionalRouteGroups: [RouteGroup]
  let clientActivity: ClientActivityTracker
  /// The container's counters, so a restart of this service keeps counting into the same
  /// ones rather than starting a fresh set nobody reads.
  let requestMetrics: RequestMetrics
  /// Told when the listener dies on its own: `health` flips to "not listening" the moment it
  /// does, and the registry re-reads health only on report.
  let healthReporter: any HealthChangeReporting
  /// TLS material out of the Keychain.
  ///
  /// A narrow collaborator rather than the secret store itself, and that is the manifest
  /// model working as intended: a secret is never declarable, so a service that needs one
  /// asks the host for the specific job instead of being handed the Keychain. This one can
  /// read and write TLS material and nothing else.
  let certificates: CertificateKeychainStore
  /// The audit log, as the two things the listener feeds it: refusals from the auth stage
  /// and a record per finished request. Narrow on purpose, like `certificates`: the service
  /// records; it never reads the table.
  let audit: AuditRequestBridge
  /// Resolved per start: nothing is registered when the container is constructed.
  let handlers: @Sendable () async -> HandlerRegistry
  /// Resolved per request, never captured; see the call site.
  let isHelperConnected: @Sendable () async -> Bool
  /// The switches routes declare with `requiring:`, evaluated per request against the live
  /// settings, so turning one off closes its routes without a restart.
  let routeGates: RouteGateStage
  /// The live subscription entitlement, resolved per request for the same reason.
  ///
  /// A closure rather than the runtime itself: this service reads one value off it and has
  /// no business refreshing anything, which is `LicenseService`'s job.
  let licenseStatus: @Sendable () async -> LicenseStatus
}

extension HTTPServiceHost {
  /// The composition root's projection. The only place that knows this service's host is
  /// assembled from the container.
  init(_ context: AppContext) {
    self.init(
      settings: context.scopedSettings(for: HTTPService.manifest),
      alerts: context.alerts,
      logger: context.logger,
      accessControl: context.accessControl,
      tokenAuth: context.tokenAuth,
      passwordDigests: context.passwordDigests,
      engineIO: context.engineIO,
      additionalRouteGroups: context.additionalRouteGroups,
      clientActivity: context.clientActivity,
      requestMetrics: context.requestMetrics,
      healthReporter: context,
      certificates: CertificateKeychainStore(secrets: context.secrets, logger: context.logger),
      audit: AuditRequestBridge(recorder: context.auditLog),
      handlers: { [weak context] in await context?.httpHandlers ?? HandlerRegistry() },
      isHelperConnected: { [weak context] in await context?.isHelperConnected ?? false },
      routeGates: RouteGateStage { [weak context] gate in
        // Weak for the reason `handlers` is: the container owns this service. A request that
        // outlives the container is one arriving while the server is torn down.
        guard let context else { throw ServiceUnavailable("The server is shutting down") }
        try await RouteGates.check(gate, context: context)
      },
      licenseStatus: context.license.statusProvider()
    )
  }
}

actor HTTPService: Service, ConfigurableService {
  static let manifest = BuiltInManifests.http
  /// The manifest's reads (port, bind address, TLS) plus the password, which this service
  /// does not read (authentication is delegated) but must restart on, to kick clients that
  /// authenticated with the old one.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.password.key])
  }
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(1), max: .seconds(30), attempts: 10
  )

  typealias Host = HTTPServiceHost

  private let host: HTTPServiceHost
  private let listener = HTTPListener()
  /// Re-checks whether the self-signed certificate has entered its renewal window. See
  /// `startCertificateWatch`.
  private let certificateWatch = OwnedTask()

  init(host: HTTPServiceHost) { self.host = host }

  /// How often the certificate expiry is re-checked. Daily: the window is thirty days, so
  /// anything finer buys nothing and anything coarser risks stepping over it.
  private static let certificateCheckInterval = Duration.seconds(24 * 60 * 60)

  /// Reports a self-signed certificate that has entered its renewal window.
  ///
  /// Renewal itself happens at `start`, and is reached nowhere else — so a server left up
  /// for eleven months served an expired certificate, and the failure is total and silent on
  /// the server side: every client stops connecting and nothing here says why.
  ///
  /// This REPORTS rather than renews. Swapping the material under a bound listener is a
  /// restart in everything but name, and the restart the user then makes is what renews,
  /// through the path that already works. The alert says that, so the remedy is the next
  /// step rather than a puzzle.
  private func startCertificateWatch() {
    certificateWatch.runPeriodically(
      every: Self.certificateCheckInterval, after: Self.certificateCheckInterval
    ) { [host] in
      guard let expiry = await TLSProvisioning.isDueForRenewal(settings: host.settings)
      else { return }
      await host.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "The server's TLS certificate is about to expire",
          body: "It expires on \(expiry.formatted(date: .abbreviated, time: .omitted)). "
            + "Restart the server and a new one is generated automatically. Without that, "
            + "clients stop being able to connect.",
          source: "tls",
          diagnostics: Diagnostics(code: "tls.renewal_due", domain: "TLS"),
          dedupeKey: "tls.renewal_due"
        )
      )
    }
  }

  func start() async throws {
    let port = try await host.settings.get(Settings.socketPort)
    let (router, corsPolicy) = try await makeRouter()
    let socket = Self.mountSocket(on: router, engine: host.engineIO, policy: corsPolicy)

    // TLS wraps the channel the websocket upgrade is built on, so `https://` and
    // `wss://` are the same decision: there is no way to end up with an encrypted API
    // and a plaintext socket on one port.
    let tls = await TLSProvisioning.material(
      settings: host.settings,
      store: CertificateStore(),
      keychain: host.certificates,
      alerts: host.alerts,
      logger: host.logger
    )

    // Validated before binding, because the failure it prevents is confusing. A pinned
    // address disappears whenever DHCP moves it or an interface goes down, and `bind(2)`
    // then fails with `EADDRNOTAVAIL`, which reads as "the port is taken" to everyone
    // who has ever seen it.
    //
    // It refuses rather than falling back to 0.0.0.0, matching the TLS decision: someone
    // who narrowed the bind did it deliberately, and silently listening on every
    // interface instead would widen their exposure without asking. Recovery does not need
    // the UI; `--set bind_address=0.0.0.0` works from the command line.
    let bindAddress = try await host.settings.get(Settings.bindAddress)
    try await validate(bindAddress: bindAddress)

    try await startListener(
      router: router, bindAddress: bindAddress, port: port, socket: socket, tls: tls)

    // Started only after the listener is up, so a failed bind does not leave a timer
    // running for a service that never came up.
    startCertificateWatch()
  }

  /// The REST API's router, built per start. The CORS policy comes back beside it because the
  /// socket mounted on the same listener answers under the same one.
  private func makeRouter() async throws -> sending (Router<BBRequestContext>, CORSPolicy) {
    // The auth chain is built HERE rather than being long-lived, because it depends on
    // `auth_mode` and on the password, and both can change while the server runs. A
    // chain captured at construction would keep authenticating against a password the
    // user has since changed.
    let digests = host.passwordDigests
    let chain = await host.tokenAuth.chain(
      passwordProvider: { await digests.digest() }
    )

    let isHelperConnected = host.isHelperConnected
    // Resolved at call time through the runtime, for the same reason as `isHelperConnected`:
    // a key is entered, a subscription lapses and is renewed while the server runs.
    let licenseStatus = host.licenseStatus
    let clientActivity = host.clientActivity
    let audit = host.audit
    // Read once, here, which is why a change to it restarts this service rather than taking
    // effect live: the policy is baked into the router's middleware when the router is built.
    let allowedOrigin = try await host.settings.get(Settings.corsAllowedOrigin)
    let corsPolicy = CORSPolicy(configured: allowedOrigin)

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(allowedOrigin: allowedOrigin),
      authentication: AuthenticationStage(
        chain: chain, accessControl: host.accessControl,
        auditor: AuditAuthenticationBridge(recorder: audit.recorder)
      ),
      privateAPI: PrivateAPIStage(isConnected: {
        // Resolved at call time, not captured: the Private API may connect, drop and
        // reconnect while the HTTP server keeps running, so a boolean taken here would be
        // wrong within seconds.
        //
        // Through the CONTAINER, which is the same question `server/info` answers: one
        // path to one fact. Looking the service up by type would return nil silently on a
        // miss, which lands here as "no helper", so a rename or a deregistration would make
        // every Private-API route refuse while `server/info` went on reporting the helper
        // as connected.
        await isHelperConnected()
      }),
      gates: host.routeGates,
      // COMPOSED ONLY WHEN THIS BUILD CAN VERIFY A LICENSE. With no public key compiled in
      // there is no way for anyone to satisfy a gated route, so enforcing would answer 402
      // to every caller of FaceTime, stickers and the rest with no possible remedy. Absent,
      // not disabled: dropping a key into `LicensePublicKey` is what turns the gate on, and
      // nothing else about this line changes when it does.
      license: LicensePublicKey.isConfigured
        ? LicenseStage(
          status: licenseStatus, auditor: AuditLicenseRefusalBridge(recorder: audit.recorder))
        : .unenforced,
      metrics: host.requestMetrics,
      onClientActivity: {
        clientActivity.note()
      },
      onRequestCompleted: { record in
        audit.requestCompleted(record)
      },
      // Its own label, not the host's root logger: the access line and every HTTP error
      // are what a reader filters by subsystem for.
      logger: Logger(label: "bluebubbles.http")
    )

    let router = try builder.buildRouter(
      registry: await host.handlers(),
      additionalGroups: host.additionalRouteGroups
    )
    return (router, corsPolicy)
  }

  private static func mountSocket(
    on router: Router<BBRequestContext>, engine: EngineIOServer, policy corsPolicy: CORSPolicy
  ) -> SocketIOTransport {
    // Mounted on the same listener as the REST API, as today: one port, both surfaces.
    // The polling endpoints go on the router; the upgrade is handled at the channel.
    // The SAME policy the REST middleware got. The socket has no port of its own — it is
    // mounted on this listener — so an operator who narrows the origin and finds the event
    // stream still answering every page would be right to call that a bug. BBSocketIO takes a
    // closure rather than the policy type so it gains no dependency on BBHTTPAPI for one
    // value; this is the composition root's job, and it is the one place that sees both.
    let socket = SocketIOTransport(
      engine: engine, corsHeaders: Self.socketCORSHeaders(policy: corsPolicy)
    )
    socket.mount(on: router)
    return socket
  }

  private func startListener(
    router: sending Router<BBRequestContext>,
    bindAddress: String,
    port: Int,
    socket: SocketIOTransport,
    tls: CertificateStore.Material?
  ) async throws {
    // A listener that dies is not a log line either. `health` does flip to "not listening",
    // but nothing polls health on a headless install, so on the deployment this server is
    // built for the state reached nobody at all: the process alive, the port empty, every
    // client refused, and no notice anywhere. Two things reach out: the alert, and a health
    // report, so the app's rows agree with the alert the moment it is raised.
    let alerts = host.alerts
    let healthReporter = host.healthReporter
    try await listener.start(
      router: router, host: bindAddress, port: port, socket: socket, tls: tls,
      onUnexpectedExit: { error in
        await healthReporter.serviceHealthDidChange(Self.id)
        await alerts.raise(
          UserAlert(
            severity: .critical,
            title: "The server stopped accepting connections",
            body: "The API is no longer listening, so no client can reach this Mac. The "
              + "server itself is still running and will try to start the listener again "
              + "within a minute. If it does not come back, restart the server from the "
              + "Connection page.",
            source: "HTTP",
            diagnostics: error.map {
              Diagnostics(
                code: "http.listener_stopped",
                domain: "HTTP",
                underlyingDescription: String(describing: $0)
              )
            },
            actions: [.openSettings(.settings)],
            dedupeKey: "http.listener-stopped",
            // Re-established by the next start either way, and a copy of this surviving a
            // restart would say the server is unreachable while it is serving.
            isDurable: false
          )
        )
      }
    )
  }

  /// The socket transport's CORS headers under one policy.
  ///
  /// A named static rather than a closure written inline, so a test can exercise the thing
  /// that actually runs. The alternative is a test that rebuilds the same three lines and
  /// passes while the wiring is wrong, which is the one useless shape for this.
  ///
  /// The allow-origin default is cleared before the policy writes its own: `defaultCORSHeaders`
  /// carries the wildcard this transport has always sent, and leaving it in place would mean a
  /// narrowed policy that allows nobody still answered `*`.
  static func socketCORSHeaders(policy: CORSPolicy) -> @Sendable (String?) -> HTTPFields {
    { origin in
      var headers = SocketIOTransport.defaultCORSHeaders
      headers[.accessControlAllowOrigin] = nil
      CORSPolicy.apply(policy, origin: origin, to: &headers)
      return headers
    }
  }

  /// Refuses a bind address this machine does not have.
  ///
  /// `0.0.0.0` (every interface) and `127.0.0.1` (loopback) always pass: they are not
  /// interface addresses and are always bindable.
  private func validate(bindAddress: String) async throws {
    guard bindAddress != "0.0.0.0", bindAddress != "127.0.0.1", bindAddress != "::" else {
      return
    }

    let available = SystemInfo.localAddresses(.ipv4) + SystemInfo.localAddresses(.ipv6)
    guard !available.contains(bindAddress) else { return }

    await host.alerts.raise(
      UserAlert(
        severity: .error,
        title: "This Mac no longer has the address the server listens on",
        body: "The server is set to listen on \(bindAddress), which is not currently "
          + "assigned to any network interface; it usually means the network "
          + "changed. Available addresses: "
          + (available.isEmpty ? "none" : available.joined(separator: ", "))
          + ". Change Listen On under Configure HTTP Settings on the Connection page, "
          + "or set it back to all interfaces.",
        source: "HTTP",
        actions: [.openSettings(.settings)],
        dedupeKey: "http.bind-address-missing",
        // The interface list is read fresh on every bind, so this answer is only
        // ever true of the start that raised it.
        isDurable: false
      )
    )
    throw HTTPListener.ListenerError.bindFailed(
      port: await host.settings.valueOrDefault(Settings.socketPort),
      reason: "\(bindAddress) is not assigned to any interface on this Mac"
    )
  }

  func stop() async {
    await certificateWatch.stop()
    await listener.stop()
  }

  /// Watched, but consumed live: a change to one of these must NOT rebuild the listener.
  ///
  /// `server_address` is watched because `TLSProvisioning` puts the published address in a
  /// generated certificate's SAN. It is also WRITTEN by whichever connection method is
  /// running, on every connect and every reconnect, and the five reverse proxies declare a
  /// dependency on this service, so restarting on it restarted them, each restart
  /// reconnected the tunnel, and the reconnect published the address again. Measured on a
  /// Cloudflare quick tunnel: the listener was torn down and cloudflared respawned about
  /// twenty times a second, indefinitely, until the process was killed.
  ///
  /// `ServiceManifest.watchedSettingKeys` already subtracts the keys a service WRITES, for
  /// exactly this reason: "a restart on each publish is a loop". That subtraction only sees
  /// a service looping on its OWN write. This is the same loop one hop out, through a
  /// dependent, where the writer and the restarter are different services and neither
  /// declaration is wrong on its own.
  ///
  /// Restarting would not apply a new address in any case: a certificate is generated once
  /// and persisted, and `TLSProvisioning` reuses the stored one on every later start.
  private static let liveKeys: Set<String> = [Settings.serverAddress.key]

  /// Whether a change rebuilds the listener.
  ///
  /// Static and pure, so it can be asserted without assembling a host: the listener's
  /// address, port and TLS are read once in `start`, so this decision IS whether a setting
  /// takes effect before the next launch. `HTTPListenerReconfigurationTests` holds it.
  ///
  /// Intersected with what this service watches BEFORE the exemption is applied: a batch
  /// that writes `server_address` alongside a key belonging to some other service must not
  /// be read as "something restart-worthy changed".
  ///
  /// Everything else this service watches rebuilds the listener, and the default direction
  /// is deliberate: a read added to the manifest later restarts until someone decides
  /// otherwise. A password change must kick connected clients: they authenticated with the
  /// old one, and leaving them connected means a revoked password still works until they
  /// happen to reconnect.
  static func reloadAction(for change: SettingsChange) -> ReloadAction {
    let relevant = change.changedKeys
      .intersection(watchedSettings)
      .subtracting(liveKeys)
    return relevant.isEmpty ? .none : .restart
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    Self.reloadAction(for: change)
  }

  /// **`.failed`, not `.degraded`, and the distinction is load-bearing.** `.degraded` means
  /// running but not fully functional — a tunnel that is connected and rate limited. An HTTP
  /// server that is not listening is not running at all: every client is refused, and there
  /// is nothing partial about it.
  ///
  /// The registry only asks a service for its health while an instance EXISTS, and
  /// `performStop` clears the instance, so reaching this branch means the service is
  /// supposed to be listening and is not. That is a failure by any reading.
  ///
  /// Two things keyed off the old answer and both were wrong because of it. `APIReachability`
  /// maps `.degraded` to `.reachable` on the reasoning that a degraded service "still answers
  /// requests, so the address is real" — true for a rate-limited tunnel, false for a dead
  /// listener, so the app showed a reachable address for a server refusing every connection.
  /// And a recovery pass keyed on network changes has to be able to tell "broken, retry when
  /// the network returns" from "working, leave it alone"; `.degraded` cannot carry that,
  /// because `PrivateAPIGatedService` reports it for a Mac that simply has no helper.
  var health: ServiceHealth {
    get async { await listener.isRunning ? .running : .failed(reason: "not listening") }
  }

  /// A listener that exited on its own is revived by the liveness poll, within its budget,
  /// rather than waiting for somebody to read the alert and restart the server.
  var isAlive: Bool { get async { await listener.isRunning } }
}

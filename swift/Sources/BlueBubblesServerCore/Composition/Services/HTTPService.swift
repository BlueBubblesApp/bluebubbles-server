//  HTTPService
//  The REST API and the socket transport, on one listener.

import BBBuiltIns
import BBDiagnostics
import BBHTTPAPI
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import Hummingbird

actor HTTPService: ContextualService, ConfigurableService {
  static let manifest = BuiltInManifests.http
  /// The manifest's reads — port, bind address, TLS — plus the password, which this service
  /// does not read (authentication is delegated) but must restart on, to kick clients that
  /// authenticated with the old one.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.password.key])
  }
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(1), max: .seconds(30), attempts: 10
  )

  let context: AppContext
  private let listener = HTTPListener()

  init(host: AppContext) { self.context = host }

  func start() async throws {
    let port = await context.settings.get(Settings.socketPort)

    // The auth chain is built HERE rather than being long-lived, because it depends on
    // `auth_mode` and on the password — and both can change while the server runs. A
    // chain captured at construction would keep authenticating against a password the
    // user has since changed.
    let settings = context.settings
    let digests = context.passwordDigests
    let chain = await context.tokenAuth.chain(
      passwordProvider: { await digests.digest() }
    )

    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: AuthenticationStage(
        chain: chain, accessControl: context.accessControl
      ),
      privateAPI: PrivateAPIStage(isConnected: { [weak self] in
        // Resolved through the registry at call time: the Private API may connect,
        // drop, and reconnect while the HTTP server keeps running, so a captured
        // boolean would be wrong within seconds.
        guard let self else { return false }
        let service = await self.context.service(PrivateAPIGatedService.self)
        guard let service else { return false }
        if case .running = await service.health { return true }
        return false
      }),
      onClientActivity: { [weak self] in
        self?.context.clientActivity.note()
      },
      logger: context.logger
    )

    let router = try builder.buildRouter(
      registry: await context.httpHandlers,
      additionalGroups: context.additionalRouteGroups
    )
    // Mounted on the same listener as the REST API, as today: one port, both surfaces.
    // The polling endpoints go on the router; the upgrade is handled at the channel.
    let socket = SocketIOTransport(engine: context.engineIO)
    socket.mount(on: router)

    // TLS wraps the channel the websocket upgrade is built on, so `https://` and
    // `wss://` are the same decision — there is no way to end up with an encrypted API
    // and a plaintext socket on one port.
    let tls = await TLSProvisioning.material(
      settings: settings,
      store: CertificateStore(),
      alerts: context.alerts,
      logger: context.logger
    )

    // Validated before binding, because the failure it prevents is confusing. A pinned
    // address disappears whenever DHCP moves it or an interface goes down, and `bind(2)`
    // then fails with `EADDRNOTAVAIL` — which reads as "the port is taken" to everyone
    // who has ever seen it.
    //
    // It refuses rather than falling back to 0.0.0.0, matching the TLS decision: someone
    // who narrowed the bind did it deliberately, and silently listening on every
    // interface instead would widen their exposure without asking. Recovery does not need
    // the UI — `--set bind_address=0.0.0.0` works from the command line.
    let host = await context.settings.get(Settings.bindAddress)
    try await validate(bindAddress: host)

    try await listener.start(
      router: router, host: host, port: port, socket: socket, tls: tls
    )
  }

  /// Refuses a bind address this machine does not currently have.
  ///
  /// `0.0.0.0` (every interface) and `127.0.0.1` (loopback) always pass — they are not
  /// interface addresses and are always bindable.
  private func validate(bindAddress: String) async throws {
    guard bindAddress != "0.0.0.0", bindAddress != "127.0.0.1", bindAddress != "::" else {
      return
    }

    let available = SystemInfo.localAddresses(.ipv4) + SystemInfo.localAddresses(.ipv6)
    guard !available.contains(bindAddress) else { return }

    await context.alerts.raise(
      UserAlert(
        severity: .error,
        title: "This Mac no longer has the address the server listens on",
        body: "The server is set to listen on \(bindAddress), which is not currently "
          + "assigned to any network interface — it usually means the network "
          + "changed. Available addresses: "
          + (available.isEmpty ? "none" : available.joined(separator: ", "))
          + ". Change Listen On, or set it back to all interfaces.",
        source: "HTTP",
        actions: [.openSettings(.settings)],
        dedupeKey: "http.bind-address-missing",
        // The interface list is read fresh on every bind, so this answer is only
        // ever true of the start that raised it.
        isDurable: false
      )
    )
    throw HTTPListener.ListenerError.bindFailed(
      port: await context.settings.get(Settings.socketPort),
      reason: "\(bindAddress) is not assigned to any interface on this Mac"
    )
  }

  func stop() async {
    await listener.stop()
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    // A password change must kick connected clients — they authenticated with the old
    // one, and leaving them connected means a revoked password still works until they
    // happen to reconnect.
    .restart
  }

  var health: ServiceHealth {
    get async { await listener.isRunning ? .running : .degraded(reason: "not listening") }
  }
}

//  HTTPService
//  The REST API and the socket transport, on one listener.
//
//  This is the one service whose host is a purpose-built value rather than a composition of
//  capabilities. The eleven things it needs are not eleven independent capabilities that one
//  service happens to want: they are, between them, everything required to stand up the
//  listener, and a protocol naming all of them would be `AppContext` under another name.
//  `HTTPServiceHost` names the job instead. It is also what lets this service be constructed
//  in a test from eleven values rather than from a whole server.

import BBAuth
import BBBuiltIns
import BBDiagnostics
import BBHTTPAPI
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
  /// TLS material out of the Keychain.
  ///
  /// A narrow collaborator rather than the secret store itself, and that is the manifest
  /// model working as intended: a secret is never declarable, so a service that needs one
  /// asks the host for the specific job instead of being handed the Keychain. This one can
  /// read and write TLS material and nothing else.
  let certificates: CertificateKeychainStore
  /// Resolved per start: nothing is registered when the container is constructed.
  let handlers: @Sendable () async -> HandlerRegistry
  /// Resolved per request, never captured; see the call site.
  let isHelperConnected: @Sendable () async -> Bool
}

extension HTTPServiceHost {
  /// The composition root's projection. The only place that knows this service's host is
  /// assembled from the container.
  init(_ context: AppContext) {
    self.init(
      settings: ScopedSettings(
        store: context.settings, manifest: HTTPService.manifest,
        secretKeys: Settings.secretKeys, logger: context.logger
      ),
      alerts: context.alerts,
      logger: context.logger,
      accessControl: context.accessControl,
      tokenAuth: context.tokenAuth,
      passwordDigests: context.passwordDigests,
      engineIO: context.engineIO,
      additionalRouteGroups: context.additionalRouteGroups,
      clientActivity: context.clientActivity,
      certificates: CertificateKeychainStore(secrets: context.secrets, logger: context.logger),
      handlers: { [weak context] in await context?.httpHandlers ?? HandlerRegistry() },
      isHelperConnected: { [weak context] in await context?.isHelperConnected ?? false }
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

  init(host: HTTPServiceHost) { self.host = host }

  func start() async throws {
    let port = try await host.settings.get(Settings.socketPort)

    // The auth chain is built HERE rather than being long-lived, because it depends on
    // `auth_mode` and on the password, and both can change while the server runs. A
    // chain captured at construction would keep authenticating against a password the
    // user has since changed.
    let settings = host.settings
    let digests = host.passwordDigests
    let chain = await host.tokenAuth.chain(
      passwordProvider: { await digests.digest() }
    )

    let isHelperConnected = host.isHelperConnected
    let clientActivity = host.clientActivity
    let builder = HTTPAPIBuilder(
      configuration: HTTPAPIConfiguration(),
      authentication: AuthenticationStage(
        chain: chain, accessControl: host.accessControl
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
      onClientActivity: {
        clientActivity.note()
      },
      logger: host.logger
    )

    let router = try builder.buildRouter(
      registry: await host.handlers(),
      additionalGroups: host.additionalRouteGroups
    )
    // Mounted on the same listener as the REST API, as today: one port, both surfaces.
    // The polling endpoints go on the router; the upgrade is handled at the channel.
    let socket = SocketIOTransport(engine: host.engineIO)
    socket.mount(on: router)

    // TLS wraps the channel the websocket upgrade is built on, so `https://` and
    // `wss://` are the same decision: there is no way to end up with an encrypted API
    // and a plaintext socket on one port.
    let tls = await TLSProvisioning.material(
      settings: settings,
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

    try await listener.start(
      router: router, host: bindAddress, port: port, socket: socket, tls: tls
    )
  }

  /// Refuses a bind address this machine does not currently have.
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

  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    // Intersected with what this service watches BEFORE the exemption is applied: a batch
    // that writes `server_address` alongside a key belonging to some other service must not
    // be read as "something restart-worthy changed".
    //
    // Everything else this service watches rebuilds the listener, and the default direction
    // is deliberate: a read added to the manifest later restarts until someone decides
    // otherwise. A password change must kick connected clients: they authenticated with the
    // old one, and leaving them connected means a revoked password still works until they
    // happen to reconnect.
    let relevant = change.changedKeys
      .intersection(Self.watchedSettings)
      .subtracting(Self.liveKeys)
    return relevant.isEmpty ? .none : .restart
  }

  var health: ServiceHealth {
    get async { await listener.isRunning ? .running : .degraded(reason: "not listening") }
  }
}

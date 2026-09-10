//  ServerComposition
//  Building the server, once, in one place.
//
//  Everything above this file takes what it needs as a parameter. This is the only code that
//  knows the whole graph, and it is deliberately readable top to bottom: what starts before
//  what is answered by reading this file, not by tracing.
//
//  Three properties this is responsible for:
//
//    1. **The server starts even when things are wrong.** No Full Disk Access, no Firebase,
//       no helper: it still comes up, so the user can reach the UI and fix it. A server that
//       refuses to boot cannot tell anyone why it refused.
//    2. **Optional subsystems stay absent when unconfigured.** Push with no credentials and
//       token auth under the default mode are not disabled features holding resources; they
//       are never constructed, and their routes are never registered.
//    3. **Start order is derived, stop order is its exact reverse.** Both come from the
//       declared dependency graph rather than from two hand-maintained lists.
//
//  See `.claude/docs/architecture.md`.

import BBAuth
import BBBuiltIns
import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBHandlers
import BBIMessage
import BBInterfaces
import BBPersistence
import BBPrivateAPI
import BBProxy
import BBPushKit
import BBSerialization
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import BBTooling
import Foundation
import GRDB
import Logging

public struct ServerComposition {

  public struct Options: Sendable {
    public var headless: Bool
    public var configPath: String?
    /// Overrides from the command line, which win over both the config file and the
    /// stored value.
    public var overrides: [String: String]
    /// Applies to both the file log and stdout.
    public var logLevel: Logger.Level

    public init(
      headless: Bool = false,
      configPath: String? = nil,
      overrides: [String: String] = [:],
      logLevel: Logger.Level = .info
    ) {
      self.headless = headless
      self.configPath = configPath
      self.overrides = overrides
      self.logLevel = logLevel
    }
  }

  /// The long-lived storage every other object is built from.
  ///
  /// Split out of `build` so it can be opened WITHOUT building a server. Two callers need
  /// that: `bluebubbles-server --migrate`, which runs a migration and exits, and the app,
  /// which has to know whether a migration is pending before it decides to start anything.
  ///
  /// Opening it twice is not an option, which is why this is a value passed in rather than
  /// a second `AppDatabase.open`. GRDB defaults `busyMode` to `.immediateError`
  /// (`Configuration.swift`) and `AppDatabase.open` does not override it, so a second live
  /// connection throws `SQLITE_BUSY` on the first contended write with no retry and nothing
  /// pointing at the cause. `SettingsStore` also caches the whole table in memory, so two
  /// stores would silently disagree after either one wrote.
  public struct Storage: Sendable {
    public let logSink: FileSink
    public let logger: Logger
    public let appDatabase: AppDatabase
    /// The Keychain in production; a test passes what it likes.
    public let secrets: any SecretStore
    public let settings: SettingsStore
  }

  /// Opens storage and nothing else. Safe to call before deciding whether to start.
  ///
  /// `LoggingSystemBootstrap.bootstrap` is idempotent, so this sitting in front of a later
  /// `build(storage:options:)` costs nothing.
  public static func prepareStorage(options: Options = Options()) async throws -> Storage {
    // Bootstrapped before anything else logs, and to the SAME path the Electron server
    // uses: an operator debugging a migrated install should find one log file where
    // they expect it, not two. Held so `GET /server/logs` can tail it: without the sink,
    // that route has nothing to read and a client's log viewer goes blank.
    let logSink = LoggingSystemBootstrap.bootstrap(level: options.logLevel)
    let logger = Logger(label: "bluebubbles")

    let appDatabase = try AppDatabase.open(contributors: AppSchema.contributors)
    // Service name from `ApplicationSupport`, NOT the default, so a run redirected by
    // `BB_SUPPORT_DIRECTORY` cannot reach the real installation's credentials. See the
    // comment on `keychainService`.
    let secrets = KeychainSecretStore(service: ApplicationSupport.keychainService)
    let settings = try await SettingsStore(
      database: appDatabase,
      secrets: secrets,
      configFileValues: ConfigFile.load(at: options.configPath),
      commandLineValues: options.overrides
    )

    // Raised to whatever the user asked for, as soon as the store can answer.
    //
    // After the store rather than at bootstrap, because the level LIVES in the store: the
    // handful of lines logged before this point are start-up chatter at the default level.
    // Without this the setting is read by nothing, so turning on debug logging does nothing
    // and gives no hint why.
    LoggingSystemBootstrap.setLevel(
      Settings.logLevel(from: await settings.get(Settings.logLevel))
    )

    return Storage(
      logSink: logSink, logger: logger, appDatabase: appDatabase,
      secrets: secrets, settings: settings
    )
  }

  /// Builds every long-lived object and returns the assembled server.
  ///
  /// Opens its own storage. Callers that already have some (because they had to inspect it
  /// first) pass it to `build(storage:options:)` instead.
  public static func build(options: Options = Options()) async throws -> RunningServer {
    try await build(storage: try await prepareStorage(options: options), options: options)
  }

  /// Builds from storage somebody else opened.
  ///
  /// The steps, in the order they happen: refuse an install nobody has adopted, move each
  /// service's settings into the shape it expects, open the read path, build the services
  /// that everything else leans on, build the transport, assemble the context, register
  /// the services, and hand back the assembled server.
  ///
  /// Each step is a function below this one, in call order, so the file still reads top to
  /// bottom, and each is short enough to hold in one's head, which the 345-line version of
  /// this function had stopped being.
  public static func build(
    storage: Storage, options: Options = Options()
  ) async throws -> RunningServer {
    let logger = storage.logger
    let settings = storage.settings

    try await refuseUnadoptedInstall(settings: settings)
    await prepareServiceSettings(settings: settings, logger: logger)

    let readPath = await openReadPath(settings: settings, logger: logger)
    let shared = await makeSharedServices(storage: storage)
    let transport = await makeTransport(storage: storage)

    // Decided before the context is built, because the HTTP service mounts them and is
    // constructed by the registry with nothing but a context to read from.
    let additionalGroups = await routeGroups(
      authMode: transport.authMode,
      codecs: transport.codecs,
      features: Set(
        await settings.featureStates().filter(\.value).keys.map(\.id)
      ),
      faceTime: await settings.get(Settings.enableFaceTimePrivateAPI),
      faceTimeIncoming: await settings.get(Settings.faceTimeIncomingHandoff)
    )

    let context = AppContext(
      storage: storage,
      readPath: readPath,
      shared: shared,
      transport: transport,
      additionalRouteGroups: additionalGroups,
      // Registered with every manifest below, so a tool is known to the manager because
      // a service declared it, not because this file lists it a second time.
      tools: ToolManager(
        alerts: shared.alerts,
        // The bundled copy stays a fallback rather than being removed: a build that
        // does ship binaries in `Contents/Resources/bin` keeps working, and an
        // offline first run has something to fall back to.
        bundledLocator: { BundledBinaries.path(for: $0) },
        logger: logger
      )
    )

    let registry = await makeRegistry(context: context, shared: shared, settings: settings)
    await context.finishWiring(
      registry: registry,
      handlers: buildHandlers(
        context: context,
        authMode: transport.authMode,
        codecs: transport.codecs,
        additionalGroups: additionalGroups,
        logSink: storage.logSink,
        logger: logger
      )
    )

    // Every tool any service declares, in one registry. Derived from the manifests so a
    // program the server can install is exactly a program some service said it needs,
    // and so a third-party connection method's binary is managed by the same code that
    // manages ngrok's, with no list here to add itself to.
    await context.tools.register(BuiltInManifests.all)
    await registerServices(in: registry)

    return RunningServer(
      context: context,
      logSink: storage.logSink,
      registry: registry,
      // Constructed here rather than inside `start()` so the whole graph is visible in
      // one place, and so a test can drive it without standing up a listener.
      propagation: makePropagation(
        settings: settings, registry: registry, context: context, shared: shared,
        passwordDigests: transport.passwordDigests
      ),
      handlers: await context.httpHandlers,
      routeGroups: additionalGroups,
      options: options,
      logger: logger
    )
  }

  // MARK: - Before anything is built

  /// Refuses to build on an unadopted Electron install. This does NOT migrate.
  ///
  /// Migrating automatically would rewrite a user's settings and move their credentials with
  /// no notice and no way to decline, and redoing a settings import is not harmless: it
  /// writes every key it finds with no comparison and reverts anything changed since.
  ///
  /// Building on defaults instead would be worse still (a different port, no password)
  /// so the answer is to refuse and say so. `bluebubbles-server --migrate` adopts it; the
  /// app presents a wizard. Certificates are deliberately NOT in the blocking set: see
  /// `MigrationStep.isBlocking`.
  static func refuseUnadoptedInstall(settings: SettingsStore) async throws {
    let migration = await MigrationStateStore.status(in: settings)
    if migration.isBlockingStart {
      throw MigrationPending(steps: migration.blocking.map(\.step))
    }
  }

  /// Runs each service's own settings migrations.
  ///
  /// In the same window and for the same reason as the install gate above: a service that
  /// reads its settings before they have been moved configures itself from the old shape
  /// and never looks again.
  ///
  /// Validated BEFORE migrations run, because a migration is described by the same
  /// manifest: applying one from a manifest that has not been checked would be acting on
  /// untrusted instructions about where someone's data should go.
  static func prepareServiceSettings(settings: SettingsStore, logger: Logger) async {
    let validated = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: [ServiceIdentifier(await settings.get(Settings.connectionMethod))],
      logger: logger,
      // No alert centre yet: it is constructed further down, after storage. A conflict
      // found here is logged and re-raised once the centre exists rather than being
      // dropped; see `SettingsPropagation`, which re-validates on a settings change.
      alerts: nil
    )
    await ServiceSettingsBridge.prepare(
      manifests: validated, store: settings, logger: logger
    )
  }

  // MARK: - chat.db

  /// Everything the read path needs, or nothing at all.
  ///
  /// Optional as a set rather than one field at a time: without Full Disk Access there is
  /// no database, and with no database there is no profile, no repository and no
  /// serializer either. Four independent optionals could express states that cannot happen.
  struct ReadPath: Sendable {
    var database: ReadOnlyDatabase?
    var profile: SchemaProfile?
    var messages: MessageRepository?
    var serializer: MessageSerializer?
  }

  /// Opens `chat.db`, or reports that it could not.
  ///
  /// Optional, and that is the point. Without Full Disk Access there is no database to
  /// open, and the server must still start, or the user cannot reach the permissions
  /// page that would fix it.
  static func openReadPath(settings: SettingsStore, logger: Logger) async -> ReadPath {
    do {
      // Read before the open, because it decides which KIND of connection to make. One is
      // the default and the shape this has always had; see `Settings.chatDatabaseReaders`
      // and the benchmark it points at.
      let database = try ReadOnlyDatabase(
        path: ChatDatabase.defaultPath,
        maximumReaders: await settings.get(Settings.chatDatabaseReaders))
      let profile = try await SchemaProfile.detect(
        in: database, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
      )
      logger.info(
        "Opened chat.db",
        metadata: [
          "dateUnit": .string(String(describing: profile.dateUnit)),
          // What it OPENED with, not what was asked for: a pool that could not open falls
          // back to one connection, and a setting that silently did nothing is worse than
          // one that did nothing loudly.
          "readers": .stringConvertible(database.readerCount),
        ])
      return ReadPath(
        database: database,
        profile: profile,
        messages: MessageRepository(database: database, profile: profile),
        serializer: MessageSerializer(profile: profile)
      )
    } catch {
      // Reported, not fatal.
      logger.warning(
        "chat.db is not readable; the read path is unavailable",
        metadata: [
          "error": .string(String(describing: error))
        ])
      return ReadPath()
    }
  }

  // MARK: - Cross-cutting

  /// The four services everything else is built on top of.
  struct SharedServices: Sendable {
    let alerts: AlertCenter
    let permissions: PermissionsService
    let accessControl: AccessControlService
    let contacts: ContactIndex
  }

  /// Builds the alert centre, the permission monitor, access control and the contact index.
  static func makeSharedServices(storage: Storage) async -> SharedServices {
    let appDatabase = storage.appDatabase
    let settings = storage.settings

    let alerts = AlertCenter()
    // Attached before anything can raise, so an alert from start-up (the likeliest moment
    // for one) is stored rather than being the one that gets lost. Restoring happens here
    // too: what comes back is what was unread and undismissed within the retention window,
    // with live-condition alerts restored already-read so a problem that cleared while the
    // server was down does not greet the user as current.
    await alerts.attach(store: AlertRepository(database: appDatabase))

    // The settings store is built before this point, so a Keychain failure during
    // start-up (the likeliest moment for one, and the one that decides whether the
    // server can authenticate at all) has nowhere to be reported until now. Attaching
    // drains anything already held.
    await settings.attachAlerts(alerts)

    let permissions = PermissionsService(
      onChange: { id, from, to in
        // A permission revoked after setup (which happens on OS upgrades) is
        // reported when it breaks rather than surfacing later as odd failures.
        //
        // **`.unknown` IS NOT A REVOCATION**, and treating it as one produced 112 "A
        // permission was revoked" notifications for `automation-messages` on a permission
        // the Permissions page correctly showed as granted the whole time. Its own
        // declaration says what it means: "the check could not run. Reported rather than
        // guessed at." The probe returns it whenever
        // `AEDeterminePermissionToAutomateTarget` overruns `tccProbeDeadline`: measured,
        // with a thread parked in it on a semaphore, so a busy `tccd` became a scary
        // warning about a permission nobody had touched.
        //
        // Only a DEFINITE negative is worth waking somebody for. `.restricted` counts: MDM
        // or parental controls really did take it away.
        guard from == .granted, to.isDefiniteRefusal else { return }
        await alerts.raise(
          UserAlert(
            severity: .warning,
            title: "A permission was revoked",
            body: "\(id.rawValue) is no longer granted, so some features have stopped working.",
            source: "Permissions",
            // Coalesced: a permission that flaps must not produce one alert per
            // two-second refresh.
            dedupeKey: "permission.\(id.rawValue)"
          )
        )
      }
    )

    let accessControl = AccessControlService(
      policy: await accessPolicy(from: settings),
      trust: await proxyTrust(from: settings),
      alerts: alerts,
      persistence: AccessControlStore(database: appDatabase)
    )
    // Read back BEFORE anything is served, so a client blocked before the restart does
    // not get one free window, and an administrator's allowlist is in force from the
    // first request rather than from whenever they next open the Security page.
    await accessControl.loadPersistedState()
    await accessControl.trustLocalNetwork(await settings.get(Settings.trustLocalNetwork))

    return SharedServices(
      alerts: alerts,
      permissions: permissions,
      accessControl: accessControl,
      contacts: ContactIndex(database: appDatabase)
    )
  }

  // MARK: - Transport

  /// How a client reaches the server: what it may speak, how it proves who it is, and the
  /// socket it speaks over.
  struct Transport: Sendable {
    let authMode: AuthMode
    let codecs: CodecNegotiator
    let tokenAuth: TokenAuthService
    let passwordDigests: PasswordDigestCache
    let events: EventBus
    let socketServer: SocketServer
    let engineIO: EngineIOServer
  }

  static func makeTransport(storage: Storage) async -> Transport {
    let settings = storage.settings

    // Codecs are registered, but the ceiling defaults to legacy-v1, so a client
    // advertising sealed-v2 still gets legacy-v1 until an operator raises it. Built to be
    // switchable, not switched.
    let codecPreference = await settings.get(Settings.eventPayloadCodec)
    let codecs = CodecNegotiator.full(preference: CodecIdentifier(codecPreference.rawValue))

    // Under `auth_mode = password` this constructs nothing: no signing key, no device
    // store, no bearer scheme.
    let authMode = await settings.get(Settings.authMode)
    let tokenAuth = TokenAuthService(
      configuration: TokenAuthConfiguration(mode: authMode),
      secrets: authMode == .password ? nil : storage.secrets
    )

    // Hashed once, not once per request. `SettingsPropagation` clears it when `password`
    // is written, so the "checked against the password as it is now" property below still
    // holds; see PasswordDigest.swift for why only successful reads are cached.
    let passwordDigests = PasswordDigestCache(
      load: { await settings.secret(Settings.password) }
    )

    let socketServer = SocketServer(negotiator: codecs)
    let engineIO = EngineIOServer(
      server: socketServer,
      // The auth chain is a CLOSURE rather than a value, so a handshake is checked against
      // the password as it is now. Capturing a chain here would keep authenticating
      // against whatever the password was at launch, and a password change would not lock
      // anybody out until the process restarted: the opposite of what changing it means.
      chain: { [tokenAuth] in
        await tokenAuth.chain(
          passwordProvider: { await passwordDigests.digest() }
        )
      },
      // A closure for the same reason the chain is one, and additionally because the
      // engine outlives every start and stop of the socket service. Reading the setting
      // per handshake is also what makes the answer right at BOOT: a socket switched off
      // before the server started never runs `SocketService.start`, so a flag that only
      // that method could set would say "accepting" forever.
      isAccepting: { [settings] in
        await ServiceEnablement.isEnabled(BuiltInManifests.ID.socket, settings: settings)
      }
    )

    return Transport(
      authMode: authMode,
      codecs: codecs,
      tokenAuth: tokenAuth,
      passwordDigests: passwordDigests,
      events: EventBus(),
      socketServer: socketServer,
      engineIO: engineIO
    )
  }

  // MARK: - Registry

  static func makeRegistry(
    context: AppContext, shared: SharedServices, settings: SettingsStore
  ) async -> ServiceRegistry<AppContext> {
    let alerts = shared.alerts
    return ServiceRegistry(
      host: context,
      permissionCheck: await shared.permissions.permissionCheck(),
      // What the Integrations screen's switches actually DO: a write to `disabled_services`
      // reaches the registry here, so a webhook endpoint stops receiving events when it is
      // switched off rather than only losing its "enabled" tag.
      enablementCheck: { [settings] id in
        await ServiceEnablement.isEnabled(id, settings: settings)
      },
      enablementSettings: [Settings.disabledServicesKey],
      onAlert: { id, error in
        await alerts.raise(
          UserAlert(
            severity: .error,
            title: "\(id.rawValue) stopped working",
            body: DiagnosticText.sentence(for: error),
            source: "Services",
            dedupeKey: "service.\(id.rawValue)",
            // A live condition: on the next start the service either comes up or fails
            // again and says so, so the stale one must not greet the user as current.
            isDurable: false
          )
        )
      }
    )
  }

  /// Every service, registered. Order is DERIVED from each service's declared
  /// dependencies, not from the order they appear here.
  static func registerServices(in registry: ServiceRegistry<AppContext>) async {
    await registry.register(PermissionsMonitorService.self) { $0 }
    await registry.register(ContactsService.self) { $0 }
    await registry.register(ChangeDetectionService.self) { $0 }
    await registry.register(HTTPService.self) { HTTPServiceHost($0) }
    await registry.register(SocketService.self) { $0 }
    await registry.register(PrivateAPIGatedService.self) { $0 }
    await registry.register(PushDeliveryService.self) { $0 }
    await registry.register(WebhookDeliveryService.self) { $0 }
    await registry.register(ScheduledMessageService.self) { $0 }
    // Six connection methods, one exclusive category: all register, and `canRun` lets
    // exactly the selected one through. This is what makes a third-party tunnel possible:
    // it joins a category rather than adding a case to an enum.
    await registry.register(ProxyService<LANMethod>.self) { $0 }
    await registry.register(ProxyService<DynamicDNSMethod>.self) { $0 }
    await registry.register(ProxyService<NgrokMethod>.self) { $0 }
    await registry.register(ProxyService<CloudflareMethod>.self) { $0 }
    await registry.register(ProxyService<ZrokMethod>.self) { $0 }
    await registry.register(ProxyService<TailscaleMethod>.self) { $0 }
    await registry.register(SleepPreventionService.self) { $0 }
    await registry.register(LaunchAtLoginService.self) { $0 }
    await registry.register(ToolUpdateService.self) { $0 }
  }

  // MARK: - Settings propagation

  static func makePropagation(
    settings: SettingsStore,
    registry: ServiceRegistry<AppContext>,
    context: AppContext,
    shared: SharedServices,
    passwordDigests: PasswordDigestCache
  ) -> SettingsPropagation {
    let alerts = shared.alerts
    return SettingsPropagation(
      settings: settings, registry: registry, accessControl: shared.accessControl,
      // The tunnel writes `server_address` and this is what turns that write into
      // something clients hear about: a `new-server` frame, and a Firebase document
      // for the ones that are not connected.
      onServerAddressChanged: { [weak context] address in
        guard let lifecycle = await context?.lifecycle else { return }
        await lifecycle.announce(serverAddress: address)
      },
      // Saved, not yet in effect, and one click from being in effect. Deduplicated
      // on a fixed key so toggling one of these repeatedly leaves one standing
      // notice rather than a pile of identical ones.
      onRestartRequired: { [alerts] keys in
        let names = keys.map(Settings.label(forKey:)).sorted()
          .joined(separator: ", ")
        await alerts.raise(
          UserAlert(
            severity: .info,
            title: "Restart the server to apply this",
            body: "\(names) is saved, but the server reads it while starting "
              + "up. Restarting applies it; connected clients reconnect on "
              + "their own.",
            source: "settings",
            actions: [.restartServer],
            dedupeKey: "structural-setting-changed",
            // Restarting is exactly what clears this, so it must never survive one.
            isDurable: false
          )
        )
      },
      passwordDigests: passwordDigests
    )
  }

  // MARK: - Routes

  /// The additive route groups, chosen by configuration.
  ///
  /// This is where "not registered" is enforced. A group absent from this array is absent
  /// from the router, and its paths 404 exactly like any unknown path.
  static func routeGroups(
    authMode: AuthMode,
    codecs: CodecNegotiator,
    features: Set<String> = [],
    faceTime: Bool = false,
    faceTimeIncoming: Bool = false
  ) async -> [RouteGroup] {
    var groups: [RouteGroup] = []

    // ALWAYS MOUNTED. v2 is not opt-in.
    //
    // Gating it behind a setting would protect nobody. v1 is frozen and stays frozen, which
    // is what actually protects an existing client; v2 is a separate prefix that no v1
    // client asks for. A capability nobody can reach without first being told to flip a
    // hidden setting may as well not exist, and every one of these is a feature a client
    // wants: pinning, stickers, Send Later, polls, app balloons, wallpaper, the full alert
    // and contact-card shapes.
    //
    // The two groups that genuinely should not ship are gated where the gate belongs, in
    // `#if DEBUG` inside their own definitions rather than behind a runtime switch anyone
    // holding an admin token could flip: `AdditiveRoutes.security` (which edits who may talk
    // to this server) and the FaceTime debug diagnostics. Those stay compiled out.
    groups.append(AdditiveRoutes.security)
    // The richer alert shape. Additive because v1's is frozen at the reference's six
    // keys; this is where the full alert shape becomes reachable.
    groups.append(AdditiveRoutes.alerts)
    // A second way to get an avatar the contact payload already carries.
    groups.append(AdditiveRoutes.contactAvatar)
    // Pinning: a helper capability the Node server never had a route for.
    groups.append(AdditiveRoutes.chatPinning)
    // Stickers: likewise, a send the Node helper never had an action for.
    groups.append(AdditiveRoutes.stickers)
    // The sticker library. Reads need no helper: the store is a SQLite file.
    groups.append(AdditiveRoutes.stickerLibrary)
    // Send Later: Apple's scheduling, distinct from this server's own timer.
    groups.append(AdditiveRoutes.sendLater)
    // Polls, macOS 26.
    groups.append(AdditiveRoutes.polls)
    // Any iMessage app's balloon, Game Pigeon included.
    groups.append(AdditiveRoutes.appMessages)
    // Editing a webhook, which the Node server only ever exposed to its own UI.
    groups.append(AdditiveRoutes.webhookEditing)
    // Conversation controls: wallpaper today, mute and filtering next.
    groups.append(AdditiveRoutes.chatControls)
    // The shared contact card, with the handle and shared-state v1 cannot carry.
    groups.append(AdditiveRoutes.contactCard)

    // Feature flags, each independently off by default. Unlike v2 as a whole, these are
    // about a capability not being ready to be reachable at all, rather than about which
    // prefix it lives under.
    if features.contains(Features.findMy.id) {
      groups.append(AdditiveRoutes.findMy)

      // Nested rather than parallel: the sharing routes sit under the same prefix and
      // are meaningless without the status route to tell a client whether FindMy works
      // at all. Both flags have to be on.
      if features.contains(Features.findMyLocationSharing.id) {
        groups.append(AdditiveRoutes.findMySharing)
      }
    }

    // FaceTime, same structure: the incoming-call flow is nested under the enhanced flag
    // because it shares the prefix and is meaningless without the rest.
    // Settings, not feature flags: FaceTime is a capability a user turns on, the same
    // way they turn on the Messages Private API.
    if faceTime {
      groups.append(AdditiveRoutes.faceTime)
      // Nested: the incoming flow shares the prefix and is meaningless without the rest.
      if faceTimeIncoming {
        groups.append(AdditiveRoutes.faceTimeIncoming)
      }
    }

    if authMode != .password {
      groups.append(AdditiveRoutes.auth)
    }
    // Hydration is only meaningful to a client on reference-v2 or sealed-v2. On a
    // legacy-only server nobody can call it, so it does not exist.
    if codecs.serverPreference != .legacyV1 {
      groups.append(AdditiveRoutes.hydration)
    }
    return groups
  }

  static func buildHandlers(
    context: AppContext,
    authMode: AuthMode,
    codecs: CodecNegotiator,
    additionalGroups: [RouteGroup] = [],
    logSink: FileSink? = nil,
    logger: Logger? = nil
  ) async -> HandlerRegistry {
    var registry = HandlerRegistry()

    CoreHandlers.register(into: &registry, context: context)
    LandingHandlers.register(into: &registry, context: context)
    FindMyHandlers.register(into: &registry, context: context)
    FaceTimeHandlers.register(into: &registry, context: context)
    ReadHandlers.register(into: &registry, context: context)
    WriteHandlers.register(into: &registry, context: context)
    AdminHandlers.register(into: &registry, context: context)
    ContactHandlers.register(into: &registry, context: context)
    ScheduleHandlers.register(into: &registry, context: context)
    SystemHandlers.register(into: &registry, context: context, logSink: logSink)
    MediaHandlers.register(into: &registry, context: context)
    StickerHandlers.register(into: &registry, context: context)
    PushHandlers.register(into: &registry, context: context)
    UploadHandlers.register(into: &registry, context: context)
    UpdateHandlers.register(into: &registry, context: context)
    SecurityHandlers.register(into: &registry, context: context)
    if authMode != .password {
      AuthHandlers.register(into: &registry, context: context)
    }
    if codecs.serverPreference != .legacyV1 {
      HydrationHandlers.register(into: &registry, context: context)
    }

    // Everything the interfaces layer has not reached yet is mounted and answers 501.
    //
    // The alternative (letting `buildRouter` refuse to start) would be defensible and
    // useless: the server could not run until all 107 controllers existed. Mounting them
    // with the truthful status keeps the gap measurable instead of hiding it behind a
    // 404 that looks like a missing route.
    let unimplemented = PlaceholderHandlers.fill(
      into: &registry, groups: RouteTable.alwaysMounted + additionalGroups
    )
    if !unimplemented.isEmpty {
      logger?.warning(
        "Endpoints not yet implemented",
        metadata: [
          "handlers": .string(unimplemented.map(\.rawValue).sorted().joined(separator: ",")),
          "count": .stringConvertible(unimplemented.count),
          "of": .stringConvertible(
            RouteTable.groups.flatMap(\.routes).count
              + additionalGroups.flatMap(\.routes).count),
        ])
    }
    return registry
  }

  // MARK: - Helpers

  /// The whole policy, not just the on/off switch.
  ///
  /// `rate_limit_failures` and `rate_limit_block_seconds` were declared, rendered in the
  /// Security section, and read by nothing, so moving either slider changed no behaviour.
  static func accessPolicy(from settings: SettingsStore) async -> AccessControlPolicy {
    var policy = AccessControlPolicy()
    policy.isEnabled = await settings.get(Settings.rateLimitEnabled)
    policy.perClientThreshold = max(1, await settings.get(Settings.rateLimitFailureThreshold))
    policy.baseLockout = .seconds(max(1, await settings.get(Settings.rateLimitBlockSeconds)))
    // Kept above the base so escalation has somewhere to go, whatever the operator set.
    policy.maximumLockout = max(policy.baseLockout, .seconds(86_400))
    return policy
  }

  /// Who is allowed to set `X-Forwarded-For`, from `trusted_proxies`.
  ///
  /// Loopback is always included and cannot be configured away: the managed ngrok,
  /// cloudflared, zrok and tailscaled processes all connect over it, and dropping it would
  /// make every
  /// tunnelled client unattributable.
  static func proxyTrust(from settings: SettingsStore) async -> ProxyTrustPolicy {
    var trust = ProxyTrustPolicy()
    let declared = await settings.get(Settings.trustedProxies)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    trust.trustedProxies.formUnion(declared)
    return trust
  }
}

/// An assembled server, not yet started.
public struct RunningServer: Sendable {
  public let context: AppContext
  /// The file the server is logging to. Held so the app's log viewer can tail it without
  /// re-deriving the path, and so a test can point both at the same temporary file.
  public let logSink: FileSink?
  public let registry: ServiceRegistry<AppContext>
  /// Routes settings writes to the services that watch them. Held for its lifetime: it
  /// owns a subscription task, and dropping it would silently stop config propagation.
  public let propagation: SettingsPropagation
  public let handlers: HandlerRegistry
  public let routeGroups: [RouteGroup]
  public let options: ServerComposition.Options
  let logger: Logger

  /// Starts everything, in dependency order.
  public func start() async throws {
    // Mount checked before anything starts. A route in the table with no handler is a
    // hard failure here rather than a 404 at runtime that looks like a client bug.
    // Checked across the WHOLE table, not just the additive groups: the core table is the
    // part with ~90 routes in it.
    let missing = handlers.missing(for: RouteTable.groups + routeGroups)
    if !missing.isEmpty {
      logger.error(
        "Route handlers are missing",
        metadata: [
          "handlers": .string(missing.map(\.rawValue).joined(separator: ", "))
        ])
      throw HTTPMountError.unregisteredHandlers(missing)
    }

    // Subscribed BEFORE the services start. A service that writes a setting during its
    // own startup (the proxy publishing its address is the live example) must not do
    // it into a stream nobody is reading yet.
    await propagation.start()

    // Anything a previous process left running. Before the proxies start, so the port
    // and the tunnel an orphan holds are free by the time the replacement asks.
    DaemonLedger.shared.reapOrphans(logger: logger)

    try await registry.startAll()
    logger.info("Server started")
  }

  /// Stops everything, in exactly the reverse of the start order.
  public func stop() async {
    await propagation.stop()
    // Before the sinks stop: a FindMy position held by the rate limiter is the newest one
    // there is, and it can only reach a socket that is still open.
    await context.events.flushPending()
    await registry.stopAll()
    logger.info("Server stopped")
  }
}

// MARK: - Adapters

/// Where chat.db lives.
public enum ChatDatabase {
  static var defaultPath: String {
    NSHomeDirectory() + "/Library/Messages/chat.db"
  }
}

/// Reads a YAML/env config file, if one is present.
public enum ConfigFile {
  /// Absent is normal: most installs configure through the UI. Returning empty rather
  /// than failing means "no config file" is not an error.
  static func load(at path: String?) -> [String: String] {
    let resolved = path ?? NSHomeDirectory() + "/bluebubbles.yml"
    guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
      return [:]
    }

    // Deliberately a `key: value` reader rather than a YAML parser. The file exists for
    // headless and container deployments to set a handful of scalars; supporting nested
    // YAML would mean a dependency and a schema for something nothing needs.
    var values: [String: String] = [:]
    for line in contents.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      let parts = trimmed.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      values[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
        String(parts[1])
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return values
  }
}

/// Bridges BBSettings' secret store to the narrow protocol BBAuth declares.
///

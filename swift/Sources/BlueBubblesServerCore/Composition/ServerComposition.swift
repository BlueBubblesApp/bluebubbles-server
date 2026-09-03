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
//       no helper — it still comes up, so the user can reach the UI and fix it. A server that
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

  /// Builds every long-lived object and returns the assembled server.
  public static func build(options: Options = Options()) async throws -> RunningServer {
    // Bootstrapped before anything else logs, and to the SAME path the Electron server
    // uses — an operator debugging a migrated install should find one log file where
    // they expect it, not two. Held so `GET /server/logs` can tail it: without the sink,
    // that route has nothing to read and a client's log viewer goes blank.
    let logSink = LoggingSystemBootstrap.bootstrap(level: options.logLevel)
    let logger = Logger(label: "bluebubbles")

    // MARK: Storage
    let appDatabase = try AppDatabase.open(contributors: AppSchema.contributors)
    let secrets = KeychainSecretStore()
    let settings = try await SettingsStore(
      database: appDatabase,
      secrets: secrets,
      configFileValues: ConfigFile.load(at: options.configPath),
      commandLineValues: options.overrides
    )

    // Raised to whatever the user asked for, as soon as the store can answer.
    //
    // After the store rather than at bootstrap, because the level LIVES in the store — the
    // handful of lines logged before this point are start-up chatter at the default level.
    // Without this the setting is read by nothing, so turning on debug logging does nothing
    // and gives no hint why.
    LoggingSystemBootstrap.setLevel(
      Settings.logLevel(from: await settings.get(Settings.logLevel))
    )

    // Bring an Electron install's settings across, once, before anything reads one.
    //
    // Without this call an upgrading user's port, password, proxy provider, ngrok key and
    // tunnel configuration are all silently discarded — the server comes up on defaults, on
    // a different port, with no password, and nothing says why. It reads `config.db`
    // READ-ONLY and never touches the Electron server's copy, so running both during a
    // transition is safe.
    //
    // Ordered here deliberately: after the store exists, before any service reads a
    // setting. Migrating later would have services configured from defaults and then
    // silently disagreeing with what the settings screen shows.
    await Self.migrateLegacyConfiguration(into: settings, secrets: secrets, logger: logger)

    // Then each service's own migrations, in the same window and for the same reason: a
    // service that reads its settings before they have been moved configures itself from
    // the old shape and never looks again.
    // Validated BEFORE migrations run, because a migration is described by the same
    // manifest: applying one from a manifest that has not been checked would be acting on
    // untrusted instructions about where someone's data should go.
    let validated = await ServiceSettingsBridge.validate(
      manifests: BuiltInManifests.all,
      enabled: [ServiceIdentifier(await settings.get(Settings.connectionMethod))],
      logger: logger,
      // No alert centre yet — it is constructed further down, after storage. A conflict
      // found here is logged and re-raised once the centre exists rather than being
      // dropped; see `SettingsPropagation`, which re-validates on a settings change.
      alerts: nil
    )
    await ServiceSettingsBridge.prepare(
      manifests: validated, store: settings, logger: logger
    )

    // MARK: chat.db
    //
    // Optional, and that is the point. Without Full Disk Access there is no database to
    // open — and the server must still start, or the user cannot reach the permissions
    // page that would fix it.
    var chatDatabase: ReadOnlyDatabase?
    var schemaProfile: SchemaProfile?
    var messages: MessageRepository?
    var serializer: MessageSerializer?

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
      chatDatabase = database
      schemaProfile = profile
      messages = MessageRepository(database: database, profile: profile)
      serializer = MessageSerializer(profile: profile)
      logger.info(
        "Opened chat.db",
        metadata: [
          "dateUnit": .string(String(describing: profile.dateUnit)),
          "readers": .stringConvertible(database.readerCount),
          // What it OPENED with, not what was asked for: a pool that could not open falls
          // back to one connection, and a setting that silently did nothing is worse than
          // one that did nothing loudly.

        ])
    } catch {
      // Reported, not fatal.
      logger.warning(
        "chat.db is not readable; the read path is unavailable",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }

    // MARK: Cross-cutting
    let alerts = AlertCenter()
    // Attached before anything can raise, so an alert from start-up — the likeliest moment
    // for one — is stored rather than being the one that gets lost. Restoring happens here
    // too: what comes back is what was unread and undismissed within the retention window,
    // with live-condition alerts restored already-read so a problem that cleared while the
    // server was down does not greet the user as current.
    await alerts.attach(store: AlertRepository(database: appDatabase))

    // The settings store is built before this point, so a Keychain failure during
    // start-up — the likeliest moment for one, and the one that decides whether the
    // server can authenticate at all — has nowhere to be reported until now. Attaching
    // drains anything already held.
    await settings.attachAlerts(alerts)
    let permissions = PermissionsService(
      onChange: { id, from, to in
        // A permission revoked after setup — which happens on OS upgrades — is
        // reported when it breaks rather than surfacing later as odd failures.
        guard from == .granted, to != .granted else { return }
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
    let contacts = ContactIndex(database: appDatabase)

    // MARK: Codecs
    //
    // Registered, but the ceiling defaults to legacy-v1 — so a client advertising
    // sealed-v2 still gets legacy-v1 until an operator raises it. Built to be switchable,
    // not switched.
    let codecPreference = await settings.get(Settings.eventPayloadCodec)
    let codecs = CodecNegotiator.full(preference: CodecIdentifier(codecPreference.rawValue))

    // MARK: Token auth
    //
    // Under `auth_mode = password` this constructs nothing: no signing key, no device
    // store, no bearer scheme.
    let authMode = await settings.get(Settings.authMode)
    let tokenAuth = TokenAuthService(
      configuration: TokenAuthConfiguration(mode: authMode),
      secrets: authMode == .password ? nil : secrets
    )

    let events = EventBus()

    // MARK: Socket
    //
    // The auth chain is a CLOSURE rather than a value, so a handshake is checked against
    // the password as it is now. Capturing a chain here would keep authenticating
    // against whatever the password was at launch, and a password change would not lock
    // anybody out until the process restarted — the opposite of what changing it means.
    // Hashed once, not once per request. `SettingsPropagation` clears it when `password`
    // is written, so the "checked against the password as it is now" property above still
    // holds — see PasswordDigest.swift for why only successful reads are cached.
    let passwordDigests = PasswordDigestCache(
      load: { await settings.secret(Settings.password) }
    )

    let socketServer = SocketServer(negotiator: codecs)
    let engineIO = EngineIOServer(
      server: socketServer,
      chain: { [tokenAuth] in
        await tokenAuth.chain(
          passwordProvider: { await passwordDigests.digest() }
        )
      }
    )

    // Decided before the context is built, because the HTTP service mounts them and is
    // constructed by the registry with nothing but a context to read from.
    let additionalGroups = await routeGroups(
      authMode: authMode,
      codecs: codecs,
      additiveEndpoints: await settings.get(Settings.additiveEndpoints),
      features: Set(
        await settings.featureStates().filter(\.value).keys.map(\.id)
      ),
      faceTime: await settings.get(Settings.enableFaceTimePrivateAPI),
      faceTimeIncoming: await settings.get(Settings.faceTimeIncomingHandoff)
    )

    let context = AppContext(
      appDatabase: appDatabase,
      chatDatabase: chatDatabase,
      settings: settings,
      secrets: secrets,
      schemaProfile: schemaProfile,
      messages: messages,
      contacts: contacts,
      serializer: serializer,
      events: events,
      codecs: codecs,
      socketServer: socketServer,
      engineIO: engineIO,
      additionalRouteGroups: additionalGroups,
      permissions: permissions,
      accessControl: accessControl,
      tokenAuth: tokenAuth,
      passwordDigests: passwordDigests,
      // Registered with every manifest below, so a tool is known to the manager because
      // a service declared it — not because this file lists it a second time.
      tools: ToolManager(
        alerts: alerts,
        // The bundled copy stays a fallback rather than being removed: a build that
        // does ship binaries in `Contents/Resources/bin` keeps working, and an
        // offline first run has something to fall back to.
        bundledLocator: { BundledBinaries.path(for: $0) },
        logger: logger
      ),
      alerts: alerts,
      logger: logger
    )

    // MARK: Registry
    let registry = ServiceRegistry(
      host: context,
      permissionCheck: await permissions.permissionCheck(),
      // What the Integrations screen's switches actually DO. Before this they wrote
      // `disabled_services` and nothing read it: a webhook endpoint kept receiving
      // every event after being switched off, and the only place the setting had any
      // effect was the "enabled" tag next to it.
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
    await context.finishWiring(
      registry: registry,
      handlers: buildHandlers(
        context: context,
        authMode: authMode,
        codecs: codecs,
        additionalGroups: additionalGroups,
        logSink: logSink,
        logger: logger
      )
    )

    // Every tool any service declares, in one registry. Derived from the manifests so a
    // program the server can install is exactly a program some service said it needs —
    // and so a third-party connection method's binary is managed by the same code that
    // manages ngrok's, with no list here to add itself to.
    await context.tools.register(BuiltInManifests.all)

    // Order is DERIVED from these declarations, not from the order they appear here.
    await registry.register(PermissionsMonitorService.self)
    await registry.register(ContactsService.self)
    await registry.register(ChangeDetectionService.self)
    await registry.register(HTTPService.self)
    await registry.register(SocketService.self)
    await registry.register(PrivateAPIGatedService.self)
    await registry.register(PushDeliveryService.self)
    await registry.register(WebhookDeliveryService.self)
    await registry.register(ScheduledMessageService.self)
    // Five connection methods, one exclusive category: all register, and `canRun` lets
    // exactly the selected one through. This is what makes a third-party tunnel possible
    // — it joins a category rather than adding a case to an enum.
    await registry.register(ProxyService<LANMethod>.self)
    await registry.register(ProxyService<DynamicDNSMethod>.self)
    await registry.register(ProxyService<NgrokMethod>.self)
    await registry.register(ProxyService<CloudflareMethod>.self)
    await registry.register(ProxyService<ZrokMethod>.self)
    await registry.register(SleepPreventionService.self)
    await registry.register(LaunchAtLoginService.self)
    await registry.register(ToolUpdateService.self)

    return RunningServer(
      context: context,
      logSink: logSink,
      registry: registry,
      // Constructed here rather than inside `start()` so the whole graph is visible in
      // one place, and so a test can drive it without standing up a listener.
      propagation: SettingsPropagation(
        settings: settings, registry: registry, accessControl: accessControl,
        // The tunnel writes `server_address` and this is what turns that write into
        // something clients hear about — a `new-server` frame now, and a Firebase
        // document for the ones that are not connected.
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
                + "up. Restarting applies it — connected clients reconnect on "
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
      ),
      handlers: await context.httpHandlers,
      routeGroups: additionalGroups,
      options: options,
      logger: logger
    )
  }

  /// Imports the Electron server's `config.db`, once.
  ///
  /// **Guarded by a marker, because the import is not idempotent.** It writes every key it
  /// finds without comparing against the current value, so an unguarded call would re-run on
  /// every launch and overwrite whatever the user had since changed in the Swift app with
  /// the value the old server happened to have. The marker is set only after a successful
  /// run, so a failure part-way retries next launch rather than stranding a half-migrated
  /// configuration.
  ///
  /// A failure is logged and swallowed: a server that refuses to start because an old
  /// database was unreadable is a worse outcome than one that starts on defaults, and the
  /// user can still configure it by hand.
  static func migrateLegacyConfiguration(
    into settings: SettingsStore,
    secrets: any SecretStore,
    logger: Logger
  ) async {
    guard await !settings.get(Settings.legacyConfigImported) else { return }

    let migration = LegacyConfigMigration()
    guard migration.hasLegacyDatabase() else { return }

    do {
      let result = try await migration.run(into: settings, secrets: secrets)
      // Set even when nothing was imported: an empty legacy database is still a
      // database we have now read, and re-reading it every launch buys nothing.
      await settings.trySet(Settings.legacyConfigImported, to: true)
      guard !result.imported.isEmpty || !result.secretsMoved.isEmpty else { return }

      logger.info(
        "Imported settings from the Electron server",
        metadata: [
          "imported": .stringConvertible(result.imported.count),
          "secretsMoved": .stringConvertible(result.secretsMoved.count),
          "skipped": .stringConvertible(result.skippedUnknown.count),
          "coercionFailures": .stringConvertible(result.coercionFailures.count),
        ])

      // Named individually, because a setting that failed to coerce is one the user
      // configured deliberately and now silently does not have.
      for failure in result.coercionFailures {
        logger.warning(
          "Could not import a setting",
          metadata: [
            "key": .string(failure.key),
            "expected": .string(failure.expected),
          ])
      }
    } catch {
      logger.warning(
        "Could not import settings from the Electron server",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
  }

  // MARK: - Routes

  /// The additive route groups, chosen by configuration.
  ///
  /// This is where "not registered" is enforced. A group absent from this array is absent
  /// from the router, and its paths 404 exactly like any unknown path.
  static func routeGroups(
    authMode: AuthMode,
    codecs: CodecNegotiator,
    additiveEndpoints: Bool = false,
    features: Set<String> = [],
    faceTime: Bool = false,
    faceTimeIncoming: Bool = false
  ) async -> [RouteGroup] {
    var groups: [RouteGroup] = []

    // Opt-in, and off by default. With default settings the route table has to be
    // identical to the Node server's — an added path is as much a difference as a
    // missing one, and a client probing for capabilities can see it.
    //
    // Rate limiting without an unblock path would be a real problem, but it is not this
    // one: `--clear-blocklist` recovers a lockout from the command line, and it works
    // without building the server precisely so it survives whatever broke the API.
    if additiveEndpoints {
      groups.append(AdditiveRoutes.security)
      // The richer alert shape. Additive because v1's is frozen at the reference's six
      // keys — this is where the full alert shape becomes reachable.
      groups.append(AdditiveRoutes.alerts)
      // A second way to get an avatar the contact payload already carries.
      groups.append(AdditiveRoutes.contactAvatar)
      // Pinning: a helper capability the Node server never had a route for.
      groups.append(AdditiveRoutes.chatPinning)
      // Stickers: likewise, a send the Node helper never had an action for.
      groups.append(AdditiveRoutes.stickers)
      // Send Later: Apple's scheduling, distinct from this server's own timer.
      groups.append(AdditiveRoutes.sendLater)
      // Polls, macOS 26.
      groups.append(AdditiveRoutes.polls)
      // Any iMessage app's balloon, Game Pigeon included.
      groups.append(AdditiveRoutes.appMessages)
      // Editing a webhook, which the Node server only ever exposed to its own UI.
      groups.append(AdditiveRoutes.webhookEditing)
      // Conversation controls — wallpaper today, mute and filtering next.
      groups.append(AdditiveRoutes.chatControls)
      // The shared contact card, with the handle and shared-state v1 cannot carry.
      groups.append(AdditiveRoutes.contactCard)
    }

    // Feature flags, each independently off by default. Separate from
    // `additiveEndpoints` on purpose: that switch is about matching the previous
    // server's route table, whereas these are about a capability not being ready to be
    // reachable. Conflating them would mean turning on the admin endpoints in order to
    // get FindMy, which is not a trade anyone should have to make.
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
    // The alternative — letting `buildRouter` refuse to start — would be defensible and
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
  /// Security section, and read by nothing — so moving either slider changed no behaviour.
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
  /// Loopback is always included and cannot be configured away: the bundled ngrok,
  /// cloudflared and zrok processes all connect over it, and dropping it would make every
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
  /// Routes settings writes to the services that watch them. Held for its lifetime — it
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
    // Checked across the WHOLE table, not just the additive groups. Checking only the
    // additive ones was the bug this replaced: the core table is the part with ~90
    // routes in it, and it was the part going unverified.
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
    // own startup — the proxy publishing its address is the live example — must not do
    // it into a stream nobody is reading yet.
    await propagation.start()

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
  /// Absent is normal — most installs configure through the UI. Returning empty rather
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

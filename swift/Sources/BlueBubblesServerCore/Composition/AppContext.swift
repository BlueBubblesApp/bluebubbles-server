//  AppContext
//  The dependency container, and what replaces the `Server()` global.
//
//  The current implementation reaches through a `Server()` singleton **530 times across 70
//  files**. Every one of those is an undeclared dependency: nothing states what a component
//  needs, so nothing can be constructed without constructing everything, and nothing can be
//  tested without a running server.
//
//  This is the one place that knows how the parts fit together. Everything below it takes
//  what it needs as a parameter.
//
//  See `.claude/docs/architecture.md`.

import BBAuth
import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBPersistence
import BBPrivateAPI
import BBPrivateAPIContract
import BBProxy
import BBPushKit
import BBSerialization
import BBServiceKit
import BBSettings
import BBShortcuts
import BBSocketIO
import BBSystem
import BBTooling
import Foundation
import GRDB
import Logging

/// Everything long-lived, assembled once.
///
/// An actor because the services reach into it concurrently, and because `lastClientActivity`
/// is written by the HTTP layer on every request while the proxy's refresh timer reads it.
///
/// The service references below are `nonisolated let`: immutable bindings to types that are
/// already Sendable (actors, or value types over their own synchronisation). Isolating them
/// would protect nothing — there is no mutable state behind the binding — while costing an
/// actor hop at every call site, including one per row of the settings screen. Only the
/// genuinely mutable state below is isolated.
public actor AppContext {

  // Storage
  public nonisolated let appDatabase: AppDatabase
  public nonisolated let chatDatabase: ReadOnlyDatabase?
  public nonisolated let settings: SettingsStore
  public nonisolated let secrets: any SecretStore

  // Domain
  public nonisolated let schemaProfile: SchemaProfile?
  public nonisolated let messages: MessageRepository?
  public nonisolated let contacts: ContactIndex
  public nonisolated let serializer: MessageSerializer?

  // Delivery
  public nonisolated let events: EventBus
  public nonisolated let codecs: CodecNegotiator
  /// Connected socket clients, and the Engine.IO sessions carrying them.
  ///
  /// Long-lived and built once: `HTTPService` mounts the transport on its listener and
  /// `SocketService` registers the event sink, so both need the same instance. Building it
  /// per service would give the broadcaster and the transport two different connection
  /// tables, and events would be written to sockets nobody is holding.
  public nonisolated let socketServer: SocketServer
  public nonisolated let engineIO: EngineIOServer

  /// The mounted route surface. Held here rather than passed into the service because it
  /// is decided by configuration at build time, and the service is constructed by the
  /// registry with nothing but a context.
  ///
  /// Assigned after construction rather than passed in, because the handlers close over
  /// this context — they need the message repository, the device registry, and the access
  /// control service. Injecting them would require building them first, which would
  /// require the context. `attach` is where that knot is untied, and it is the same shape
  /// as `attach(registry:)` below for the same reason.
  public private(set) var httpHandlers = HandlerRegistry()
  public nonisolated let additionalRouteGroups: [RouteGroup]

  // Cross-cutting
  public nonisolated let permissions: PermissionsService
  public nonisolated let accessControl: AccessControlService
  /// FindMy's in-memory state and its gates on reaching Apple.
  public nonisolated let findMy = FindMyRuntime()
  /// When a client last did anything. See `ClientActivityTracker`.
  public nonisolated let clientActivity = ClientActivityTracker()
  /// Serves attachments in formats clients can open, caching each conversion. See
  /// `AttachmentConversion` — HEIC and CAF are what iMessage stores and what most clients
  /// cannot display.
  public nonisolated let attachmentConversion = AttachmentConversion()
  /// Where uploaded bytes land before a send. A value over a directory; see `UploadStore`.
  public nonisolated let uploads = UploadStore()
  /// Machine facts for `server/info`, cached. See `SystemInfoProvider` — two of those
  /// fields are a network round trip and a database query, on a route every client polls.
  public nonisolated let systemInfo: SystemInfoProvider
  public nonisolated let tokenAuth: TokenAuthService
  /// Shared so the HTTP and socket chains hash the password ONCE between them, and so a
  /// `password` write invalidates both at the same moment.
  public nonisolated let passwordDigests: PasswordDigestCache
  /// The external programs services depend on — the tunnel binaries today.
  ///
  /// One per server rather than one per service, because two services wanting cloudflared
  /// should share an install rather than each keeping their own 38 MB copy. See
  /// `ToolManager`: it downloads, verifies and version-checks, and it never updates anything
  /// without being told to.
  public nonisolated let tools: ToolManager
  public nonisolated let alerts: AlertCenter
  public nonisolated let logger: Logger

  /// The macOS call log, opened on first use and then held.
  ///
  /// Lazy rather than built in `init` because most servers never ask for recents, and
  /// opening it eagerly would add a SQLite handle — and a Full Disk Access failure — to
  /// every start. `loaded` is separate from the value so a machine with NO call history
  /// (a real, non-error state) is not retried on every request.
  private var callHistoryRepository: CallHistoryRepository?
  private var callHistoryLoaded = false

  public func callHistory() async -> CallHistoryRepository? {
    if callHistoryLoaded { return callHistoryRepository }
    callHistoryLoaded = true
    do {
      callHistoryRepository = try await CallHistoryRepository()
    } catch {
      // Almost always Full Disk Access. Logged rather than thrown so recents degrade
      // to "empty" instead of failing the request with a SQLite error.
      logger.warning(
        "Could not open the macOS call log",
        metadata: [
          "error": .string(String(describing: error))
        ])
    }
    return callHistoryRepository
  }

  /// Services, once the registry has built them. Populated by the registry rather than
  /// here, which is what keeps this from being a second construction path.
  private var registry: ServiceRegistry<AppContext>?
  /// The `new-server` announcer. Built on first use; it needs `events` and `logger`.
  private var addressAnnouncer: ServerAddressAnnouncer?

  /// The interfaces layer.
  ///
  /// Built lazily and cached rather than constructed per request: each one is a value type
  /// over the same repositories, so building one is cheap, but the Private API reference
  /// they close over is only available after the service registry has started. Reading
  /// them through here is what lets a controller stay two lines long.
  ///
  /// This is the layer `.claude/docs/api.md` calls for — shared verbatim by the HTTP
  /// routes, the legacy socket commands, and the SwiftUI app. Sharing it is what makes the
  /// current implementation's 68 IPC channels unnecessary.
  private var cachedInterfaces: Interfaces?
  /// The push delivery object, once the push service has started it.
  ///
  /// A `PushService` — a BBPushKit type — rather than a lookup of `PushDeliveryService`.
  /// Reaching for the concrete SERVICE made the container depend on the services that depend
  /// on it, which is a cycle the single-target build hides and a module split would not. The
  /// service hands over what it owns; this holds a reference to a type it already depends on.
  private var pushDelivery: PushService?

  /// Set once the Private API service is running. Nil is a normal state, not a failure:
  /// the Private API is an enhancement and AppleScript covers the send path without it.
  private var privateAPI: (any PrivateAPI)?
  /// `private(set)` rather than `private` so a test can assert it was published. It went
  /// unpublished for the life of the project precisely because nothing could look.
  private(set) var contactsIngestor: ContactsIngestor?
  /// Group chat creation without the Private API.
  ///
  /// Owned here rather than constructed per interface because it caches whether the user's
  /// shortcut is currently installed, and that reading should be shared — the settings page
  /// and a `chat.create` arriving at the same moment must not disagree about it, and each
  /// fresh instance would spawn its own `shortcuts list` subprocess.
  private let groupChatShortcutsBacking = GroupChatShortcutManager()
  /// Set by the hosting application when one exists. Nil headless, which is a supported
  /// configuration rather than a failure — see UpdateHandlers.
  private var updateInstallerBacking: (any UpdateInstalling)?

  /// Kept as a nested name so existing call sites read the same.
  public typealias Interfaces = ServerInterfaces

  init(
    appDatabase: AppDatabase,
    chatDatabase: ReadOnlyDatabase?,
    settings: SettingsStore,
    secrets: any SecretStore,
    schemaProfile: SchemaProfile?,
    messages: MessageRepository?,
    contacts: ContactIndex,
    serializer: MessageSerializer?,
    events: EventBus,
    codecs: CodecNegotiator,
    socketServer: SocketServer,
    engineIO: EngineIOServer,
    additionalRouteGroups: [RouteGroup],
    permissions: PermissionsService,
    accessControl: AccessControlService,
    tokenAuth: TokenAuthService,
    passwordDigests: PasswordDigestCache,
    tools: ToolManager,
    alerts: AlertCenter,
    logger: Logger
  ) {
    self.appDatabase = appDatabase
    self.chatDatabase = chatDatabase
    self.settings = settings
    self.secrets = secrets
    self.schemaProfile = schemaProfile
    self.messages = messages
    self.systemInfo = SystemInfoProvider(messages: messages, logger: logger)
    self.contacts = contacts
    self.serializer = serializer
    self.events = events
    self.codecs = codecs
    self.socketServer = socketServer
    self.engineIO = engineIO
    self.additionalRouteGroups = additionalRouteGroups
    self.permissions = permissions
    self.accessControl = accessControl
    self.tokenAuth = tokenAuth
    self.passwordDigests = passwordDigests
    self.tools = tools
    self.alerts = alerts
    self.logger = logger
  }

  /// Closes the construction cycle, once.
  ///
  /// The registry and the handlers cannot be constructor-injected and this is why: the
  /// handlers close over this context — they need the message repository, the device
  /// registry, the access-control service — so building them first would require the
  /// context to exist first. The knot is untied here instead.
  ///
  /// ONE method rather than the two `attach` calls it replaces, because they were always
  /// made together, immediately after one another, and nothing checked that either had
  /// happened. Two independent late-binding points that must both fire is two chances to
  /// fire only one. `isWired` below is what turns "somebody remembered" into something a
  /// test can assert — see `AppContextWiringTests`.
  func finishWiring(registry: ServiceRegistry<AppContext>, handlers: HandlerRegistry) {
    self.registry = registry
    self.lifecycle = ServerLifecycle(registry: registry, logger: logger)
    self.httpHandlers = handlers
    self.isWired = true
  }

  /// Whether `finishWiring` has run.
  ///
  /// A context that skipped it looks healthy and fails obscurely later: no service can be
  /// looked up, no route has a controller, and the failure surfaces as a 404 or a nil
  /// service rather than as "this was never assembled".
  public private(set) var isWired = false

  /// FaceTime link bookkeeping, hand-off tracking and cleanup.
  ///
  /// A subsystem with its own state rather than more wiring, so it is its own type. Built
  /// lazily and held, because it must be ONE instance: the ledger it owns is the only
  /// record of which links this server minted, and a second coordinator would clean up
  /// against an empty one and leave every real link behind.
  private var faceTimeBacking: FaceTimeCoordinator?

  /// This Mac's own iMessage address, for the Shortcut test send. Nil when unknown.
  public func ownMessagingAddress() async -> String? {
    guard let messages else { return nil }
    return try? await messages.ownAddress()
  }

  /// The group chat Shortcut, for the settings page that installs and tests it.
  ///
  /// The same instance `ChatInterface` uses, so a status the user just refreshed on the
  /// settings page is the status the next `chat.create` acts on.
  public func groupChatShortcuts() -> GroupChatShortcutManager { groupChatShortcutsBacking }

  public func faceTime() -> FaceTimeCoordinator {
    if let faceTimeBacking { return faceTimeBacking }
    let coordinator = FaceTimeCoordinator(
      settings: settings,
      // Resolved per call, not captured: the helper connects and drops while the server
      // runs, and a reference taken now would be stale after the next helper restart.
      privateAPI: { [weak self] in await self?.privateAPIClient() },
      logger: logger
    )
    faceTimeBacking = coordinator
    return coordinator
  }

  /// Restarting Messages or FaceTime with the helper re-injected. Built on first use, like
  /// `faceTime()`, and for the same reason: most servers never do this.
  private var applicationRestartBacking: ApplicationRestartCoordinator?

  public func applicationRestart() -> ApplicationRestartCoordinator {
    if let applicationRestartBacking { return applicationRestartBacking }
    let coordinator = ApplicationRestartCoordinator(
      privateAPIRuntime: { [weak self] in await self?.privateAPIRuntime },
      logger: logger
    )
    applicationRestartBacking = coordinator
    return coordinator
  }

  /// The Private API runtime, when the server manages injection.
  ///
  /// Held so the restart endpoints can relaunch an app WITH its helper inserted. Restarting
  /// Messages without injection silently drops the Private API: the app comes back looking
  /// healthy while every Private API route reports the helper as unavailable.
  public private(set) var privateAPIRuntime: PrivateAPIRuntime?

  func publish(pushDelivery: PushService) {
    self.pushDelivery = pushDelivery
    clientActivity.setForwarder { await pushDelivery.noteClientActivity() }
  }

  func withdrawPushDelivery() {
    self.pushDelivery = nil
    clientActivity.setForwarder(nil)
  }

  /// Publishes the Private API — the connection AND the process control — together.
  ///
  /// One call rather than two, and that is a fix rather than a tidy-up. They were set by two
  /// `attach` calls and cleared by two more, and in `stop()` the two clears sat either side
  /// of `runtime.stop()`: for the length of that await the runtime was already nil while the
  /// client was still published, so `isHelperConnected` could answer "yes" for a helper that
  /// was being torn down. Setting both under one actor-isolated call closes that window.
  ///
  /// Invalidates the interface cache, because an interface built before the helper connected
  /// holds a nil reference and would go on reporting the Private API as unavailable for the
  /// life of the process — exactly the bug where a working helper looks broken.
  func publishPrivateAPI(client: any PrivateAPI, runtime: PrivateAPIRuntime?) {
    self.privateAPI = client
    self.privateAPIRuntime = runtime
    self.cachedInterfaces = nil
  }

  /// Withdraws both halves at once. See `publishPrivateAPI`.
  func withdrawPrivateAPI() {
    self.privateAPI = nil
    self.privateAPIRuntime = nil
    self.cachedInterfaces = nil
  }

  /// The address-book reader, published by `ContactsService` once it exists.
  ///
  /// Its OWN call, deliberately — not an optional parameter on the Private API publication.
  /// The two have nothing to do with one another, the Private API call sites have no
  /// ingestor to pass, and a defaulted argument means leaving it out compiles:
  /// `ContactInterface.refresh` then runs with a nil ingestor for the life of the process and
  /// answers "contact access has not been granted to this server" on servers where it has.
  /// A separate call is what makes forgetting it visible.
  func publish(contactsIngestor ingestor: ContactsIngestor) {
    self.contactsIngestor = ingestor
    self.cachedInterfaces = nil
  }

  /// The interfaces, or nil when chat.db is not readable.
  ///
  /// Nil rather than a half-built set: every interface here reads the message database,
  /// and handing back one that cannot would move the failure from a clear "no access" to a
  /// confusing empty result on every route.
  public func interfaces() -> Interfaces? {
    if let cachedInterfaces { return cachedInterfaces }
    guard let messages, let serializer else { return nil }

    let built = ServerInterfaces(
      message: MessageInterface(
        repository: messages, serializer: serializer, privateAPI: privateAPI
      ),
      chat: ChatInterface(
        repository: messages, serializer: serializer, privateAPI: privateAPI,
        shortcuts: groupChatShortcutsBacking
      ),
      handle: HandleInterface(repository: messages, privateAPI: privateAPI),
      attachment: AttachmentInterface(repository: messages, privateAPI: privateAPI),
      contact: ContactInterface(index: contacts, ingestor: contactsIngestor)
    )
    cachedInterfaces = built
    return built
  }

  /// Server administration: alerts, totals, webhooks and backups.
  ///
  /// NOT part of `ServerInterfaces`, and this is a fix rather than a tidy-up. That bundle
  /// is nil whenever chat.db is unreadable, so every screen and route reached through it
  /// was gated on Full Disk Access — including the webhooks page, which has nothing to do
  /// with the message database. `messages` is optional here and the counts are the only
  /// thing that needs it, so the rest works without it.
  ///
  /// A value type over the same storage, so building one per call costs nothing.
  public nonisolated var server: ServerInterface {
    ServerInterface(
      database: appDatabase, alerts: alerts, settings: settings, messages: messages
    )
  }

  /// Scheduled messages. Out of the bundle for the same reason `server` is: scheduling
  /// touches only the app database, and `AdminHandlers` and `ScheduleHandlers` were each
  /// rebuilding their own interface to get around the chat.db gate.
  public nonisolated var schedule: ScheduleInterface {
    ScheduleInterface(database: appDatabase)
  }

  /// Firebase setup.
  ///
  /// NOT part of `Interfaces`, deliberately. That set is nil whenever chat.db is unreadable,
  /// and push setup is one of the few things a user can usefully do on a server that has
  /// not been granted Full Disk Access yet — tying it to the message database would hide
  /// the notifications screen behind an unrelated permission.
  ///
  /// Built per call rather than cached: `service` returns nil until the registry has
  /// started push, so a cached instance built during startup would hold a nil service for
  /// the lifetime of the process and report "push is not running" forever.
  public func pushInterface() async -> PushInterface {
    PushInterface(
      credentials: PushCredentialStore(secrets: secrets),
      settings: settings,
      service: pushDelivery,
      deviceTokens: { [weak self] in await self?.deviceDirectory.tokens() ?? [] },
      reloadPush: { [weak self] in
        // Through the REGISTRY, not through the service instance, and the difference
        // is the whole setup flow. A server that started with no Firebase credentials
        // has no push service at all — the gate declined and nothing was constructed —
        // so there is no instance to reload, and asking one to reload itself would be
        // a no-op on exactly the install that just finished setting push up. Restarting
        // through the registry re-runs the gate, which now sees credentials.
        await self?.restartPushService()
      },
      clearDevices: { [weak self] in await self?.deviceDirectory.removeAll() },
      logger: logger
    )
  }

  /// Rebuilds the push service from the credentials as they are now.
  ///
  /// Deliberately `restart` rather than `restartWithDependents`: nothing depends on push,
  /// and taking the socket or the tunnel down because someone imported a Firebase key would
  /// disconnect every client mid-setup.
  func restartPushService() async {
    await lifecycle?.restartPush()
  }

  /// What `server/info` reports as `proxy_service`.
  ///
  /// The wire value stays the SHORT name — `cloudflare`, `ngrok` — even though the setting
  /// now holds a service identifier. Clients have branched on those strings for years and
  /// the compatibility contract is strict in both directions, so the internal model
  /// changing must not change what goes out.
  public func connectionMethodName() async -> String {
    ServiceIdentifier(await settings.get(Settings.connectionMethod)).shortName
  }

  /// A service's settings, narrowed to what its manifest declares.
  ///
  /// Built per call rather than cached: it is a value type over the store, so building one
  /// costs nothing, and caching would mean a manifest change needing a restart to take
  /// effect for no reason.
  public nonisolated func scopedSettings(for manifest: ServiceManifest) -> ScopedSettings {
    ScopedSettings(store: settings, manifest: manifest, secretKeys: Settings.secretKeys)
  }

  public var updateInstaller: (any UpdateInstalling)? { updateInstallerBacking }

  /// Whether an injected helper is currently connected.
  ///
  /// Distinct from `enable_private_api`, which is only what the user asked for. A client
  /// needs both: the setting says the feature is meant to work, this says it does.
  public var isHelperConnected: Bool {
    get async { await privateAPI?.isConnected ?? false }
  }

  /// Supplied by the hosting application, which owns the updater.
  ///
  /// **Nothing conforms to `UpdateInstalling` yet, so this is never called and
  /// `updateInstaller` is always nil.** The seam is real and the endpoint is written against
  /// it; what is missing is an implementation in the app. Until there is one,
  /// `server.installUpdate` refuses — see `UpdateHandlers`, whose message says so without
  /// claiming a reason it cannot know.
  public func setUpdateInstaller(_ installer: any UpdateInstalling) {
    self.updateInstallerBacking = installer
  }

  /// The Private API, if the helper is connected.
  ///
  /// Nil is a normal state: the Private API is an enhancement, and every caller here is
  /// expected to say so rather than treat it as a failure.
  public func privateAPIClient() -> (any PrivateAPI)? { privateAPI }

  /// The interfaces, or a 503 explaining why not.
  public func requireInterfaces() throws -> Interfaces {
    guard let interfaces = interfaces() else {
      throw ServiceUnavailable(
        "the iMessage database is not readable; grant this server Full Disk Access"
      )
    }
    return interfaces
  }

  public func service<S: Service>(_ type: S.Type) async -> S? {
    await registry?.service(type.id) as? S
  }

  // MARK: - Address changes

  /// Announces a new address for this server. See `ServerAddressAnnouncer`.
  ///
  /// Neither delivery happened before this existed: `new-server` was a defined event name
  /// with no emitter, and `ServerURLPublisher` was built, tested, and called from nowhere.
  public func announce(serverAddress: String) async {
    let announcer = addressAnnouncer ?? ServerAddressAnnouncer(events: events, logger: logger)
    addressAnnouncer = announcer
    await announcer.announce(serverAddress) { [pushDelivery] address in
      // Forced, because this is only reached when the address CHANGED and the publisher's
      // own "unchanged" memory is about what this process wrote, not about what the
      // document says.
      await pushDelivery?.publish(serverURL: address, force: true)
    }
  }

  /// The secret store, reachable synchronously.
  ///
  /// Needed because services are constructed by the registry inside a non-async
  /// initializer, and `secrets` is actor-isolated. `nonisolated` is safe here: the store is
  /// immutable and its own implementation is thread-safe.
  public nonisolated var secretsForPush: any SecretStore { secrets }

  /// The whole-server verbs — restart, and process replacement.
  ///
  /// A separate type because `execv` does not belong on a dependency container. Built when
  /// the registry attaches, since it is the registry these drive.
  public private(set) var lifecycle: ServerLifecycle?

  /// Asks the server to restart itself. Delegates; see `ServerLifecycle`.
  public func requestRestart() async {
    await lifecycle?.restartServices()
  }

  /// Replaces the process. Delegates; see `ServerLifecycle`.
  public func requestFullRestart() async {
    await lifecycle?.replaceProcess()
  }

  /// Registered push targets. Storage lives in `DeviceRepository`.
  public nonisolated var devices: DeviceRepository { DeviceRepository(database: appDatabase) }

  /// The registered push targets, with the delivery path's failure policy.
  ///
  /// Prune, clear and read live on `DeviceDirectory`, not here. Holding a reference is a
  /// container's job; deciding what to do when a delete fails is not.
  public nonisolated var deviceDirectory: DeviceDirectory {
    DeviceDirectory(repository: devices, logger: logger)
  }

  /// What each webhook's last delivery did.
  ///
  /// Held here rather than inside `WebhookSink` because the sink is registered and
  /// unregistered by a service — a restart of the sink must not lose the delivery history
  /// the settings page is showing, and the page has no way to reach into the bus for it.
  public let webhookDeliveries = WebhookDeliveryTracker()

  /// Registered webhook endpoints. Storage lives in `WebhookRepository`.
  public nonisolated var webhookStore: WebhookRepository {
    WebhookRepository(database: appDatabase)
  }

  /// The registered webhooks: their targets, the test button, and the delivery history.
  ///
  /// `sendTestWebhook` and `webhookTargets` were methods here; they are one cohesive job and
  /// now live on the type that owns the tracker they both touch.
  public nonisolated var webhooks: WebhookDirectory {
    WebhookDirectory(
      repository: webhookStore, codecs: codecs,
      deliveries: webhookDeliveries, logger: logger
    )
  }

  /// Whether the chat.db read path is available.
  ///
  /// It is optional because Full Disk Access may not be granted yet — and the server has to
  /// start anyway, so the user can reach the permissions page and fix it. A server that
  /// refuses to boot without the permission cannot tell anyone why.
  public var hasMessageAccess: Bool { messages != nil }
}

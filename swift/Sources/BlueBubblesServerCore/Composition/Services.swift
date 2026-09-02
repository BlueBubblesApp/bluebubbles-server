//  Services
//  Each subsystem as a registry service.
//
//  These are thin on purpose. All the behaviour lives in the modules; what a service adds is
//  its identity, its dependencies, and its restart policy — the three things the registry
//  needs to start everything in the right order and keep it running.
//
//  Contrast with `index.ts:459-615`, where init/start/stop are three hand-maintained lists in
//  inconsistent orders. Declaring dependencies means the order is derived, and stop order is
//  its exact reverse rather than a second list that drifted.
//
//  See `.claude/docs/architecture.md`.

import BBAppleScript
import BBAuth
import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBIMessage
import BBInterfaces
import BBPrivateAPI
import BBPrivateAPIContract
import BBProxy
import BBPushKit
import BBSerialization
import BBServiceKit
import BBSettings
import BBSocketIO
import BBSystem
import Foundation
import Hummingbird
import Logging

/// The registry's keys, taken from the manifests.
///
/// Derived rather than declared, so a service's manifest identifier and the key the registry
/// files it under cannot drift. Independent short strings — `"http"` — let a dependency
/// written as `ServiceID.http` silently fail to match a service whose manifest calls it
/// something else, and the topological sort then orders on a graph with missing edges.
extension ServiceID {
  public static let permissions = ServiceID(BuiltInManifests.ID.permissions.rawValue)
  public static let contactsIngest = ServiceID(BuiltInManifests.ID.contacts.rawValue)
  public static let changeDetection = ServiceID(BuiltInManifests.ID.changeDetection.rawValue)
  public static let http = ServiceID(BuiltInManifests.ID.http.rawValue)
  public static let socket = ServiceID(BuiltInManifests.ID.socket.rawValue)
  public static let privateAPI = ServiceID(BuiltInManifests.ID.privateAPI.rawValue)
  public static let push = ServiceID(BuiltInManifests.ID.push.rawValue)
  public static let webhooks = ServiceID(BuiltInManifests.ID.webhooks.rawValue)
  public static let sleepPrevention = ServiceID(BuiltInManifests.ID.sleepPrevention.rawValue)
  public static let scheduledMessages = ServiceID(BuiltInManifests.ID.scheduledMessages.rawValue)
  public static let launchAtLogin = ServiceID(BuiltInManifests.ID.launchAtLogin.rawValue)
}

/// Shared plumbing: every service here is built from the same context.
public protocol ContextualService: Service where Host == AppContext {
  var context: AppContext { get }
}

extension ContextualService {
  /// This service's settings, narrowed to what its manifest declares.
  ///
  /// Reading a core setting through here fails unless the manifest asked for it, which is
  /// what turns the entitlement list from a description into a control. Its own namespace
  /// needs no entitlement — `scoped.own("auth_token")` is always permitted, and cannot
  /// reach another service's field.
  public var scoped: ScopedSettings {
    context.scopedSettings(for: Self.manifest)
  }
}

// MARK: - Permissions

/// Starts first, because everything else's permission gate reads from it.
final class PermissionsMonitorService: ContextualService {
  static let manifest = BuiltInManifests.permissions
  /// Never worth restarting: a failure here is a failure to read system state, and
  /// retrying immediately would just fail the same way.
  static let restartPolicy = RestartPolicy.never

  let context: AppContext

  init(host: AppContext) {
    self.context = host
  }

  func start() async throws {
    await context.permissions.checkAll()
    await context.permissions.startMonitoring()
  }

  func stop() async {
    await context.permissions.stopMonitoring()
  }

  var health: ServiceHealth {
    get async {
      await context.permissions.requiredPermissionsSatisfied()
        ? .running
        : .degraded(reason: "a required permission is missing")
    }
  }
}

// MARK: - Contacts

final class ContactsService: ContextualService, PermissionDependentService {
  static let manifest = BuiltInManifests.contacts
  /// Recommended rather than required — the server runs without Contacts, it just shows
  /// numbers instead of names.
  static let requiredPermissions: [PermissionID] = []

  let context: AppContext
  /// Held so the ingest can be cancelled. `Task.detached` with nothing holding it meant
  /// `stop()` could not stop it: restarting the service — which a settings change now
  /// genuinely does — left the previous reindex running and started a second one on top,
  /// two writers walking the same address book.
  private let ingest = TaskBox()

  init(host: AppContext) { self.context = host }

  func start() async throws {
    // Deliberately not awaited to completion: a large address book takes a while, and
    // blocking startup on it would delay everything behind this service for no reason.
    // Names simply fill in as the ingest progresses.
    let contacts = context.contacts
    let logger = context.logger

    // Published, not just used. The startup reindex built one of these locally and threw it
    // away, so `ContactInterface` held nil and every `contact/refresh` — the API route and
    // the app's "Refresh from Address Book" button — refused with "contact access has not
    // been granted", whatever the actual permission was. One instance, shared.
    let ingestor = ContactsIngestor(index: contacts)
    await context.publish(contactsIngestor: ingestor)

    await ingest.set(
      Task {
        do {
          let result = try await ingestor.reindexAll()
          logger.info(
            "Indexed the address book",
            metadata: [
              "indexed": .stringConvertible(result.indexed),
              "skipped": .stringConvertible(result.skipped),
            ])
        } catch let error as ContactsIngestError {
          // Reported, not swallowed. This was `try?`, so the single most likely failure
          // — no Contacts permission — produced an empty index, no log line, and a
          // server that showed phone numbers for every message with no way to tell why.
          // Not an alert: running without Contacts is a supported configuration, and
          // the Permissions page is where a user acts on it.
          logger.warning(
            "Could not index the address book",
            metadata: [
              "reason": .string(String(describing: error))
            ])
        } catch is CancellationError {
          // Ordinary: `stop()` cancels the ingest.
        } catch {
          logger.error(
            "The address-book index failed",
            metadata: [
              "error": .string(String(describing: error))
            ])
        }
      })
  }

  func stop() async { await ingest.cancel() }

  var health: ServiceHealth {
    get async { await ingest.isRunning ? .running : .inactive(reason: "not started") }
  }
}

// MARK: - Change detection

/// Watches chat.db and turns writes into events.
final class ChangeDetectionService: ContextualService, PermissionDependentService,
  ConfigurableService
{
  static let manifest = BuiltInManifests.changeDetection
  /// The poll interval is read once, at start, to build the detector — so without this the
  /// setting was inert: a user lowering it to get faster message delivery saw no change
  /// until the next launch, and nothing said why.
  static let watchedSettings: Set<String> = ["db_poll_interval"]
  /// The one permission that genuinely gates a service: without Full Disk Access there is
  /// no database to watch, and the registry reports that precisely instead of letting this
  /// fail obscurely at first read.
  static let requiredPermissions: [PermissionID] = [.fullDiskAccess]
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  let context: AppContext
  /// Held so it can be cancelled. The detector's stream ends when the task does.
  private let pump = TaskBox()

  init(host: AppContext) { self.context = host }

  func start() async throws {
    guard let repository = context.messages else {
      throw ServiceStartupError.unavailable("chat.db is not readable")
    }

    var configuration = ChangeDetectorConfiguration()
    configuration.pollInterval = .milliseconds(
      await context.settings.get(Settings.dbPollInterval)
    )

    let detector = ChangeDetector(repository: repository, configuration: configuration)
    let events = context.events
    let serializer = context.serializer
    let logger = context.logger

    // Started before `start()` returns, so a change written while the rest of the
    // services are still coming up is not missed.
    await pump.set(
      Task {
        for await changes in await detector.changes(watching: ChatDatabase.defaultPath) {
          for change in changes {
            guard let event = Self.event(for: change, serializer: serializer) else {
              continue
            }
            // Rate-limited per chat where the policy asks for it, so a busy
            // conversation cannot starve a quiet one. `cacheRoomnames` is the chat
            // the row belongs to as chat.db records it; a message with none is
            // rate-limited globally, which is correct — it has no chat to key on.
            await events.emit(
              event, rateLimitKey: change.message.cacheRoomnames
            )
          }
        }
        logger.debug("Change detection stopped")
      })

    let pollInterval = await context.settings.get(Settings.dbPollInterval)
    context.logger.info(
      "Watching chat.db for changes",
      metadata: [
        "pollMs": .stringConvertible(pollInterval)
      ])
  }

  /// Rebuilt rather than reconfigured: the interval is baked into the detector when it is
  /// constructed and cannot be changed on a running one.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  func stop() async {
    await pump.cancel()
  }

  /// Maps a detected change onto the client-facing event vocabulary.
  ///
  /// Returns nil for changes with no client event — not every column that moves is
  /// something a client is told about, and emitting one anyway would be a new event name
  /// no client knows.
  static func event(
    for change: MessageChange,
    serializer: MessageSerializer?
  ) -> ServerEvent? {
    guard let serializer else { return nil }
    let payload = serializer.serialize(
      change.message, context: MessageSerializer.Context(), config: .full
    )
    let notification = serializer.serialize(
      change.message, context: MessageSerializer.Context(),
      config: .notification, isForNotification: true
    )

    // `isNew` distinguishes an insert from an update; the changed-field set says what
    // moved. An error is reported as its own event because clients surface it
    // differently from an ordinary update.
    let name: EventName
    if change.changedFields.contains(.error), change.message.error != 0 {
      name = .messageSendError
    } else {
      name = change.isNew ? .newMessage : .updatedMessage
    }

    return ServerEvent(
      name: name, fullPayload: payload, notificationPayload: notification
    )
  }

  var health: ServiceHealth {
    get async { await context.hasMessageAccess ? .running : .degraded(reason: "no chat.db access") }
  }
}

/// Holds a cancellable task behind an actor, since services are constructed as classes.
/// Holds the Private API runtime across `start`, `stop` and `health`.
///
/// An actor rather than a bare `var` behind `@unchecked Sendable`. The registry does
/// serialise lifecycle calls today, so the race was not reachable — but that is an
/// invariant of the CALLER, nothing in this type said so, and the annotation that would
/// have flagged it was the one suppressing the check. Removing the annotation is what
/// surfaced it.
actor RuntimeBox {
  private var runtime: PrivateAPIRuntime?
  func set(_ runtime: PrivateAPIRuntime?) { self.runtime = runtime }
  var current: PrivateAPIRuntime? { runtime }
}

actor TaskBox {
  private var task: Task<Void, Never>?
  func set(_ task: Task<Void, Never>) { self.task = task }
  func cancel() {
    task?.cancel()
    task = nil
  }
  var isRunning: Bool { task != nil }
}

// MARK: - HTTP

final class HTTPService: ContextualService, ConfigurableService {
  static let manifest = BuiltInManifests.http
  /// A port change or a certificate change means rebinding, which is a restart.
  static let watchedSettings: Set<String> = [
    "socket_port", "use_custom_certificate", "password", "bind_address",
  ]
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
        await self?.context.noteClientActivity()
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
        actions: [.openSettings(section: "settings")],
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

// MARK: - Socket

final class SocketService: ContextualService, ConfigurableService {
  static let watchedSettings: Set<String> = ["password"]

  static let manifest = BuiltInManifests.socket

  let context: AppContext

  init(host: AppContext) { self.context = host }

  func start() async throws {
    // Registering the sink is what connects change detection to connected clients: the
    // detector emits onto the bus, the bus fans out to sinks, and this one broadcasts.
    // Without it the events are produced and go nowhere.
    await context.events.register(SocketSink(server: context.socketServer))

    // Heartbeats and session reaping. Without it an idle EIO4 client eventually decides
    // the server is gone, and a client that vanished without closing leaves its session
    // and its queued broadcasts in memory for the life of the process.
    await context.engineIO.startMaintenance()
    context.logger.info("Socket transport ready")
  }

  func stop() async {
    await context.engineIO.stopMaintenance()
    await context.engineIO.closeAll()
    await context.events.unregister(.socket)
  }

  /// A password change must kick connected clients: they authenticated with the old one,
  /// and leaving the socket open means a revoked password keeps working until they happen
  /// to reconnect.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let clients = await context.socketServer.connectionCount
      return clients > 0 ? .running : .degraded(reason: "no clients connected")
    }
  }
}

// MARK: - Private API

final class PrivateAPIGatedService: ContextualService, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.privateAPI
  static let watchedSettings: Set<String> = [
    "enable_private_api", "private_api_mode", "private_api_helper_path",
    // Changing which FaceTime dylib is injected has to re-inject it, same as the
    // Messages one — and so does turning FaceTime injection on or off.
    "private_api_facetime_helper_path", "enable_ft_private_api",
  ]
  static let restartPolicy = RestartPolicy.backoff(
    base: .seconds(5), max: .seconds(60), attempts: 5
  )

  let context: AppContext
  /// Built in `start()` rather than `init`, because its configuration comes from settings
  /// and the initializer is synchronous. A runtime constructed here with `isEnabled: false`
  /// never opens a socket and never injects, so the helper has nothing to connect to and
  /// every Private API endpoint reports the helper as unavailable on a machine where it
  /// would work.
  private let runtime = RuntimeBox()
  /// Forwards helper events onto the event bus. Held so it stops with the service.
  private let pump = TaskBox()

  init(host: AppContext) {
    self.context = host
  }

  /// Declining is a normal state, not a failure. This is what replaces the inline
  /// `if privateApiEnabled` in startServices().
  /// Runs when EITHER helper is wanted.
  ///
  /// The two are independent: different dylibs, injected into different apps, connecting to
  /// different sockets. They share only this transport, so FaceTime does not need the
  /// Messages Private API switched on. (One soft link remains: the FaceTime call pre-flight
  /// asks the MESSAGES helper whether an address is FaceTime-capable, and without it that
  /// check simply cannot answer — an unverifiable address is allowed through rather than
  /// refused. See `requireFaceTimeCapable`.)
  func canRun() async -> Bool {
    let messages = await context.settings.get(Settings.enablePrivateAPI)
    let faceTime = await context.settings.get(Settings.enableFaceTimePrivateAPI)
    return messages || faceTime
  }

  func start() async throws {
    let settings = context.settings
    let configuration = PrivateAPIConfiguration(
      isEnabled: true,
      dylibPath: await settings.get(Settings.enablePrivateAPI)
        ? await Self.resolveHelperPath(settings: settings)
        : nil,
      // Injected AT STARTUP when the FaceTime toggle is on, alongside Messages.
      // Injection quits and relaunches the app, so doing it lazily — on the first
      // client call to a FaceTime route — would restart FaceTime.app underneath
      // someone mid-request and fail that call. Both helpers come up with the server,
      // so every Private API route works from the first request.
      faceTimeDylibPath: await settings.get(Settings.enableFaceTimePrivateAPI)
        ? await Self.resolveFaceTimeHelperPath(settings: settings)
        : nil,
      injectionPolicy: .legacy,
      // Validated against Messages.app's own signature. The peer on this socket IS
      // Messages — the helper runs inside it — so this is what stops any other local
      // process from driving the Private API.
      peerRequirement: nil
    )

    let runtime = PrivateAPIRuntime(
      configuration: configuration,
      alerts: PrivateAPIAlertBridge(alerts: context.alerts),
      logger: context.logger
    )
    await self.runtime.set(runtime)

    // Attached BEFORE start: injection quits and relaunches Messages and can take tens
    // of seconds, and the interfaces should hold the client for that whole time rather
    // than reporting "no Private API" until it finishes.
    await context.publishPrivateAPI(client: runtime.client, runtime: runtime)

    try await runtime.start()

    // Helper events onto the bus.
    //
    // The decoder turns typing, FindMy, alias-removal and FaceTime notifications into
    // `PrivateAPIEvent`s, and nothing forwarded them: the only consumer of the stream
    // matched `helperRegistered` and discarded the rest. So a whole family of
    // client-visible events was decoded correctly and thrown away — typing indicators in
    // particular are the most visible thing the Private API provides.
    let client = await runtime.client
    let events = context.events
    let logger = context.logger
    let cleanupContext = context
    await pump.set(
      Task {
        for await event in client.events {
          // The FaceTime helper registering is the ONLY moment stray links can be
          // cleared: invalidation needs link objects, and the list that holds them is
          // populated at FaceTime's process start and never refreshed (the delegate that
          // would refresh it crashes FaceTime.app). So the sweep rides on registration
          // rather than a timer — a timer would find nothing, every time.
          if case .helperRegistered(let process, _, _) = event,
            process == HelperHost.faceTime
          {
            await Self.sweepFaceTime(context: cleanupContext)
          }
          guard let (server, key) = Self.serverEvent(for: event) else { continue }
          await events.emit(server, rateLimitKey: key)
        }
        logger.debug("Private API event pump stopped")
      })
  }

  func stop() async {
    await pump.cancel()
    // Withdrawn BEFORE the runtime is torn down, and both halves together. Clearing them
    // separately either side of `stop()` left the client published against a runtime that
    // was already gone.
    await context.withdrawPrivateAPI()
    await self.runtime.current?.stop()
    await self.runtime.set(nil)
  }

  /// Maps a helper event onto the client-facing vocabulary.
  ///
  /// The second element is the rate-limit key. It matters for FindMy: locations arrive as
  /// a batch covering every device, and keying on the DEVICE is what makes the limiter
  /// deliver each device's newest position rather than one device's and nobody else's.
  /// The automatic sweep: expired server-created links, plus any call the Mac is stuck in.
  ///
  /// Deliberately quiet. This runs on every registration, and the common case is that there
  /// is nothing to do; only actual work is logged.
  /// The automatic sweep: expired server-created links, plus any call the Mac is stuck in.
  ///
  /// Deliberately quiet. This runs on every registration and the common case is that there
  /// is nothing to do, so only actual work is worth a line.
  private static func sweepFaceTime(context: AppContext) async {
    let result = await context.faceTime().cleanUp(clearAll: false)
    guard !result.links.isEmpty || !result.calls.isEmpty else { return }
    context.logger.info(
      "FaceTime cleanup on helper registration",
      metadata: [
        "links": .stringConvertible(result.links.count),
        "calls": .stringConvertible(result.calls.count),
      ])
  }

  static func serverEvent(
    for event: PrivateAPIEvent
  ) -> (event: ServerEvent, rateLimitKey: String?)? {
    switch event {
    case .helperRegistered:
      // Connection bookkeeping, not something a client is told about.
      return nil

    case .typingChanged(let chat, let isTyping):
      let payload = JSONValue.object([
        "guid": .string(chat.rawValue),
        "display": .bool(isTyping),
      ])
      return (
        ServerEvent(
          name: .typingIndicator, fullPayload: payload, notificationPayload: payload
        ),
        chat.rawValue
      )

    case .iMessageAliasesRemoved(let aliases):
      let payload = JSONValue.object([
        "aliases": .array(aliases.map(JSONValue.string))
      ])
      return (
        ServerEvent(
          name: .iMessageAliasesRemoved,
          fullPayload: payload,
          notificationPayload: payload
        ),
        nil
      )

    case .findMyLocationUpdated(let payload):
      let body = JSONValue.object(payload.mapValues(JSONValue.string))
      // No key, deliberately. FindMy's limit is global — see `EventRouting.policy` —
      // because it protects Apple's service from this server rather than protecting
      // this server's own delivery from a busy chat. Keying it per device would
      // multiply the permitted request rate by the number of devices.
      return (
        ServerEvent(
          name: .newFindMyLocation, fullPayload: body, notificationPayload: body
        ),
        nil
      )

    case .faceTimeCallChanged(let call, let payload):
      // The typed call plus the raw fields the contract does not model. An incoming
      // call is delivered under the same event with `status = incoming`, which is the
      // signal a client turns into "answer via the API."
      var fields = payload.mapValues(JSONValue.string)
      fields["callUuid"] = .string(call.callUUID)
      fields["status"] = .string(call.status.name)
      fields["callStatus"] = .int(call.status.rawValue)
      if let handle = call.handle { fields["address"] = .string(handle.value) }
      let body = JSONValue.object(fields)
      return (
        ServerEvent(
          name: call.status == .incoming ? .incomingFaceTime : .faceTimeCallStatusChanged,
          fullPayload: body,
          notificationPayload: body
        ),
        call.callUUID
      )

    case .faceTimeMembershipChanged(let conversationUUID, let members):
      // Consumed by the server's FaceTime session state machine to decide when the Mac
      // may drop. Not forwarded to clients as its own event yet — the client cares about
      // the link and the call status, not raw membership churn.
      let body = JSONValue.object([
        "conversationUuid": .string(conversationUUID),
        "members": .array(
          members.map { member in
            JSONValue.object([
              "address": .string(member.handle.value),
              "isPending": .bool(member.isPending),
            ])
          }),
      ])
      return (
        ServerEvent(
          name: .faceTimeCallStatusChanged,
          fullPayload: body,
          notificationPayload: body
        ),
        conversationUUID
      )
    }
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      guard let runtime = await runtime.current else {
        return .degraded(reason: "not started")
      }
      guard await runtime.isConnected else {
        return .degraded(reason: "no helper connected")
      }
      return .running
    }
  }

  /// Where the dylib is, in order of preference.
  ///
  /// The bundled copy first, because that is what a released install uses and it is inside
  /// the signed, notarized container. The setting is the development escape hatch.
  /// Same resolution order as the Messages helper, against the FaceTime dylib.
  static func resolveFaceTimeHelperPath(settings: SettingsStore) async -> String? {
    let configured = await settings.get(Settings.privateAPIFaceTimeHelperPath)
    if !configured.isEmpty { return configured }

    if let bundled = Bundle.main.url(
      forResource: "libBlueBubblesFaceTimeHelper", withExtension: "dylib"
    ) {
      return bundled.path
    }
    let frameworks = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libBlueBubblesFaceTimeHelper.dylib")
    if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks.path }
    return nil
  }

  static func resolveHelperPath(settings: SettingsStore) async -> String? {
    let configured = await settings.get(Settings.privateAPIHelperPath)
    if !configured.isEmpty { return configured }

    if let bundled = Bundle.main.url(forResource: "libBlueBubblesHelper", withExtension: "dylib") {
      return bundled.path
    }
    let frameworks = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Frameworks/libBlueBubblesHelper.dylib")
    if FileManager.default.fileExists(atPath: frameworks.path) { return frameworks.path }

    // Nil means "listen, but do not manage injection" — a helper installed some other
    // way still connects. That is a supported configuration, not a failure.
    return nil
  }
}

/// Routes the runtime's failures into the alert centre without giving BBPrivateAPI a
/// dependency on BBDiagnostics.
struct PrivateAPIAlertBridge: PrivateAPIAlerting {
  let alerts: AlertCenter

  func raise(title: String, detail: String) async {
    await alerts.raise(
      UserAlert(
        severity: .error,
        title: title,
        body: detail,
        source: "PrivateAPI",
        // Coalesced: injection retries, and a failing retry loop would otherwise
        // produce one alert per attempt.
        dedupeKey: "private-api.injection"
      )
    )
  }
}

// MARK: - Push

final class PushDeliveryService: ContextualService, GatedService, ConfigurableService {
  static let manifest = BuiltInManifests.push

  let context: AppContext
  private let credentials: PushCredentialStore
  /// Reachable so `PushInterface` can drive setup — importing credentials, provisioning a
  /// project, sending a test notification — against the SAME service the sink delivers
  /// through, rather than a second one that would have its own token cache and its own idea
  /// of whether push is configured.
  let push: PushService

  init(host: AppContext) {
    let app = host
    self.context = app
    // The SHARED Keychain store, not a fresh in-memory one. With its own store this
    // would find no credentials, decline to run, and report "push is not configured" on
    // a machine where it demonstrably is.
    let credentials = PushCredentialStore(secrets: app.secretsForPush)
    self.credentials = credentials
    self.push = PushService(
      credentials: credentials,
      onRestart: { await app.requestRestart() },
      pruneTokens: { tokens in await app.deviceDirectory.prune(tokens: tokens) },
      persistLastRestart: { timestamp in
        try? await app.settings.set(Settings.lastFcmRestart, to: Int(timestamp))
      },
      serverURL: { await app.settings.get(Settings.serverAddress) }
    )
  }

  /// Push is optional. With no credentials this declines, the server starts clean, and
  /// nothing is logged as a defect — the opposite of today's `postChecks` nagging.
  ///
  /// It reads the CREDENTIAL STORE, not the service. `push.isConfigured` reports what the
  /// last `start` found, and the gate runs BEFORE `start` — so asking the service was
  /// asking a question whose answer is always "no" on a server that has not started push
  /// yet, which is every server. Push was gated off on every install, including fully
  /// configured ones: nothing failed, no warning was logged, and no notification was ever
  /// sent. Measured by the wiring test that now pins this.
  func canRun() async -> Bool { await credentials.isConfigurable() }

  static let watchedSettings: Set<String> = ["remote_restart_enabled"]

  func start() async throws {
    // Read here rather than at construction: the registry builds services synchronously
    // and settings are actor-isolated, so there is no `await` available in `init`.
    await push.configure(
      PushConfiguration(
        remoteRestartEnabled: await context.settings.get(Settings.remoteRestartEnabled),
        lastHonouredRestart: Int64(await context.settings.get(Settings.lastFcmRestart))
      )
    )
    await push.start()
    // Handed to the context rather than looked up from it: see `AppContext.pushDelivery`.
    await context.publish(pushDelivery: push)

    // Registering the sink is what makes push actually deliver. Without it the service
    // starts, reports itself configured, and is never asked to send anything: the bus
    // fans out only to sinks that registered, and this one never did. Nothing failed —
    // `server/info` said push was active and Android clients received nothing.
    await context.events.register(
      PushSink(
        service: push,
        tokens: { [weak context] in await context?.deviceDirectory.tokens() ?? [] },
        negotiator: context.codecs
      )
    )
  }

  /// Turning remote restart off has to stop the poll, which means rebuilding the watcher —
  /// there is nothing to reconfigure in place.
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  func stop() async {
    await context.withdrawPushDelivery()
    await context.events.unregister(.push)
    await push.stop()
  }

  var health: ServiceHealth { get async { .running } }
}

// MARK: - Webhooks

/// Registers the webhook sink so subscribed endpoints actually receive events.
///
/// Its own service rather than part of push, because the two are independent delivery routes
/// and a webhook-only install is a first-class deployment — several users run ntfy and no
/// Firebase at all. `WebhookSink` had been written, tested and never constructed, so every
/// webhook subscription in the database was inert.
final class WebhookDeliveryService: ContextualService, ConfigurableService {
  static let manifest = BuiltInManifests.webhooks
  /// A failing endpoint is the endpoint's problem, not ours; the sink alerts once a
  /// failure becomes persistent and there is nothing here to restart.
  static let restartPolicy = RestartPolicy.never

  let context: AppContext

  init(host: AppContext) { self.context = host }

  static let watchedSettings: Set<String> = [
    "ntfy_topic", "ntfy_server", "ntfy_token", "ntfy_events",
  ]

  func start() async throws {
    // Targets are read per event rather than captured: a webhook added through the API
    // has to start receiving without a restart, which a snapshot taken here would not.
    await context.events.register(
      WebhookSink(
        targets: { [weak context] in await context?.webhooks.targets() ?? [] },
        negotiator: context.codecs,
        alerts: context.alerts,
        // Shared with the context so delivery history outlives a restart of this
        // service, and so the settings page has something to read.
        deliveries: context.webhookDeliveries
      )
    )

    // ntfy is registered only when a topic is configured. An unconfigured sink that
    // declines every event is indistinguishable from a configured one that is failing,
    // and it is the second state an operator needs to be able to see.
    let topic = await context.settings.get(Settings.ntfyTopic)
      .trimmingCharacters(in: .whitespaces)
    guard !topic.isEmpty else { return }

    // An unreadable Keychain gives nil, which here is treated as no token: ntfy accepts
    // unauthenticated publishes to a public topic, so the sink stays up rather than
    // taking the server down with it. The alert raised by the store is what reports it.
    let token = await context.settings.secret(Settings.ntfyToken)?.unsafeStringValue() ?? ""

    // The event filter `NtfyTarget` has always supported and nothing ever supplied, so
    // every ntfy install has been receiving the wildcard whether or not that is what the
    // operator wanted. An empty or absent setting still means everything, which is what
    // existing installs already get.
    let events = await context.settings.get(Settings.ntfyEvents)
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    // Cleared to nothing means nothing, not everything. The setting ships as `*`, so an
    // empty value is someone deliberately unticking every box — and a sink registered to
    // accept no event is the inert-but-present state this project keeps finding, so it is
    // not registered at all. The settings row says so where the boxes are unticked.
    guard !events.isEmpty else { return }

    await context.events.register(
      NtfySink(
        target: NtfyTarget(
          serverURL: await context.settings.get(Settings.ntfyServer),
          topic: topic,
          accessToken: token.isEmpty ? nil : token,
          events: events
        )
      )
    )
  }

  func stop() async {
    await context.events.unregister(.webhook)
    await context.events.unregister(.ntfy)
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let webhooks = await context.webhooks.targets().count
      // A topic subscribed to no events delivers nothing, so it does not count as
      // configured — reporting "running" for it would describe a sink that was never
      // registered.
      let topic = await context.settings.get(Settings.ntfyTopic)
      let ntfyEvents = await context.settings.get(Settings.ntfyEvents)
      let ntfy =
        !topic.isEmpty
        && !ntfyEvents.trimmingCharacters(in: .whitespaces).isEmpty
      guard webhooks > 0 || ntfy else {
        return .inactive(reason: "no webhooks or ntfy topic configured")
      }
      return .running
    }
  }
}

// MARK: - Sleep prevention

final class SleepPreventionService: ContextualService, ConfigurableService, GatedService {
  static let manifest = BuiltInManifests.sleepPrevention
  static let watchedSettings: Set<String> = ["auto_caffeinate"]

  let context: AppContext
  private let prevention = SleepPrevention()

  init(host: AppContext) { self.context = host }

  func canRun() async -> Bool {
    await context.settings.get(Settings.autoCaffeinate)
  }

  func start() async throws { await prevention.begin() }
  func stop() async { await prevention.end() }
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }
  var health: ServiceHealth { get async { .running } }
}

// MARK: - Errors

public enum ServiceStartupError: BBError, CustomStringConvertible {
  case unavailable(String)

  public var description: String {
    switch self {
    case .unavailable(let reason): reason
    }
  }
}

extension ServiceStartupError {
  public var code: String { "service.unavailable" }
  public var domain: String { "Services" }
  public var title: String { "A service could not start" }
  public var body: String { description }
}

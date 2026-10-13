//  AppModel
//  The root observable model. Owns the running server; the views read from it.
//
//  There is NO IPC here, and that is the point. View models call the same interfaces layer the
//  HTTP controllers call, in the same process. See `.claude/docs/architecture.md`.

import BBAuth
import BBBuiltIns
import BBContacts
import BBCore
import BBDiagnostics
import BBEvents
import BBFaceTime
import BBInterfaces
import BBPrivateAPI
import BBServiceKit
import BBSettings
import BBShortcuts
import BBSystem
import BBTooling
import BBUpdates
import BlueBubblesServerCore
import Foundation
import Observation
import SwiftUI

/// How far along the server is.
///
/// A real state machine rather than a Bool, because "starting" is a state the user sees:
/// building the context opens two databases and probes the schema, which is not instant on a
/// large chat.db, and a UI that shows "stopped" during it looks broken.
enum ServerPhase: Hashable {
  case idle
  case starting
  /// Honouring the configured startup delay. Distinct from `.starting` so the UI can say
  /// WHY nothing is happening: a silent thirty-second pause reads as a hang.
  case waiting(Duration)
  case running
  case stopping
  case failed(String)
  /// An Electron installation was found that has not been adopted. The server is NOT built,
  /// deliberately; see `MigrationStep.isBlocking`.
  ///
  /// Carries no payload. `ServerPhase` is `Hashable` and `HomeView` keys its visit on
  /// `model.phase`; a plan value holding `@Sendable` closures would kill the synthesized
  /// conformance and take `phase != .idle` with it. The plan lives on `AppModel.migration`
  /// instead.
  case migrationRequired

  var isRunning: Bool { self == .running }

  /// Whether `AppModel.start` may begin from here.
  ///
  /// `.migrationRequired` is in the set, and must be: it is the phase the wizard leaves
  /// behind, so without it the "I am done, start now" call returns silently and the user is
  /// left looking at a finished wizard and a stopped server.
  var canStart: Bool {
    switch self {
    case .idle, .failed, .migrationRequired: true
    case .starting, .waiting, .running, .stopping: false
    }
  }

  /// Mid-transition: the Start/Stop button has nothing useful to do. `.waiting` counts:
  /// the server is on its way up, and offering Start again during the delay would look
  /// like the first press was ignored.
  var isBusy: Bool {
    switch self {
    case .starting, .waiting, .stopping: true
    // NOT busy: there is something to do, and the button that does it must be pressable.
    case .idle, .running, .failed, .migrationRequired: false
    }
  }

  var label: String {
    switch self {
    case .idle: "Stopped"
    case .starting: "Starting…"
    case .waiting(let delay):
      "Starting in \(delay.components.seconds)s…"
    case .running: "Running"
    case .stopping: "Stopping…"
    case .failed: "Failed"
    case .migrationRequired: "Setup required"
    }
  }
}

/// What `start()` is doing, while it is doing it.
///
/// `.starting` is one phase and, on a Mac with a large `chat.db` or a spinning disk, several
/// minutes of work: a schema probe, two databases, a migration check, the whole service
/// graph. A single "Starting…" for all of it is what a user reported as "no indication of
/// what was going on", and the natural conclusion from a spinner that does not move is that
/// the app has hung.
///
/// Separate from `ServerPhase` rather than a payload on `.starting`, on purpose: `HomeView`
/// and `RootView` both key a `.task` on the phase, and a phase that changed five times on
/// the way up would re-run those reads five times.
enum StartupStage: Equatable {
  case checkingForAnotherCopy
  case openingStorage
  case checkingForAnExistingInstall
  case assembling
  /// Services are coming up, one at a time in dependency order, and this is the one the
  /// registry is on.
  ///
  /// A NAME rather than "3 of 12", and the difference is not cosmetic. A service that has
  /// not been reached yet and one that is deliberately switched off both report
  /// `.inactive`, and the only thing separating them is the sentence inside it, so a count
  /// of "how many are done" could only be arrived at by matching on that prose: the exact
  /// habit `ConnectionActivity` exists to avoid. What IS structural is which service the
  /// registry has in flight, and it is also the more useful answer: "Starting
  /// Private API…" says which step is slow, where a fraction only says that one is.
  case startingServices(name: String?)

  var label: String {
    switch self {
    case .checkingForAnotherCopy: "Checking for another copy…"
    case .openingStorage: "Opening the database…"
    case .checkingForAnExistingInstall: "Looking for an existing installation…"
    // Named for what takes the time. This step opens `chat.db` and probes its schema, which
    // is the step that is slow on an old Mac with years of messages in it.
    case .assembling: "Reading the Messages database…"
    case .startingServices(let name):
      name.map { "Starting \($0)…" } ?? "Starting services…"
    }
  }
}

@Observable
@MainActor
final class AppModel {

  private(set) var phase: ServerPhase = .idle

  /// What the current start is doing. Nil whenever the phase is not `.starting`.
  ///
  /// Read by `ServerStatusBar` and by Home. Cleared on every exit from `start`, success or
  /// failure, so a stale stage cannot outlive the attempt that set it.
  private(set) var startupStage: StartupStage?

  private(set) var server: RunningServer?

  /// The concerns with their own state and lifetime. Each attaches in `start`, through
  /// `attachments`, which is also what detaches it; the views reach them as `model.alerts`
  /// etc.
  let permissions = PermissionsModel()
  let alerts = AlertsModel()
  let updates = UpdatesModel()
  let updater = SparkleUpdater()
  let integrations = IntegrationsModel()
  let onboarding = OnboardingModel()
  /// Export and import. A child model because both halves own work with a lifetime: an
  /// import unpacks into a temporary directory that has to be cleaned up whether or not
  /// the person goes through with it.
  let archive = ArchiveModel()
  let migration = MigrationModel()
  /// The log tail, followed while the Logs page is showing; see `LogsModel`.
  let logs = LogsModel()
  /// What the server is doing, sampled on the server and followed here; see `MetricsModel`.
  let metrics = MetricsModel()
  /// Each webhook's last delivery, and a version of the registered list; see `WebhooksModel`.
  let webhooks = WebhooksModel()

  init() {
    home.model = self
    alerts.onUnreadCountChanged = { [weak self] in await self?.applyAppearance() }
    integrations.onFailure = { [weak self] error, action in
      await self?.report(error, while: action)
    }
  }

  /// What the detail column has pushed on top of the selected page.
  ///
  /// On the model rather than in `RootView` for the same reason `selection` is: an alert, or
  /// a Configure button on the settings screen, needs to be able to send someone to a
  /// specific service's page and have Back work.
  var detailPath: [ServiceIdentifier] = []

  /// What the Firebase page has pushed on top of itself.
  ///
  /// Its own path rather than a case on `detailPath`, which is typed to the thing
  /// Integrations pushes: a service identifier. On the model for the reason every other
  /// navigation state is -- the registered devices are somewhere an alert about a rejected
  /// push token will eventually want to send someone, and a page only the user can reach by
  /// clicking cannot be offered.
  var firebasePath: [FirebaseDetail] = []

  /// Which tab of the settings page is showing.
  ///
  /// On the model rather than as `@State` in `SettingsView` for the same reason `selection`
  /// is: a guide's "Open Permissions" button and an alert's remedy both need to land on a
  /// specific tab, and a tab that only the user can reach by clicking cannot be offered.
  var settingsTab: SettingsTab = .general

  /// Which sidebar page is showing.
  ///
  /// On the model rather than as `@State` in `RootView` because navigation is no longer
  /// only the sidebar's business: an alert carries the remedy for its own problem, and
  /// "open the Security page" is one of the remedies. A view that can only be reached by
  /// the user clicking the sidebar cannot be offered by a notification.
  var selection: Destination = .home {
    didSet {
      // The log tail is followed only while its page is showing; see `LogsModel`.
      guard selection != oldValue else { return }
      logs.setShowing(selection == .logs)
    }
  }

  /// Firebase setup state and its in-flight work.
  ///
  /// Owned here, not by `FirebaseView`. Guided provisioning takes minutes, and anything a
  /// view holds in `@State` (including the `Task` running the work) dies when the detail
  /// column shows another page. Held here, the run continues and the screen re-attaches to
  /// it with its progress intact.
  let firebaseSetup = FirebaseSetupModel()

  /// What Home has read, and when. Owned here for the same reason `firebaseSetup` is: the
  /// reads are the most expensive the app makes, and held in the page's `@State` they ran
  /// again on every visit. See `HomeModel`.
  let home = HomeModel()

  /// The running server's container. PRIVATE, and the facades are why.
  ///
  /// Handing a component the whole `AppContext` is an undeclared dependency: the type says
  /// "everything", so nothing states what the component actually needs. The HTTP controllers
  /// take narrow capabilities; the app is the OTHER consumer of that same layer and takes
  /// them the same way, through the facades this file builds (`security`, `messaging`,
  /// `delivery`, `subscription`, `monitoring`; see `ServerAccess.swift`). Nothing outside
  /// this file reads the context, so nothing builds a facade of its own or reaches past the
  /// doors they open; `FrontEndPlumbingPolicyTests` holds that for `server?.context` too.
  private var context: AppContext? { server?.context }

  var security: SecurityAccess { SecurityAccess(context: context) }
  var messaging: MessagingAccess { MessagingAccess(context: context) }
  var delivery: DeliveryAccess { DeliveryAccess(context: context) }
  var subscription: SubscriptionAccess { SubscriptionAccess(context: context) }
  var monitoring: MonitoringAccess { MonitoringAccess(context: context) }

  // MARK: - Narrow access
  //
  // Four cross-cutting doors stay here because they have no natural group and because the
  // model's own extensions use them: `ToolActions` drives `tools` and raises through
  // `alertCenter`, and `settings` is read by most screens for unrelated reasons. Everything
  // else is grouped; see `ServerAccess.swift` for `security`, `messaging` and `delivery`.
  //
  // Nil whenever the server is not running, which is every accessor's normal state: the app
  // opens before the server starts, and screens are expected to render without one.
  // `settings` is the exception, and a child model rather than an optional: with no server
  // it THROWS `ServerNotRunning` from every call, because a settings write that silently did
  // nothing is what an optional store produced at twenty-four call sites. See
  // `SettingsModel`.

  /// The one door to the server's settings. Attached BEFORE the start delay, not after, so
  /// during a thirty-second delay the settings screen still opens and someone who set the
  /// delay too high can reach the row that sets it.
  let settings = SettingsModel()
  var alertCenter: AlertCenter? { context?.alerts }
  var tools: ToolManager? { context?.tools }

  /// The admin API: server counts, and registering or removing a webhook. The same surface
  /// a client reaches over HTTP, which is why it is not under `delivery`: that group is the
  /// runtime side of getting an event out, and this is the configuration of one.
  var serverAdmin: AdminInterface? { context?.admin }

  /// Show a settings tab. Both halves at once, so a caller cannot select the tab and leave
  /// the sidebar on another page.
  func openSettings(tab: SettingsTab) {
    settingsTab = tab
    selection = .settings
  }

  /// The external programs services depend on, by tool id.
  ///
  /// Held here rather than read per redraw because a status crosses an actor boundary and
  /// the install page redraws on every progress step. See `ToolActions`.
  var toolStatuses: [String: ToolStatus] = [:]

  /// The registry's view of each service, followed for the life of the server; see
  /// `followServiceHealth`.
  var serviceHealths: [ServiceIdentifier: ServiceHealth] = [:]

  /// The Private API runtime's state, followed while the server holds one; see
  /// `PrivateAPIObservation.swift`. Nil when there is no runtime to follow.
  var privateAPIState: PrivateAPIRuntime.State?
  var followedPrivateAPIRuntime: ObjectIdentifier?

  /// The address clients connect to, as the running connection method last published it,
  /// and the listener's port; see `AddressObservation.swift`. `.unknown` when there is no
  /// server. A screen draws it with `ServerAddressRow`.
  var clientAddress = ClientAddress.unknown

  /// Bumped on every change to the push device table, for the same reason and in the same
  /// shape as `webhooks.registrationsVersion`: the rows are the page's to read, through
  /// `ScreenModel`, so a read that fails is reported where the page can say so. See
  /// `DeviceObservation.swift`.
  var pushDevicesVersion = 0

  /// Bumped on every change to the audit table, in the same shape as the device counter
  /// above, and for the same reason: almost nothing that writes an audit record is the page
  /// that shows it. See `AuditObservation.swift`.
  var auditEventsVersion = 0

  /// Who is blocked, exempt, or failing, followed from the access-control service for the
  /// life of the server; see `AccessControlObservation.swift`. Nil when there is no server.
  var accessControl: AccessControlSnapshot?

  /// Every stream followed from the running server, and what stopping each clears; see
  /// `ServerFollows.swift`.
  @ObservationIgnored let follows = FollowTable()

  /// Everything the current start has attached, each beside its own detach; see
  /// `ServerAttachments.swift`. The one list a stop, a failed start and the next start all
  /// undo.
  @ObservationIgnored let attachments = ServerAttachments()

  /// The app-level settings that take effect immediately.
  ///
  /// Watched here rather than by a service because no service owns them: they act on this
  /// process's Dock presence, which the server has no opinion about.
  static let appearanceKeys: Set<String> = [Settings.hideDockIcon.key, Settings.dockBadge.key]

  // MARK: - Lifecycle

  /// The one writer of `startupStage` outside `start`:
  /// `ServiceHealthObservation.noteStartupProgress`, which names the service the registry
  /// has in flight. A method rather than dropping `private(set)`, so that stays
  /// the only other place it can move from.
  func setStartupStage(_ stage: StartupStage?) { startupStage = stage }

  /// The startup attempt in flight, owned HERE rather than by whatever triggered it.
  ///
  /// A start triggered from a view and awaited there is a dependent of that view: the
  /// headless launch closes the main window before the server is up, and anyone can close
  /// it during a start that takes minutes. See `beginStart`.
  private var startTask: Task<Void, Never>?

  /// Starts the server on the model's own lifetime, and returns. The ONLY way to start it:
  /// the launch, every Start button, the migration wizard and `restart` all come here, and
  /// `start` is private so nothing can go round it.
  ///
  /// The caller says "start", not "start and stay alive until I have finished starting". A
  /// view cannot honour the second: it is torn down when its window closes, on the headless
  /// path deliberately and on every other path whenever the user closes the window during a
  /// startup that can legitimately take minutes on a large `chat.db`.
  ///
  /// Cleared when the attempt finishes, so a failed start can be retried; held while one is
  /// running, so a second press (or a window reopening) does not begin a second.
  /// `start()` guards on `phase` as well, but only once it is already running.
  func beginStart(isUnattended: Bool = false) {
    guard startTask == nil else { return }
    startTask = Task { [weak self] in
      await self?.start(isUnattended: isUnattended)
      self?.startTask = nil
    }
  }

  /// The whole start, in three jobs: open storage and pass the migration gate, assemble the
  /// composition, bring its services up. Each is a function below.
  ///
  /// Private: every caller goes through `beginStart`, which holds the attempt on the model
  /// and refuses a second while one runs.
  ///
  /// - Parameter isUnattended: true when the LAUNCHER opened the app: at login, or after a
  ///   crash. Nobody is watching, which is what the startup delay and starting minimised are
  ///   both answers to. A person double-clicking the app, or pressing Start, is not this;
  ///   see `LauncherContract.automaticLaunchArgument` and `AppBehaviourPolicy`.
  private func start(isUnattended: Bool = false) async {
    guard phase.canStart else { return }
    // Whatever the last attempt left attached. A start that stopped at the migration wizard
    // keeps onboarding, Home, the archive and the wizard attached to its storage for as long
    // as the wizard is up; this is where they let go of it, before another is opened.
    await attachments.detachAll()
    phase = .starting
    // Cleared on every exit below, so the stage cannot outlive the attempt that set it.
    defer { startupStage = nil }
    do {
      let options = LaunchOptions.current.compositionOptions
      guard let storage = try await openStorage(options: options) else { return }
      let built = try await assemble(storage: storage, options: options, isUnattended: isUnattended)
      try await bringUp(built, isUnattended: isUnattended)
    } catch {
      // Everything attached so far is detached, the composition (if one got as far as
      // existing) stopped, before the phase moves. A failure that leaves the composition
      // running is not just a leak: it holds `app.db`, and the user's next press of Start
      // then fails on a busy database rather than on whatever went wrong the first time.
      await attachments.detachAll()
      // Kept in the UI rather than only logged. A server that failed to start is the
      // one moment the user most needs to be told why, and the log viewer is itself
      // part of the window that just failed to become useful.
      phase = .failed(DiagnosticText.sentence(for: error))
    }
  }

  /// The first job: the instance lock, storage, what needs only storage, and the migration
  /// gate. Nil when the gate stopped the start and the wizard is showing; what was attached
  /// stays attached for it.
  ///
  /// Storage is opened HERE (after the lock, before anything is built) for three reasons.
  /// The lock means two copies cannot migrate at once. Nothing has been constructed, so
  /// there is no half-built server to tear down. And the same storage is handed to `build`
  /// afterwards rather than re-opened, because `SettingsStore` caches the whole table in
  /// memory and a second store would silently disagree with the first after either wrote.
  private func openStorage(
    options: ServerComposition.Options
  ) async throws -> ServerComposition.Storage? {
    startupStage = .checkingForAnotherCopy
    // Before anything is built. Two instances fight over the port AND the Private API
    // socket; see SingleInstanceLock. Inside the caller's `do` so the app surfaces it as a
    // normal startup failure with a readable reason, rather than crashing.
    try SingleInstanceLock.acquire()

    startupStage = .openingStorage
    let storage = try await ServerComposition.prepareStorage(options: options)
    // Before the migration gate, so the wizard's Start Server path and an ordinary start
    // both see this server's walkthrough state rather than the Mac's.
    await attachments.attach(onboarding) { await $0.attach(storage.settings) }
    // Home's depth, from the same storage at the same moment: the page is showing before
    // the server is up, and should already be at the depth the person chose.
    await attachments.attach(home) { await $0.attach(storage.settings) }
    // Exporting a server that is blocked on the wizard is a reasonable thing to want, and
    // it needs no running services.
    await attachments.attach(archive) { $0.attach(storage: storage) }

    startupStage = .checkingForAnExistingInstall
    let status = await MigrationStateStore.status(in: storage.settings)
    if let refusal = status.refusal {
      // Headless has no window to present a sheet from: `BlueBubblesApp` calls
      // `AppBehaviour.closeMainWindow()` before this runs, so it takes the CLI's answer
      // instead: fail loudly, and say what to run. Silently starting on defaults is the
      // outcome this whole path exists to prevent.
      guard !options.headless else { throw refusal }
      await attachments.attach(migration) { $0.attach(storage: storage, status: status) }
      migration.present()
      phase = .migrationRequired
      return nil
    }
    return storage
  }

  /// The second job: build the composition, attach what has to exist before its services
  /// start, and honour the startup delay.
  private func assemble(
    storage: ServerComposition.Storage, options: ServerComposition.Options, isUnattended: Bool
  ) async throws -> RunningServer {
    startupStage = .assembling
    let built = try await ServerComposition.build(storage: storage, options: options)
    let context = built.context
    // Before the delay, not after: during a 30-second startup delay the settings screen
    // should still open, so someone who set the delay too high can reach the row that sets
    // it.
    await attachments.attach(settings) { await $0.attach(context.settings) }
    // Recorded AFTER settings so it runs BEFORE settings detaches, and from here every way
    // out (a stop, or a failure anywhere below) stops the composition. Without it a failed
    // start left the composition running and unreferenced, holding `app.db`, and the next
    // attempt failed on `SQLITE_BUSY` with an error that had nothing to do with the first.
    attachments.onDetach("server") { [weak self] in
      await built.stop()
      self?.server = nil
    }
    await attachments.attach(updates) {
      $0.attach(context.settings, alerts: context.alerts, announcer: context.updateAnnouncer)
    }
    await attachments.attach(updater) {
      await $0.attach(
        context.settings, alerts: context.alerts, announcer: context.updateAnnouncer)
    }
    // The "Updated to X" notice, in its own task: it is the one thing on this path that
    // is allowed to be late.
    Task { [updates] in await updates.noteVersionChange() }
    // Whether a scheduled relaunch may happen now: not while a scheduled message is
    // about to go out. A read that fails answers "not quiet", because a relaunch on top
    // of a schedule this could not see is the one outcome the check exists to prevent;
    // the install looks again in fifteen minutes.
    updater.isQuiet = { [weak self] in
      guard let schedule = self?.messaging.scheduling else { return true }
      guard let pending = try? await schedule.list(status: .pending) else { return false }
      return InstallWindow.isQuiet(scheduled: pending.map(\.scheduledFor), now: Date())
    }
    // Only when it can actually install. Left nil, the endpoint refuses and says no
    // updater is available, which is the truth for a local build.
    if updater.isAvailable {
      await context.setUpdateInstaller(updater)
    }
    // Subscribes and seeds, BEFORE `start()`: the switched-off defaults the server seeds
    // while it comes up are writes to the same store, and arrive on the stream.
    await attachments.attach(integrations) { await $0.attach(context.settings) }

    if let delay = AppBehaviourPolicy.startDelay(
      await context.settings.get(Settings.startDelay), isUnattended: isUnattended
    ) {
      // The phase carries the countdown, so a stage underneath it would be a second,
      // contradictory answer to "what is happening": "Starting in 30s…" over "Reading the
      // Messages database…", which it has finished doing.
      startupStage = nil
      phase = .waiting(delay)
      try? await Task.sleep(for: delay)
      phase = .starting
    }
    return built
  }

  /// The third job: start the services, then attach and follow what reads a running server.
  private func bringUp(_ built: RunningServer, isUnattended: Bool) async throws {
    // Every follow below, and the health follow here, stops on the same detach.
    attachments.onDetach("follows") { [weak self] in self?.stopFollowingServer() }
    // BEFORE `start()`. The registry publishes a health snapshot on every service
    // transition, including the ones it makes while coming up, so following it here is
    // what turns the longest step of startup into visible progress rather than a spinner.
    // Following it early costs nothing: the stream is the same one, and the seed read
    // answers with every registered service.
    followServiceHealth(built.registry)
    startupStage = .startingServices(name: nil)
    try await built.start()
    server = built
    phase = .running
    let context = built.context
    await attachments.attach(permissions) {
      $0.attach(context.permissions) { context.hasMessageAccess }
    }
    await attachments.attach(alerts) { $0.attach(context.alerts) }
    followAppearance(context.settings)
    followTools(context.tools)
    await attachments.attach(webhooks) { $0.attach(context.webhooks) }
    followPushDevices(context.devices)
    followAuditLog(context.auditEvents)
    followAccessControl(context.accessControl)
    await attachments.attach(metrics) { $0.attach(context.metrics) }
    followClientAddress(context.settings)
    if let sink = built.logSink {
      let isShowing = selection == .logs
      await attachments.attach(logs) { $0.attach(sink, isShowing: isShowing) }
    }
    await applyStartupBehaviour(context.settings, isUnattended: isUnattended)
    // Sparkle keeps its own daily schedule once it is running; a second timer would
    // check the same feed twice a day and could announce an update Sparkle is mid-way
    // through installing. The plain timer is for builds that cannot install.
    if !updater.isAvailable {
      updates.beginChecks()
    }
  }

  /// The menu item. Sparkle's own windows when this build can install; otherwise the plain
  /// feed check, whose result `UpdatesModel.state` carries.
  func checkForUpdates() async {
    if updater.isAvailable {
      updater.checkForUpdates()
    } else {
      await updates.check(userInitiated: true)
    }
  }

  /// Follows the two appearance settings, so a change applies at once. Cancelled by
  /// `stopFollowingServer`; `applyStartupBehaviour` applies them the first time.
  private func followAppearance(_ store: SettingsStore) {
    follow(
      .appearance,
      subscribe: { await store.changes() },
      seed: { _ in },
      apply: { model, change in
        guard !change.changedKeys.isDisjoint(with: Self.appearanceKeys) else { return }
        await model.applyAppearance()
      },
      reset: nil)
  }

  /// The settings that act on the app and the Mac, applied once the server is up.
  ///
  /// After start rather than before, because two of them announce that the server is running:
  /// locking the screen and minimising the window are both "I am done here" gestures, and
  /// performing them before a start that then fails would hide the failure.
  private func applyStartupBehaviour(_ store: SettingsStore, isUnattended: Bool) async {
    await applyAppearance()

    // Three conditions, not one; see `AppBehaviourPolicy.shouldStartMinimized`. Setup is
    // the interesting one: `RootView` presents the walkthrough as a SHEET the moment the
    // phase reaches `.running`, so minimising here put a modal dialogue behind a minimised
    // window, which is what the person reporting this met after migrating.
    if AppBehaviourPolicy.shouldStartMinimized(
      configured: await store.get(Settings.startMinimized),
      isUnattended: isUnattended,
      isAwaitingSetup: !onboarding.isComplete || migration.isPresented
    ) {
      AppBehaviour.minimizeMainWindow()
    }

    if AppBehaviourPolicy.shouldOpenFindMy(
      enabled: await store.get(Settings.openFindMyOnStartup),
      cacheIsReadable: !FindMy.cacheIsEncrypted
    ) {
      AppBehaviour.openFindMy()
    }

    if AppBehaviourPolicy.shouldLock(
      enabled: await store.get(Settings.autoLockMac),
      uptime: AppBehaviour.systemUptime
    ) {
      do {
        try await ScreenLock.lock()
      } catch {
        // Never fatal. Failing to lock is worth saying, and is not worth refusing to
        // run the server over.
        await server?.context.alerts.raise(
          UserAlert(
            severity: .warning,
            title: "Could not lock the Mac",
            body: DiagnosticText.sentence(for: error),
            source: "app",
            dedupeKey: "lock-screen-failed"
          )
        )
      }
    }
  }

  /// Dock icon and badge. Continuous: reapplied whenever either setting changes, and
  /// whenever the unread count moves.
  func applyAppearance() async {
    // Nothing to apply before there are settings to apply: `start` calls this once they
    // exist, and the unread count moving before then has no Dock policy to change.
    guard settings.isAvailable else { return }
    let hiddenBySetting: Bool
    let badgeEnabled: Bool
    do {
      hiddenBySetting = try await settings.get(Settings.hideDockIcon)
      badgeEnabled = try await settings.get(Settings.dockBadge)
    } catch {
      // `ServerNotRunning`, the only thing these reads throw: the server stopped between
      // the guard and the read, and the next start applies the appearance again.
      return
    }
    // A headless launch keeps the accessory policy whatever the setting says.
    //
    // `--headless` sets `.accessory` and closes the window at launch, and this method then
    // reapplied the policy from `hide_dock_icon` alone, which defaults to off. So a headless
    // run ended up with a Dock icon and no window the moment startup finished: the one shape
    // that cannot be recovered from, since clicking the icon is how you would ask for a
    // window back. The flag was read in exactly two places in this module and neither was
    // here.
    let hidden = AppBehaviourPolicy.shouldHideDockIcon(
      isHeadless: LaunchOptions.current.isHeadless, hideDockIconSetting: hiddenBySetting)
    AppBehaviour.applyDockVisibility(hidden: hidden)
    AppBehaviour.applyDockBadge(
      count: alerts.unreadCount,
      enabled: badgeEnabled
    )
  }

  /// Detaches everything the start attached, the composition included.
  ///
  /// From `.migrationRequired` there is no server and nothing to stop: what the wizard holds
  /// stays attached until the next start releases it.
  func stop() async {
    guard server != nil else { return }
    phase = .stopping
    await attachments.detachAll()
    phase = .idle
  }

  func restart() async {
    await stop()
    beginStart()
  }

  /// Marks the app as on its way out, so the UI stops reading live service state.
  ///
  /// Quitting does NOT go through `stop()`. Every route out (⌘Q, the menu bar's Quit,
  /// `osascript`, a logout, a signal) reaches `applicationShouldTerminate`, which stops the
  /// SERVER directly and never touches the phase. So the phase stayed
  /// `.running` while every service shut down, and the sidebar went on interpreting their
  /// health as live: a connection method reporting `.stopped` mid-shutdown renders as
  /// "Reconnecting Tailscale…", which is the opposite of what is happening.
  ///
  /// Only the phase. The shutdown itself is the delegate's, and it has a deadline this must
  /// not sit in front of.
  func beginShutdown() {
    guard phase != .idle else { return }
    phase = .stopping
  }

  /// Restarts one service by name, for an alert's `.retry` action.
  ///
  /// The registry already supervises services with backoff; this is the manual override for
  /// when a user has fixed the underlying cause (plugged the network back in, restarted
  /// their tunnel) and does not want to wait out the next attempt.
  func restartService(named service: String) async {
    guard let registry = server?.registry else { return }
    await registry.restart(ServiceIdentifier(service))
  }

  /// Lifts a rate-limit block, for an alert's `.unblock` action.
  ///
  /// An accidental lockout is one click where the problem was reported, rather than a hunt
  /// through the Security page.
  func unblock(address: String) async {
    guard let context = server?.context else { return }
    await asOperator { await context.accessControl.unblock(address: address) }
  }

  // MARK: - Navigation

  /// The sidebar's rows. Every page but the Audit Log is always there; that one is shown
  /// while its feature is on and hidden while it is off or unknown (no server running).
  /// `SidebarDestinations` is the rule; this supplies the one fact it needs.
  var visibleDestinations: [Destination] {
    let enabled: Bool? =
      integrations.isAttached
      ? IntegrationCatalog.manifest(BuiltInManifests.ID.auditLog).map(integrations.isEnabled)
      : nil
    return SidebarDestinations.visible(auditLogEnabled: enabled)
  }

  /// Opens a service's own page.
  func open(_ id: ServiceIdentifier) {
    selection = .integrations
    detailPath = [id]
  }

  /// Surfaces a failure the person caused and would otherwise never see: a settings
  /// write the store refused. A control that silently does nothing is the worst outcome:
  /// the toggle flips back on the next redraw and nothing says why.
  ///
  /// Through the alert centre when the server is up, so it is persisted and badged like
  /// any other; before that, straight into the drawer.
  func report(_ error: any Error, while action: String) async {
    let alert = UserAlert(
      severity: .warning,
      title: "Could not \(action)",
      body: DiagnosticText.sentence(for: error),
      source: "app",
      dedupeKey: nil
    )
    await alerts.raise(alert)
  }

  /// Relaunches the app.
  ///
  /// Full Disk Access does not take effect until the process restarts: the grant applies
  /// at open time, so "grant it and nothing happens" is the single most common way users
  /// get this wrong. The Permissions page offers this button once the grant is detected.
  ///
  /// The new copy is only opened, and this one only quits, once it is known to have
  /// worked: a relaunch that could not open anything says so and leaves the server running.
  func relaunch() async {
    switch RelaunchRoute.choose(launcherIsSupervising: LauncherSupervision.isActive) {
    case .handToLauncher:
      LauncherContract.writeIntent(.restart)
      AppTermination.quit()

    case .reopenAfterStopping:
      await stop()
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.createsNewApplicationInstance = true
      do {
        _ = try await NSWorkspace.shared.openApplication(
          at: Bundle.main.bundleURL, configuration: configuration)
      } catch {
        beginStart()
        await report(error, while: "relaunch BlueBubbles")
        return
      }
      AppTermination.quit()
    }
  }
}

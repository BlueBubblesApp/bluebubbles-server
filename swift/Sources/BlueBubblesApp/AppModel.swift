//  AppModel
//  The root observable model. Owns the running server; the views read from it.
//
//  There is NO IPC here, and that is the point. View models call the same interfaces layer the
//  HTTP controllers call, in the same process. See `.claude/docs/architecture.md`.

import BBAuth
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
enum ServerPhase: Equatable {
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
  /// Carries no payload. `ServerPhase` is `Equatable` and `HomeView` does
  /// `.task(id: model.phase)`; a plan value holding `@Sendable` closures would kill the
  /// synthesized conformance and take `phase == .idle` with it. The plan lives on
  /// `AppModel.migration` instead.
  case migrationRequired

  var isRunning: Bool { self == .running }

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

@Observable
@MainActor
final class AppModel {

  private(set) var phase: ServerPhase = .idle
  private(set) var server: RunningServer?

  /// The four concerns with their own state and lifetime. Each attaches to the running
  /// server in `start` and detaches in `stop`; the views reach them as `model.alerts` etc.
  let permissions = PermissionsModel()
  let alerts = AlertsModel()
  let updates = UpdatesModel()
  let integrations = IntegrationsModel()
  let onboarding = OnboardingModel()
  let migration = MigrationModel()

  init() {
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
  var selection: Destination = .home

  /// Resolved once at start. `AppContext` is an actor, so reaching the store per settings
  /// row would serialise every row's load behind one actor hop.
  private(set) var settingsStore: SettingsStore?

  /// Firebase setup state and its in-flight work.
  ///
  /// Owned here, not by `FirebaseView`. Guided provisioning takes minutes, and anything a
  /// view holds in `@State` (including the `Task` running the work) dies when the detail
  /// column shows another page. Held here, the run continues and the screen re-attaches to
  /// it with its progress intact.
  let firebaseSetup = FirebaseSetupModel()

  /// The whole container. PRIVATE, and the accessors below are why.
  ///
  /// `HandlerCapabilities` exists because handing a component the whole `AppContext` is an
  /// undeclared dependency: the type says "everything", so nothing states what the component
  /// actually needs and nothing can exercise it without a running server. The HTTP
  /// controllers take narrow capabilities; the app is the OTHER consumer of that same layer
  /// and takes them the same way.
  ///
  /// So the doors are narrow and named. A screen that wants the tool manager asks for the
  /// tool manager, and what it gets back cannot also read the message database.
  /// The running server's container.
  ///
  /// Deliberately private, and the reason the facades below work: a view cannot obtain an
  /// `AppContext`, so it cannot build a `SecurityAccess` of its own or reach past the doors
  /// this file opens. `ServerAccess.swift` reads it through `serverContext`.
  private var context: AppContext? { server?.context }

  /// The one internal seam, for the facades in `ServerAccess.swift`. Not for views: reaching
  /// for this from a screen is reaching for everything, which is what the grouping exists to
  /// stop.
  var serverContext: AppContext? { context }

  // MARK: - Narrow access
  //
  // Four cross-cutting doors stay here because they have no natural group and because the
  // model's own extensions use them: `ToolActions` drives `tools` and raises through
  // `alertCenter`, and `settings` is read by most screens for unrelated reasons. Everything
  // else is grouped; see `ServerAccess.swift` for `security`, `messaging` and `delivery`.
  //
  // Nil whenever the server is not running, which is every accessor's normal state: the app
  // opens before the server starts, and screens are expected to render without one.

  var settings: SettingsStore? { context?.settings }
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
  var toolsTask: Task<Void, Never>?

  /// The registry's view of each service, followed for the life of the server; see
  /// `followServiceHealth`.
  var serviceHealths: [ServiceIdentifier: ServiceHealth] = [:]
  var healthTask: Task<Void, Never>?

  /// The Private API runtime's state, followed while the server holds one; see
  /// `PrivateAPIObservation.swift`. Nil when there is no runtime to follow.
  var privateAPIState: PrivateAPIRuntime.State?
  var privateAPITask: Task<Void, Never>?
  var followedPrivateAPIRuntime: ObjectIdentifier?

  /// The tail of the server's log, followed for the life of the server; see
  /// `LogObservation.swift`. Empty when there is no server.
  var logLines: [LogLine] = []
  var logTask: Task<Void, Never>?
  /// Where that log is on disk, for Reveal in Finder. Nil when there is no server.
  var logFileURL: URL?

  /// The address clients connect to, as the running connection method last published it;
  /// see `AddressObservation.swift`. Empty when nothing has been published yet, and when
  /// there is no server.
  var publishedAddress = ""
  var addressTask: Task<Void, Never>?

  /// What each webhook's last delivery did, followed from the tracker for the life of the
  /// server; see `WebhookObservation.swift`. Empty when there is no server.
  var webhookDeliveries: [Int64: WebhookDeliveryState] = [:]
  var webhookDeliveriesTask: Task<Void, Never>?
  /// Bumped on every change to the webhook table, so the page's own read can be keyed on
  /// it. A counter rather than the rows: the read is the page's, and it throws.
  var webhookRegistrationsVersion = 0
  var webhookRegistrationsTask: Task<Void, Never>?

  /// Who is blocked, exempt, or failing, followed from the access-control service for the
  /// life of the server; see `AccessControlObservation.swift`. Nil when there is no server.
  var accessControl: AccessControlSnapshot?
  var accessControlTask: Task<Void, Never>?

  private var appearanceTask: Task<Void, Never>?

  /// The app-level settings that take effect immediately.
  ///
  /// Watched here rather than by a service because no service owns them: they act on this
  /// process's Dock presence, which the server has no opinion about.
  static let appearanceKeys: Set<String> = [Settings.hideDockIcon.key, Settings.dockBadge.key]

  // MARK: - Lifecycle

  /// - Parameter isAutomatic: true when the app started this itself at launch. The startup
  ///   delay applies only then: a delay on a button press is a button that appears broken.
  func start(isAutomatic: Bool = false) async {
    // `.migrationRequired` is in the set, and must be: it is the phase the wizard leaves
    // behind, so without it the "I am done, start now" call returns silently and the user
    // is left looking at a finished wizard and a stopped server.
    guard phase == .idle || isFailed || phase == .migrationRequired else { return }
    phase = .starting
    do {
      // Before anything is built. Two instances fight over the port AND the Private
      // API socket; see SingleInstanceLock. Inside the `do` so the app surfaces it as
      // a normal startup failure with a readable reason, rather than crashing.
      try SingleInstanceLock.acquire()

      // Storage first, then the question: is there an Electron installation nobody has
      // adopted? Asked HERE (after the lock, before anything is built) for three reasons.
      // The lock means two copies cannot migrate at once. Nothing has been constructed, so
      // there is no half-built server to tear down. And the same storage is handed to
      // `build` afterwards rather than re-opened, because a second connection to `app.db`
      // throws `SQLITE_BUSY` (GRDB defaults `busyMode` to `.immediateError`) and a second
      // `SettingsStore` would keep its own stale cache.
      let options = LaunchOptions.current.compositionOptions
      let storage = try await ServerComposition.prepareStorage(options: options)
      let status = await MigrationStateStore.status(in: storage.settings)

      if status.isBlockingStart {
        // Headless has no window to present a sheet from: `BlueBubblesApp` calls
        // `AppBehaviour.closeMainWindow()` before this runs, so it takes the CLI's answer
        // instead: fail loudly, and say what to run. Silently starting on defaults is the
        // outcome this whole path exists to prevent.
        guard !options.headless else {
          throw MigrationPending(steps: status.blocking.map(\.step))
        }
        migration.attach(storage: storage, status: status)
        migration.present()
        phase = .migrationRequired
        return
      }

      let built = try await ServerComposition.build(storage: storage, options: options)
      // Published before the delay, not after: during a 30-second startup delay the
      // settings screen should still open, so someone who set the delay too high can
      // reach the row that sets it.
      settingsStore = built.context.settings
      updates.attach(built.context.settings)
      await integrations.attach(built.context.settings)

      if let delay = AppBehaviourPolicy.startDelay(
        await built.context.settings.get(Settings.startDelay), isAutomatic: isAutomatic
      ) {
        phase = .waiting(delay)
        try? await Task.sleep(for: delay)
        phase = .starting
      }

      try await built.start()
      server = built
      phase = .running
      // The wizard's work is done and its storage now belongs to the running server.
      // Cleared so a later stop/start does not re-present it.
      migration.finish()
      // Read once the store exists, and NOT only when a switch is flipped. This was
      // refreshed from `toggle` and `select` alone, so on every launch the app started
      // with an empty disabled set: every service rendered as enabled until you
      // touched one, whatever the settings actually said.
      await integrations.refresh()
      let context = built.context
      permissions.attach(context.permissions) { context.hasMessageAccess }
      alerts.attach(context.alerts)
      beginObservingAppearance(context.settings)
      followServiceHealth(built.registry)
      followTools(context.tools)
      followWebhooks(context.webhooks)
      followAccessControl(context.accessControl)
      followPublishedAddress(context.settings)
      if let sink = built.logSink { followLog(sink) }
      await applyStartupBehaviour()
      updates.beginChecks()
    } catch {
      // Kept in the UI rather than only logged. A server that failed to start is the
      // one moment the user most needs to be told why, and the log viewer is itself
      // part of the window that just failed to become useful.
      phase = .failed(DiagnosticText.sentence(for: error))
    }
  }

  private func beginObservingAppearance(_ store: SettingsStore) {
    appearanceTask?.cancel()
    appearanceTask = Task { [weak self] in
      for await change in await store.changes() {
        guard !change.changedKeys.isDisjoint(with: Self.appearanceKeys) else { continue }
        await self?.applyAppearance()
      }
    }
  }

  /// The settings that act on the app and the Mac, applied once the server is up.
  ///
  /// After start rather than before, because two of them announce that the server is running:
  /// locking the screen and minimising the window are both "I am done here" gestures, and
  /// performing them before a start that then fails would hide the failure.
  private func applyStartupBehaviour() async {
    guard let store = settingsStore else { return }

    await applyAppearance()

    if await store.get(Settings.startMinimized) {
      AppBehaviour.minimizeMainWindow()
    }

    if await store.get(Settings.openFindMyOnStartup) {
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
    guard let store = settingsStore else { return }
    AppBehaviour.applyDockVisibility(hidden: await store.get(Settings.hideDockIcon))
    AppBehaviour.applyDockBadge(
      count: alerts.unreadCount,
      enabled: await store.get(Settings.dockBadge)
    )
  }

  func stop() async {
    guard let server else { return }
    phase = .stopping
    permissions.detach()
    alerts.detach()
    updates.detach()
    integrations.detach()
    appearanceTask?.cancel()
    stopFollowingServer()
    await server.stop()
    self.server = nil
    settingsStore = nil
    phase = .idle
  }

  func restart() async {
    await stop()
    await start()
  }

  /// Marks the app as on its way out, so the UI stops reading live service state.
  ///
  /// Quitting does NOT go through `stop()`. Every route out except the menu bar's own
  /// button (⌘Q, `osascript`, a logout, a signal) reaches `applicationShouldTerminate`,
  /// which stops the SERVER directly and never touches the phase. So the phase stayed
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

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
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
    await context.accessControl.unblock(address: address)
  }

  // MARK: - Navigation

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
  func relaunch() {
    let url = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
      Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
  }
}

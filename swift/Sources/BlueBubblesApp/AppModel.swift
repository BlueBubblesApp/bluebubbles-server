//  AppModel
//  The root observable model. Owns the running server; the views read from it.
//
//  There is NO IPC here, and that is the point. View models call the same interfaces layer the
//  HTTP controllers call, in the same process. The Electron app needed 68 `ipcMain.handle`
//  channels — one per operation, hand-written on both sides — purely because the UI ran in a
//  different process from the business logic. See `.claude/docs/architecture.md`.

import BBAuth
import BBContacts
import BBDiagnostics
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
  /// WHY nothing is happening — a silent thirty-second pause reads as a hang.
  case waiting(Duration)
  case running
  case stopping
  case failed(String)

  var isRunning: Bool { self == .running }

  /// Mid-transition: the Start/Stop button has nothing useful to do. `.waiting` counts —
  /// the server is on its way up, and offering Start again during the delay would look
  /// like the first press was ignored.
  var isBusy: Bool {
    switch self {
    case .starting, .waiting, .stopping: true
    case .idle, .running, .failed: false
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
    }
  }
}

@Observable
@MainActor
final class AppModel {

  private(set) var phase: ServerPhase = .idle
  private(set) var server: RunningServer?

  /// Which service each exclusive category has selected, and which additive ones are off.
  var selectedConnectionMethod: String = ""
  var disabledServices: Set<String> = []

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

  /// Live permission state, refreshed continuously while the Permissions page is open.
  ///
  /// The single biggest usability gap in the current app: today a permission granted in
  /// System Settings is not reflected until the user navigates away and back, so people
  /// grant a permission, see no change, and conclude it did not work.
  private(set) var permissions: [PermissionID: PermissionStatus] = [:]
  private(set) var permissionsCheckedAt: Date?

  /// Resolved once at start. `AppContext` is an actor, so reaching the store per settings
  /// row would serialise every row's load behind one actor hop.
  private(set) var settingsStore: SettingsStore?
  var logSink: FileSink? { server?.logSink }

  private(set) var alerts: [UserAlert] = []
  private(set) var unreadAlertCount = 0

  /// Firebase setup state and its in-flight work.
  ///
  /// Owned here, not by `FirebaseView`. Guided provisioning takes minutes, and anything a
  /// view holds in `@State` — including the `Task` running the work — dies when the detail
  /// column shows another page. Held here, the run continues and the screen re-attaches to
  /// it with its progress intact.
  let firebaseSetup = FirebaseSetupModel()

  /// Set once onboarding has been completed or explicitly skipped.
  var hasCompletedOnboarding: Bool {
    get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
    set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
  }

  /// The whole container. PRIVATE, and the accessors below are why.
  ///
  /// `HandlerCapabilities` exists because handing a component the whole `AppContext` is an
  /// undeclared dependency: the type says "everything", so nothing states what the component
  /// actually needs and nothing can exercise it without a running server. The HTTP
  /// controllers have taken narrow capabilities since the beginning. The app is the OTHER
  /// consumer of that same layer and had been taking the container wholesale — thirty-five
  /// reads of `model.context` across thirteen view files, reaching a dozen different members.
  ///
  /// So the doors are narrow and named. A screen that wants the tool manager asks for the
  /// tool manager, and what it gets back cannot also read the message database.
  private var context: AppContext? { server?.context }

  // MARK: - Narrow access

  /// Nil whenever the server is not running, which is every accessor's normal state — the
  /// app opens before the server starts, and screens are expected to render without one.
  var settings: SettingsStore? { context?.settings }
  var alertCenter: AlertCenter? { context?.alerts }
  var tools: ToolManager? { context?.tools }
  var permissionsService: PermissionsService? { context?.permissions }
  var accessControl: AccessControlService? { context?.accessControl }
  var tokenAuth: TokenAuthService? { context?.tokenAuth }
  var serverAdmin: ServerInterface? { context?.server }
  var scheduling: ScheduleInterface? { context?.schedule }
  var contactIndex: ContactIndex? { context?.contacts }

  /// The push setup, as a capability rather than as the context it lives on.
  ///
  /// Handed to `FirebaseSetupModel`, which is the one part of the app with real signatures
  /// to constrain: it took `AppContext?` on twelve methods and used exactly
  /// `pushInterface()` from it.
  var pushSetup: (any PushSetupProviding)? { context }
  var webhookAdmin: (any WebhookAdministering)? { context }

  /// Resolved per call, both of them, because what is behind them is replaced while the
  /// server runs — see `PrivateAPIProviding`.
  func interfaces() async -> ServerInterfaces? { await context?.interfaces() }
  func faceTime() async -> FaceTimeCoordinator? { await context?.faceTime() }
  func ownMessagingAddress() async -> String? { await context?.ownMessagingAddress() }
  func groupChatShortcuts() async -> GroupChatShortcutManager? {
    await context?.groupChatShortcuts()
  }
  var privateAPIAccess: (any PrivateAPIRuntimeProviding)? { context }
  var isHelperConnected: Bool {
    get async { await context?.isHelperConnected ?? false }
  }

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
  /// How many views are currently watching tool status. See `beginObservingTools`.
  var toolObservers = 0

  private var permissionsTask: Task<Void, Never>?
  private var alertsTask: Task<Void, Never>?
  private var appearanceTask: Task<Void, Never>?

  /// The app-level settings that take effect immediately.
  ///
  /// Watched here rather than by a service because no service owns them: they act on this
  /// process's Dock presence, which the server has no opinion about.
  static let appearanceKeys: Set<String> = ["hide_dock_icon", "dock_badge"]

  // MARK: - Lifecycle

  /// - Parameter isAutomatic: true when the app started this itself at launch. The startup
  ///   delay applies only then — a delay on a button press is a button that appears broken.
  func start(isAutomatic: Bool = false) async {
    guard phase == .idle || isFailed else { return }
    phase = .starting
    do {
      // Before anything is built. Two instances fight over the port AND the Private
      // API socket — see SingleInstanceLock. Inside the `do` so the app surfaces it as
      // a normal startup failure with a readable reason, rather than crashing.
      try SingleInstanceLock.acquire()

      let built = try await ServerComposition.build(
        options: LaunchOptions.parse().compositionOptions
      )
      // Published before the delay, not after: during a 30-second startup delay the
      // settings screen should still open, so someone who set the delay too high can
      // reach the row that sets it.
      settingsStore = built.context.settings

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
      // Read once the store exists, and NOT only when a switch is flipped. This was
      // refreshed from `toggle` and `select` alone, so on every launch the app started
      // with an empty disabled set — every service rendered as enabled until you
      // touched one, whatever the settings actually said.
      await refreshIntegrationState()
      beginObserving(built)
      beginObservingAppearance(built.context.settings)
      await applyStartupBehaviour()
      beginUpdateChecks()
    } catch {
      // Kept in the UI rather than only logged. A server that failed to start is the
      // one moment the user most needs to be told why, and the log viewer is itself
      // part of the window that just failed to become useful.
      phase = .failed(String(describing: error))
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
  /// After start rather than before, because two of them announce that the server is running
  /// — locking the screen and minimising the window are both "I am done here" gestures, and
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
            body: String(describing: error),
            source: "app",
            dedupeKey: "lock-screen-failed"
          )
        )
      }
    }
  }

  /// Dock icon and badge. Continuous — reapplied whenever either setting changes, and
  /// whenever the unread count moves.
  func applyAppearance() async {
    guard let store = settingsStore else { return }
    AppBehaviour.applyDockVisibility(hidden: await store.get(Settings.hideDockIcon))
    AppBehaviour.applyDockBadge(
      count: unreadAlertCount,
      enabled: await store.get(Settings.dockBadge)
    )
  }

  func stop() async {
    guard let server else { return }
    phase = .stopping
    permissionsTask?.cancel()
    alertsTask?.cancel()
    appearanceTask?.cancel()
    updateCheckTask?.cancel()
    await server.stop()
    self.server = nil
    settingsStore = nil
    phase = .idle
  }

  func restart() async {
    await stop()
    await start()
  }

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }

  // MARK: - Observation

  private func beginObserving(_ server: RunningServer) {
    // `AppContext` is an actor, so these hops are real. Reading the two services once
    // here rather than per iteration keeps the polling loop below off the actor.
    let context = server.context

    // Polled rather than pushed: macOS does not notify on a TCC change, so there is
    // nothing to subscribe to. Two seconds is fast enough to feel immediate when the
    // user tabs back from System Settings, and each check is cheap — the expensive one
    // (Full Disk Access) is an attempted file open.
    permissionsTask = Task { [weak self] in
      let permissionsService = context.permissions
      while !Task.isCancelled {
        let states = await permissionsService.checkAll()
        await MainActor.run {
          self?.permissions = states
          self?.permissionsCheckedAt = Date()
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }

    alertsTask = Task { [weak self] in
      let center = context.alerts
      // Seeded first, so the drawer is populated on open rather than only after the
      // next alert arrives.
      let existing = await center.all(limit: 200)
      let unread = await center.badgeCount()
      await MainActor.run {
        self?.alerts = existing
        self?.unreadAlertCount = unread
      }

      for await alert in await center.stream() {
        await MainActor.run {
          self?.alerts.insert(alert, at: 0)
          self?.unreadAlertCount += 1
          // The badge is a view of this number, so it moves with it rather than
          // only at startup.
          Task { await self?.applyAppearance() }
        }
      }
    }
  }

  /// The declared permission list, in onboarding order.
  var permissionList: [Permission] {
    server?.context.permissions.permissions ?? []
  }

  /// Required permissions currently unmet. Drives the sidebar badge and the banner.
  var unsatisfiedRequiredCount: Int {
    permissionList.filter { permission in
      permission.requirement.isRequired
        && (permissions[permission.id] ?? .notDetermined) != .granted
    }.count
  }

  /// Whether Full Disk Access has been granted since this process started.
  ///
  /// The grant applies at process launch, so a running server that was started without it
  /// still cannot read chat.db — the permission reads as granted while the database stays
  /// shut. Offering a relaunch is the only thing that resolves it, and not saying so is
  /// how "I granted it and nothing happened" happens.
  var needsRelaunch: Bool {
    permissions[.fullDiskAccess] == .granted && hasMessageAccess == false
  }

  private(set) var hasMessageAccess: Bool?

  /// Records that setup proceeded without a required permission.
  ///
  /// Kept so a later support conversation can distinguish "was never asked" from "was
  /// asked and chose to continue" — which are different problems with different fixes.
  func recordOnboardingSkip(_ ids: [String]) {
    UserDefaults.standard.set(ids, forKey: "onboardingSkippedPermissions")
    UserDefaults.standard.set(Date(), forKey: "onboardingSkippedAt")
  }

  func request(_ id: PermissionID) async {
    guard let context = server?.context else { return }
    await context.permissions.request(id)
  }

  private var updateCheckTask: Task<Void, Never>?

  /// How often an automatic check runs.
  ///
  /// Daily. An appcast is a static file and a server that runs for months should learn about
  /// a release without being restarted, but nothing about this is urgent enough to poll more
  /// often than a person would look.
  static let updateCheckInterval: Duration = .seconds(24 * 60 * 60)

  /// Starts the periodic check, if the user asked for one.
  ///
  /// This is what the automatic-update-check setting controls; without it the toggle
  /// governs nothing and only the "Check for Updates…" menu item does anything. Re-read on
  /// every tick rather than captured, so turning it off stops the next check rather than
  /// needing a restart.
  func beginUpdateChecks() {
    updateCheckTask?.cancel()
    updateCheckTask = Task { [weak self] in
      // A short settle before the first check: launch is busy, and an update banner is
      // the least urgent thing competing for that moment.
      try? await Task.sleep(for: .seconds(30))
      while !Task.isCancelled {
        guard let self, let store = self.settingsStore else { return }
        if await store.get(Settings.checkForUpdates) {
          await self.checkForUpdates()
        }
        try? await Task.sleep(for: Self.updateCheckInterval)
      }
    }
  }

  func checkForUpdates() async {
    // Routed through the same checker the API uses, so the menu item and
    // GET /server/update/check can never disagree about whether an update exists.
    guard let store = settingsStore else { return }
    updateCheck = .checking
    do {
      let checker = UpdateChecker(
        feedURL: await store.get(Settings.updateFeedURL),
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
          as? String ?? "0.0.0-dev"
      )
      let result = try await checker.check()
      updateCheck =
        result.isAvailable
        ? .available(result.item?.shortVersion ?? "?")
        : .upToDate
    } catch {
      updateCheck = .failed(String(describing: error))
    }
  }

  private(set) var updateCheck: UpdateCheckState = .idle

  enum UpdateCheckState: Equatable {
    case idle, checking, upToDate
    case available(String)
    case failed(String)
  }

  func refreshPermissions() async {
    guard let context = server?.context else { return }
    permissions = await context.permissions.checkAll()
    hasMessageAccess = await context.hasMessageAccess
    permissionsCheckedAt = Date()
  }

  func markAlertsRead() async {
    guard let center = server?.context.alerts else { return }
    await center.markAllRead()
    unreadAlertCount = 0
    alerts = await center.all(limit: 200)
  }

  /// Marks one alert read or unread, for the drawer's per-row toggle.
  ///
  /// Re-reads the count from the centre rather than adjusting it by one. The centre's
  /// badge counts warnings and above only, so an info alert changing state moves the list
  /// without moving the badge — arithmetic here would drift out of step with it on the
  /// first such alert and stay wrong until the next restart.
  func setAlertRead(_ id: UUID, _ isRead: Bool) async {
    guard let center = server?.context.alerts else { return }
    if isRead {
      await center.markRead([id])
    } else {
      await center.markUnread([id])
    }
    alerts = await center.all(limit: 200)
    unreadAlertCount = await center.badgeCount()
    await applyAppearance()
  }

  /// Relaunches the app.
  ///
  /// Full Disk Access does not take effect until the process restarts — the grant applies
  /// at open time — so "grant it and nothing happens" is the single most common way users
  /// get this wrong. The Permissions page offers this button once the grant is detected.
  /// Restarts one service by name, for an alert's `.retry` action.
  ///
  /// The registry already supervises services with backoff; this is the manual override for
  /// when a user has fixed the underlying cause — plugged the network back in, restarted
  /// their tunnel — and does not want to wait out the next attempt.
  func restartService(named service: String) async {
    guard let registry = server?.registry else { return }
    await registry.restart(ServiceID(service))
  }

  /// Lifts a rate-limit block, for an alert's `.unblock` action.
  ///
  /// An accidental lockout is one click where the problem was reported, rather than a hunt
  /// through the Security page.
  func unblock(address: String) async {
    guard let context = server?.context else { return }
    await context.accessControl.unblock(address: address)
  }

  // MARK: - Integrations

  /// Whether a service is currently enabled.
  ///
  /// Two different questions behind one word, which is why this branches. In an EXCLUSIVE
  /// category "enabled" means "this is the one selected" — there is a single value naming a
  /// winner. Everywhere else it is an independent switch with its own stored flag.
  func isEnabled(_ manifest: ServiceManifest) -> Bool {
    if manifest.category.isExclusive {
      return selectedConnectionMethod == manifest.id.rawValue
    }
    return !disabledServices.contains(manifest.id.rawValue)
  }

  /// Picks a service within an exclusive category.
  /// Opens a service's own page.
  func open(_ id: ServiceIdentifier) {
    selection = .integrations
    detailPath = [id]
  }

  func select(_ manifest: ServiceManifest) async {
    guard let store = settingsStore, manifest.category.isExclusive else { return }
    try? await store.set(Settings.connectionMethod, to: manifest.id.rawValue)
    await refreshIntegrationState()
  }

  /// Turns an additive service on or off.
  func toggle(_ manifest: ServiceManifest) async {
    guard let store = settingsStore else { return }
    var disabled = disabledServices
    if disabled.contains(manifest.id.rawValue) {
      disabled.remove(manifest.id.rawValue)
    } else {
      disabled.insert(manifest.id.rawValue)
    }
    try? await store.set(
      disabled.sorted().joined(separator: ","),
      forKey: Settings.disabledServicesKey,
      isSecret: false
    )
    await refreshIntegrationState()
  }

  /// Re-reads what is enabled.
  ///
  /// Kept as observable state rather than read per row: SwiftUI evaluates `isEnabled` for
  /// every visible service on every redraw, and an `await` per row would make the list
  /// flicker as each resolved.
  func refreshIntegrationState() async {
    guard let store = settingsStore else { return }
    selectedConnectionMethod = await store.get(Settings.connectionMethod)
    disabledServices = Set(
      (await store.string(forKey: Settings.disabledServicesKey) ?? "")
        .split(separator: ",")
        .map(String.init)
    )
  }

  func relaunch() {
    let url = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
      Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
  }
}

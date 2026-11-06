//  AppBehaviour
//  The settings that act on the app and the Mac rather than on the server.
//
//  Dock icon, dock badge, start delay, start minimized, locking the screen, opening FindMy.
//  Six settings that had rows on the General page and no implementation anywhere: the server
//  read none of them, because none of them are the server's business. They belong to the app
//  process, which is why they ended up with nobody to own them.
//
//  Gathered here rather than scattered through views so the decisions can be tested. The
//  decisions are the part worth testing: `shouldLock` in particular reproduces a rule from the
//  Electron server that looks like a bug until you know why it is there.
//
//  See `.claude/docs/architecture.md`.

import AppKit
import BBSystem
import Foundation

/// The choices, separated from the side effects so they can be asserted.
enum AppBehaviourPolicy {

  /// The FindMy app's bundle identifier. Launching it is what refreshes the caches under
  /// `~/Library/Caches/com.apple.findmy.fmipcore` that `BBSystem.FindMy` reads.
  static let findMyBundleID = "com.apple.findmy"

  /// Whether the Dock icon should be hidden, from BOTH of the things that decide it.
  ///
  /// Two inputs, one answer, in one place that a test can reach. They were separate: the
  /// launch path set `.accessory` for `--headless`, and `applyAppearance` then reapplied the
  /// policy from `hide_dock_icon` alone, which defaults to off. So a headless run regained
  /// its Dock icon the moment startup finished, with no window behind it, which is the one
  /// shape a person cannot recover from — clicking the icon is how you would ask for the
  /// window back.
  ///
  /// Headless wins because it is the stronger statement: `--headless` was passed on this
  /// launch, while the setting is a standing preference for the windowed app.
  static func shouldHideDockIcon(isHeadless: Bool, hideDockIconSetting: Bool) -> Bool {
    isHeadless || hideDockIconSetting
  }

  /// Whether to open FindMy now.
  ///
  /// Two conditions, where the setting used to be the only one, and the second is what stops
  /// an opted-in switch from doing something pointless. Opening FindMy refreshes the caches
  /// under `~/Library/Caches/com.apple.findmy.fmipcore`, and Apple encrypted `Devices.data`
  /// in Sequoia: above that release `/findmy/devices` answers `null` however fresh the file
  /// is, so the launch would open somebody's app on every start and change nothing a client
  /// can read.
  ///
  /// It buys nothing for FRIENDS on any release, which is the part that looks like it should
  /// matter and does not. `IMFMFSession` is an IMCore class, live in Messages.app from
  /// launch — see `FindMyBridge` — so `refreshFriends`, the per-handle refresh and the
  /// inbound location events all work with FindMy.app closed. The devices cache is the only
  /// thing this has ever helped.
  ///
  /// - Parameter cacheIsReadable: the inverse of `BBSystem.FindMy.cacheIsEncrypted`, passed
  ///   in rather than read here so the decision can be tested on a Mac of any version.
  static func shouldOpenFindMy(enabled: Bool, cacheIsReadable: Bool) -> Bool {
    enabled && cacheIsReadable
  }

  /// Whether to lock the screen now.
  ///
  /// Only within five minutes of boot, which is the Electron server's rule and is the whole
  /// point of the setting: it exists for a headless Mac that reboots (after a power cut, or
  /// an OS update) and comes back to an unlocked desktop. Without the uptime test the
  /// setting would lock the screen every time the server started, including when the person
  /// sitting in front of it pressed Start, which is why it reads as hostile if you meet it
  /// without the context.
  static func shouldLock(enabled: Bool, uptime: TimeInterval) -> Bool {
    enabled && uptime <= 300
  }

  /// How long to wait before starting services, clamped to the range the setting allows.
  ///
  /// Applied to an UNATTENDED start only: the launch agent started the app at login, or
  /// brought it back after a crash. A delay on a button press is a button that appears not to work,
  /// and a delay on a launch somebody just performed is the same thing one step removed:
  /// they double-clicked BlueBubbles and it sat on "Starting in 30s…". The setting exists so
  /// a login can let the network, a VPN or an external disk come up first, and nothing else.
  ///
  /// "Unattended" is who opened the app, not "the app started itself rather than the Start
  /// button": read the second way, the delay applies to a person opening the app, which is
  /// exactly what it must not do. `LaunchOptions.wasLaunchedAutomatically` is the answer; see
  /// `LaunchAgentContract.automaticLaunchArgument`.
  static func startDelay(_ configured: Double, isUnattended: Bool) -> Duration? {
    guard isUnattended, configured > 0 else { return nil }
    return .seconds(min(max(configured, 0), 600))
  }

  /// Whether this start minimises the window.
  ///
  /// Asked once, as soon as every input is known: directly after the migration gate, when
  /// storage is open and before the composition is built. Waiting for the services leaves a
  /// window on screen for the whole of a start nobody is watching. Asking any earlier answers
  /// "not awaiting setup" for an install the gate is about to stop.
  ///
  /// - `configured`: the person asked for it.
  /// - `isUnattended`: the LAUNCHER opened the app. Somebody who just double-clicked
  ///   BlueBubbles is looking at it, and a window that minimises itself in front of them is
  ///   indistinguishable from a crash. The setting is for the Mac that reboots at 4am.
  /// - `isHeadless`: that launch closes the window from the window's own `.task`, and
  ///   `AppBehaviour.closeMainWindow` passes over a minimised one, so getting in first would
  ///   leave a window behind on a launch that promised none.
  /// - `isAwaitingSetup`: nothing is waiting for an answer. Onboarding and the migration
  ///   wizard are SHEETS on the main window, so minimising puts a modal dialogue somewhere
  ///   nobody can see it and leaves the app looking like it did nothing. A sheet outranks
  ///   the preference every time: the preference will apply on the next start, and there
  ///   will be one, because finishing setup is what makes the app usable at all.
  static func shouldStartMinimized(
    configured: Bool, isUnattended: Bool, isHeadless: Bool, isAwaitingSetup: Bool
  ) -> Bool {
    configured && isUnattended && !isHeadless && !isAwaitingSetup
  }

  /// Whether the main window is showing something only a person can deal with.
  ///
  /// This is what keeps an early minimise from hiding a failure: while it is true, a window
  /// `startMinimisedStep` minimised comes back. The list is what appears on the window with
  /// nobody having touched it: the two setup sheets `RootView` declares, a start that failed
  /// and the migration gate. Every other sheet and panel in the app opens from a click inside
  /// the window, and that click means the person has already taken the window back.
  ///
  /// A running server with a problem is not on the list: a missing permission or a tunnel
  /// that gave up is reported on Home and in the sidebar, and leaves nothing waiting on the
  /// window.
  ///
  /// A `switch` with no default, so a new phase has to be placed here to compile.
  static func mainWindowNeedsPerson(
    phase: ServerPhase, isMigrationPresented: Bool, isOnboardingPresented: Bool
  ) -> Bool {
    if isMigrationPresented || isOnboardingPresented { return true }
    switch phase {
    case .failed, .migrationRequired: return true
    case .idle, .starting, .waiting, .running, .stopping: return false
    }
  }

  /// What starting minimised has done to the main window, and so what it may still do.
  enum StartMinimised: Equatable {
    /// Nothing, or nothing it still answers for: it was not asked to, it undid its own
    /// minimise, or the person took the window back. Any minimised window in this state is
    /// the person's, and stays where they put it.
    case nothingOwed
    /// Decided, with no window on screen to minimise yet. The decision is made as soon as
    /// storage opens, which can be before AppKit has shown the window.
    case awaitingWindow
    /// This path minimised the window and nobody has brought it back.
    case minimised
  }

  /// What `StartMinimisedWindow` does next.
  enum StartMinimisedStep: Equatable {
    case minimise
    case restore
    /// Drop a minimise that has not happened, because something needs the window first.
    case forget
  }

  /// The one decision about moving the window after `shouldStartMinimized` has answered.
  ///
  /// `.nothingOwed` answers nil whatever the window needs, which is the rule that a window
  /// the person minimised is never popped back up.
  static func startMinimisedStep(
    _ state: StartMinimised, windowNeedsPerson: Bool
  ) -> StartMinimisedStep? {
    switch state {
    case .nothingOwed: nil
    case .awaitingWindow: windowNeedsPerson ? .forget : .minimise
    case .minimised: windowNeedsPerson ? .restore : nil
    }
  }

  /// The dock badge text: `nil` hides it.
  ///
  /// Zero renders nothing rather than "0": a permanent zero trains people to stop reading
  /// the badge, which is the same reasoning the sidebar badges use.
  static func badgeLabel(count: Int, enabled: Bool) -> String? {
    guard enabled, count > 0 else { return nil }
    return String(count)
  }
}

extension AppBehaviourPolicy {

  /// The activation policy for a given visibility, as a DECISION separate from the AppKit
  /// call that applies it, so the choice is testable without a running NSApplication.
  ///
  /// `.accessory`, never `.prohibited`: prohibited hides the Dock icon AND suppresses the
  /// menu bar, which left a headless server with no indication it was running at all. A
  /// headless launch asks for `dockHidden: true`, because it is the same visual outcome: no
  /// icon, menu bar intact.
  static func activationPolicy(dockHidden: Bool) -> NSApplication.ActivationPolicy {
    dockHidden ? .accessory : .regular
  }
}

@MainActor
enum AppBehaviour {

  /// Shows or hides the Dock icon.
  ///
  /// `setActivationPolicy` rather than `NSApp.dockTile`/`dock.hide()`, for the reason the
  /// Electron server documents from experience: it is the runtime equivalent of `LSUIElement`
  /// and survives window creation, whereas hiding the dock tile is undone the next time a
  /// window appears.
  static func applyDockVisibility(hidden: Bool) {
    // Only when it actually changes. This runs from the unread-count callback, so every
    // alert -- including every recurrence of a flapping one -- was a round trip to
    // WindowServer to set the policy it was already set to.
    let wanted = AppBehaviourPolicy.activationPolicy(dockHidden: hidden)
    guard NSApp.activationPolicy() != wanted else { return }
    NSApp.setActivationPolicy(wanted)
  }

  static func applyDockBadge(count: Int, enabled: Bool) {
    NSApp.dockTile.badgeLabel = AppBehaviourPolicy.badgeLabel(count: count, enabled: enabled)
  }

  /// Closes the main window, leaving the menu bar item behind.
  ///
  /// For the headless launch, which wants no window but must still be visible in the menu
  /// bar. The MenuBarExtra's own window is excluded: closing that would remove the status
  /// item, which is the one thing headless mode has to keep.
  static func closeMainWindow() {
    for window in NSApp.windows where window.canBecomeMain && window.isVisible {
      window.close()
    }
  }

  /// Minimises the main window, and answers whether there was one on screen to minimise.
  ///
  /// Not `NSApp.hide`: hiding removes the app from view entirely, and someone who asked to
  /// start minimised still expects to find it in the Dock or the app switcher.
  ///
  /// What it minimises is recorded until the person takes it back, by un-minimising or closing
  /// it, when `onTakenBack` runs. Only a recorded window can be restored, and a window the
  /// person minimises by hand after that is not recorded.
  static func minimizeMainWindow(onTakenBack: @escaping @MainActor () -> Void) -> Bool {
    let windows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
    guard !windows.isEmpty else { return false }
    startMinimisedWindows = windows
    startMinimisedObservers = [
      NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
    ].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        notification in
        let window = notification.object as? NSWindow
        // Both are posted on the main thread and the queue is the main one, so this asserts
        // that isolation rather than hopping to it.
        MainActor.assumeIsolated {
          startMinimisedWindows.removeAll { $0 === window }
          guard startMinimisedWindows.isEmpty else { return }
          stopWatchingStartMinimisedWindows()
          onTakenBack()
        }
      }
    }
    for window in windows { window.miniaturize(nil) }
    return true
  }

  /// Undoes `minimizeMainWindow`, for the windows it recorded and no others.
  ///
  /// Without activating the app: a start that fails
  /// while somebody is working in another app should be there when they look, not take the
  /// keyboard from them.
  ///
  /// `isMiniaturized` is deliberately not consulted. A start can fail within moments of the
  /// minimise, while its animation is still running, and the answer then may be false for a
  /// window that is on its way to the Dock.
  static func restoreMainWindow() {
    let windows = startMinimisedWindows
    startMinimisedWindows = []
    // Before the restore, so bringing a window back is not mistaken for the person doing it.
    stopWatchingStartMinimisedWindows()
    for window in windows { window.deminiaturize(nil) }
  }

  /// What `minimizeMainWindow` minimised and the person has not taken back.
  private static var startMinimisedWindows: [NSWindow] = []
  private static var startMinimisedObservers: [any NSObjectProtocol] = []

  private static func stopWatchingStartMinimisedWindows() {
    startMinimisedObservers.forEach(NotificationCenter.default.removeObserver)
    startMinimisedObservers = []
  }

  /// Launches FindMy so it refreshes the caches the FindMy endpoints read.
  ///
  /// The data comes from files FindMy writes; without the app having run they are stale or
  /// absent, and the endpoints return nothing with no explanation.
  @discardableResult
  static func openFindMy() -> Bool {
    ApplicationControl.launch(bundleIdentifier: AppBehaviourPolicy.findMyBundleID)
  }

  /// How long this Mac has been up.
  static var systemUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// What starting minimised has done to the main window, followed from the decision until
/// nothing is owed.
///
/// The decision is `AppBehaviourPolicy`'s and the AppKit calls are `AppBehaviour`'s. This holds
/// the state between them, and takes the two calls as closures so a test can walk it with no
/// window server.
@MainActor
final class StartMinimisedWindow {

  private(set) var state = AppBehaviourPolicy.StartMinimised.nothingOwed
  private let minimise: @MainActor (@escaping @MainActor () -> Void) -> Bool
  private let restore: @MainActor () -> Void

  init(
    minimise: @escaping @MainActor (@escaping @MainActor () -> Void) -> Bool =
      AppBehaviour.minimizeMainWindow(onTakenBack:),
    restore: @escaping @MainActor () -> Void = AppBehaviour.restoreMainWindow
  ) {
    self.minimise = minimise
    self.restore = restore
  }

  /// `shouldStartMinimized` said yes: minimise as soon as there is a window to minimise.
  func request(windowNeedsPerson: Bool) {
    guard state == .nothingOwed else { return }
    state = .awaitingWindow
    reconcile(windowNeedsPerson: windowNeedsPerson)
  }

  /// Takes the step the policy asks for, if there is one. Safe to call on every change.
  func reconcile(windowNeedsPerson: Bool) {
    switch AppBehaviourPolicy.startMinimisedStep(state, windowNeedsPerson: windowNeedsPerson) {
    case .minimise:
      if minimise({ [weak self] in self?.state = .nothingOwed }) { state = .minimised }
    case .restore:
      state = .nothingOwed
      restore()
    case .forget:
      state = .nothingOwed
    case nil:
      break
    }
  }

  /// The last attempt, once the start has finished.
  ///
  /// A minimise still waiting here is dropped rather than kept. A window that first appears
  /// after this is one somebody opened, and minimising it in front of them is the one thing
  /// `isUnattended` exists to prevent.
  func settle(windowNeedsPerson: Bool) {
    reconcile(windowNeedsPerson: windowNeedsPerson)
    if state == .awaitingWindow { state = .nothingOwed }
  }
}

// Locking the screen lives in `BBSystem.ScreenLock`, which this file already imports.
//
// Do not add a copy here: a type declared in the module beats an imported one, so it
// would SHADOW the real implementation for every caller inside the app, and "Lock Screen"
// from the UI and the same action over the HTTP API would do different things. The real
// one carries the `pmset displaysleepnow` fallback, which is the half that matters on a
// Mac without "require password after sleep": the private call is what actually locks,
// and without the fallback a failure looks like success.

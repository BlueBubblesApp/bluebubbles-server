//  BlueBubblesApp
//  The application entry point. See `.claude/docs/architecture.md`.

import BBCore
import BBInterfaces
import BlueBubblesServerCore
import Logging
import SwiftUI

@main
struct BlueBubblesApp: App {

  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  /// Headless is decided before any UI exists.
  ///
  /// `.prohibited` rather than "skip creating windows": an app that merely opens no window
  /// still has a Dock icon, still appears in the app switcher, and still activates. The
  /// activation policy is what actually makes it a background process.
  ///
  /// **This is not the same as running without a GUI session.** `App` goes through
  /// `NSApplicationMain`, which needs a connection to the WindowServer: measured, not
  /// assumed: launched detached from a login session this binary exits before it logs
  /// anything at all, while `bluebubbles-server` from the same bundle serves requests
  /// normally. So `--headless` here means "a login item with no Dock icon", and a genuine
  /// headless install (a launch daemon, a headless Mac, CI) uses the CLI beside it,
  /// which links no AppKit.
  ///
  /// That is why both products exist, and why the CLI ships INSIDE the bundle rather than
  /// being dropped once there was an app: it is covered by the same signature and the same
  /// notarization ticket.
  private static let launchOptions = LaunchOptions.current

  var body: some Scene {
    Window("BlueBubbles", id: RootView.windowID) {
      RootView(model: model)
        // In the environment as well as passed explicitly: a deeply-nested row (the
        // connection-method picker inside a generated settings row) needs to navigate
        // and read integration state, and threading the model through every
        // intermediate view to reach it would be worse than either.
        .environment(model)
        // The minimum height is set by the tallest sheet, not by the content: the
        // onboarding sheet is 640 points at its ideal size, and a sheet taller than its
        // window draws its footer (Continue and Quit) off the bottom, out of reach.
        .frame(minWidth: 900, minHeight: 700)
        .task {
          // Before `start`, so a signal arriving during a slow startup still finds
          // something to shut down.
          delegate.model = model
          // Installed HERE, and not from `applicationDidFinishLaunching`, which is
          // where it belongs and where it does not work: `NSApp.delegate` is
          // SwiftUI's own `SwiftUI.AppDelegate`, and an
          // `@NSApplicationDelegateAdaptor` object never receives that message:
          // verified by reading the live delegate's class out of the running
          // process. `applicationShouldTerminate` IS forwarded to it, which is why
          // the shutdown below still runs. Touching this installs it; it is a
          // global, so it happens exactly once.
          _ = terminationSignals
          if Self.launchOptions.isHeadless {
            // `.accessory`, NOT `.prohibited`.
            //
            // `.prohibited` suppresses the Dock icon AND every other way the app
            // can present itself (including the menu bar) so a headless server
            // would run with no indication whatsoever that it is running: no Dock icon,
            // no status item, nothing to click to stop it. `.accessory` is what
            // "no Dock icon" actually means, and it is the same policy the
            // `hide_dock_icon` setting uses (see AppBehaviour.applyDockVisibility).
            NSApplication.shared.setActivationPolicy(
              AppBehaviourPolicy.activationPolicy(headless: true)
            )
            // `.accessory` permits windows, so the main one is dismissed rather
            // than left on screen: headless means no window, not no menu bar.
            AppBehaviour.closeMainWindow()
          }
          await model.start(isAutomatic: true)
        }
    }
    // Declared, as the reference window's is. Without it the first launch opens at whatever
    // SwiftUI derives from the content, which for a split view is close to the minimum.
    .defaultSize(width: 1120, height: 780)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      // ⌘, opens Settings, as it does in every Mac app with a Settings page. Replacing the
      // group rather than adding to it: there is no `Settings` scene, so the default item
      // would sit in the menu and do nothing.
      CommandGroup(replacing: .appSettings) {
        NavigationMenuItem(page: .settings, title: "Settings…", shortcut: ",", model: model)
      }
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          Task { await model.updates.check() }
        }
        .disabled(!model.phase.isRunning)
        // The walkthrough, on demand: someone adding a phone months after setting up for
        // a desktop client gets the same guided path, with their earlier answers kept.
        Button("Setup Assistant…") { model.onboarding.present() }
          .disabled(!model.phase.isRunning)
      }
      CommandGroup(after: .help) {
        APIDocsMenuItem()
      }
      // ⌘1 to ⌘9 walk the sidebar in its own order. Settings is the tenth page and already
      // has ⌘, above, so the nine digits cover the rest exactly.
      CommandMenu("Go") {
        ForEach(Array(Destination.allCases.prefix(9).enumerated()), id: \.element) {
          index, page in
          NavigationMenuItem(
            page: page, title: page.title,
            shortcut: KeyEquivalent(Character(String(index + 1))), model: model)
        }
      }
    }

    // The API reference, in its own window rather than a sidebar page or a sheet.
    //
    // It is a reference: the thing people do with it is keep it open beside something else
    // while they write a client. A sidebar destination would make that impossible without
    // losing their place in the app, and a sheet would make it modal over a server they
    // may well want to look at at the same time.
    //
    // `Window` and not `WindowGroup`: one reference, opened repeatedly, is one window.
    // A group would hand out a new copy on every click, each regenerating the document.
    Window("API Reference", id: APIDocsView.windowID) {
      APIDocsView(model: model)
        .frame(minWidth: 720, minHeight: 480)
    }
    .defaultSize(width: 1180, height: 820)

    // The server is a background service, so the menu bar is
    // where people actually interact with it day to day, and it is the ONLY indication
    // the server is running once the Dock icon is hidden, which is why the headless path
    // must not use an activation policy that suppresses it.
    MenuBarExtra("BlueBubbles", systemImage: model.phase.isRunning ? "message.fill" : "message") {
      MenuBarContent(model: model)
    }
  }
}

/// The Help-menu entry for the reference window.
///
/// Its own `View` because `openWindow` is an environment value: read from the `App` type it
/// is empty, and the button silently does nothing.
private struct APIDocsMenuItem: View {

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("API Reference") { openWindow(id: APIDocsView.windowID) }
  }
}

/// A menu item that shows one sidebar page.
///
/// Its own `View` for the same reason `APIDocsMenuItem` is: it opens the main window first,
/// so a shortcut pressed with the window closed brings the page up rather than changing a
/// selection nobody can see, and `openWindow` is only readable from a view.
private struct NavigationMenuItem: View {

  let page: Destination
  let title: String
  /// With ⌘. On the button itself rather than on this view, so the menu shows it.
  let shortcut: KeyEquivalent
  let model: AppModel

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(title) {
      openWindow(id: RootView.windowID)
      model.selection = page
    }
    .keyboardShortcut(shortcut, modifiers: .command)
  }
}

/// SIGTERM and SIGINT quit the app, the way the menu does.
///
/// Hummingbird's `runService()` defaults to claiming SIGTERM and SIGINT for its own graceful
/// shutdown, PROCESS-WIDE, which would let a `pkill`, a script, or `launchctl kill TERM`
/// shut the HTTP server down and leave the app running: alive, no listening socket, UI still
/// reporting "running". The listener declines those signals (see `HTTPListener`), which
/// leaves them for their actual owner, which is this.
///
/// A file-scope `let`, NOT a property on the delegate. A `DispatchSourceSignal` stops
/// delivering the moment it is released, and `NSApplication.delegate` is a WEAK reference, so
/// sources parked on a delegate have a lifetime nothing here controls, and the failure mode
/// is silent, since SIG_IGN stays behind with nothing listening for it. A global `let` is
/// initialised once, on first use, and never released, which is what process-wide signal
/// handling actually wants.
///
/// SIG_IGN first is not optional and not a contradiction: a `DispatchSourceSignal` only ever
/// sees a signal whose default action has been suppressed. Without it the default disposition
/// kills the process outright and the handler below never runs.
@MainActor
private let terminationSignals: [any DispatchSourceSignal] = [SIGINT, SIGTERM].map { value in
  signal(value, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
  // Routed through `terminate` rather than exiting here, so a signal and a menu Quit take
  // exactly the same path, including the server shutdown in `applicationShouldTerminate`.
  source.setEventHandler {
    // Built HERE rather than stored, and that is not a style choice: a `Logger` resolves
    // its handler when it is created, and this is created long before the server
    // bootstraps logging. A logger held as a property would write to stderr, which for an
    // app launched by LaunchServices means nowhere at all.
    Logger(label: "bluebubbles.app").info(
      "Received a termination signal; quitting",
      metadata: ["signal": .stringConvertible(value)]
    )
    // The source's queue IS the main queue, so this asserts that isolation rather
    // than hopping to it: a hop would put the terminate in a later turn of the run
    // loop, which is the sort of gap a second signal arrives in.
    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
  }
  source.resume()
  return source
}

/// Termination and reopen behaviour, which `App` alone cannot express.
/// Lets exactly one of two racing tasks resume a continuation.
///
/// A checked continuation traps on a second resume, so "whichever finishes first wins" needs
/// somewhere for the loser to find out that it lost. One `Bool` behind an actor is the whole
/// of it.
private actor FirstToFinish {
  private var isClaimed = false

  func claim() -> Bool {
    if isClaimed { return false }
    isClaimed = true
    return true
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

  /// Set by the scene once the model exists, so termination can stop the server first.
  weak var model: AppModel?

  /// Stops the server before the process goes away.
  ///
  /// Every quit except the menu bar's own button arrives HERE rather than at that button:
  /// ⌘Q, `osascript`, a logout, a signal. Without this they stop nothing, and what that
  /// costs is a tunnel that is never told to close, so the remote side holds a dead session
  /// open until it times out.
  ///
  /// `.terminateLater`, then the answer once the server has stopped. AppKit has a protocol
  /// for exactly this shape, and it is the only one that is safe here: parking the main
  /// thread on a semaphore until a detached `stop()` finished works only for as long as
  /// nothing in the stop path hops to the main actor, and the day something does, the thread
  /// holding the semaphore is the one that has to run it. The wait is bounded, because the
  /// process is about to exit either way and a wedged service must not hold a logout hostage.
  ///
  /// **The shutdown runs DETACHED and the reply goes back through the run loop, and the app
  /// deadlocks without both.** `.terminateLater` makes AppKit spin a NESTED run loop inside
  /// `-[NSApplication _shouldTerminate]` until the reply arrives, and that loop does not
  /// drain the main dispatch queue. A `Task {}` written here inherits this class's
  /// `@MainActor`, so it is enqueued exactly where nothing will pick it up: the shutdown
  /// never starts, the reply is never sent, and the nested loop waits forever. Not even the
  /// deadline below fires, because the task holding it never runs either.
  ///
  /// Measured on a live build with `sample`: the main thread parked under
  /// `_shouldTerminate → nextEventMatchingMask:`, and NO thread anywhere in `stop()`. It
  /// affected every route out of the app (the onboarding Quit button, ⌘Q, the menu-bar
  /// item, `SIGTERM`, and a logout) and presented as a Quit button that did nothing.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Before anything else, and on BOTH exits below. The launcher reads this after the process
    // is gone, and its resting value means "restart it", so a quit that fails to record
    // itself comes straight back, which to the user is an app that will not close.
    //
    // Not written when a restart is already in flight: `ServerLifecycle` sets `.restart` and
    // then terminates, and that termination arrives here.
    if LauncherContract.readIntent() != .restart {
      LauncherContract.writeIntent(.quit)
    }

    // Before the stop starts, so the window's last frames say "Stopping…" rather than
    // reporting each service's shutdown as though the server were still live.
    model?.beginShutdown()

    guard let server = model?.server else { return .terminateNow }

    // `Task.detached`, NOT `Task {}`: this must not be main-actor isolated. See above.
    Task.detached(priority: .userInitiated) {
      await Self.stopWithHardDeadline(server)
      // Whatever the deadline abandoned. The stop above is allowed to lose a race, and
      // when it does the daemon it was stopping would otherwise outlive this process
      // parented to launchd, still holding its tunnel.
      server.terminateAbandonedDaemons()
      Self.replyToTerminate()
    }
    return .terminateLater
  }

  /// Stops the server, or gives up after `shutdownDeadline`: whichever happens first.
  ///
  /// **A HARD bound, which `withTimeout` deliberately does not give.** Its task group cancels
  /// AND AWAITS the losing child on its way out, so an operation that does not observe
  /// cancellation is still waited for in full and the deadline only decides which error comes
  /// back. Everywhere else that is the right trade: nothing outlives the call. Here it is the
  /// wrong one: this deadline exists so that a wedged service cannot hold a logout hostage.
  ///
  /// Measured: a quit while one connection method was in retry backoff took 21 seconds against
  /// an 8-second deadline, and logged that it had timed out only once the stop had finished
  /// anyway: a warning that arrived too late to mean anything and a Quit button that looked
  /// dead for twenty seconds.
  ///
  /// The loser is left running, deliberately. The process is about to exit; a shutdown step
  /// that has not finished by now is one we are choosing to abandon rather than wait for.
  private nonisolated static func stopWithHardDeadline(_ server: RunningServer) async {
    let winner = FirstToFinish()
    await withCheckedContinuation { continuation in
      Task.detached {
        await server.stop()
        if await winner.claim() { continuation.resume() }
      }
      Task.detached {
        try? await Task.sleep(for: shutdownDeadline)
        guard await winner.claim() else { return }
        Logger(label: "bluebubbles.app").warning(
          "The server did not stop within \(shutdownDeadline.seconds)s; quitting anyway"
        )
        continuation.resume()
      }
    }
  }

  /// Answers the `.terminateLater` above, from off the main thread.
  ///
  /// `DispatchQueue.main.async` would be wrong for the same reason `Task {}` is: the nested
  /// loop AppKit is blocking in does not service the main dispatch queue, so the reply would
  /// sit in the queue that is waiting for it.
  ///
  /// `CFRunLoopPerformBlock` schedules directly on the run loop, and every mode it currently
  /// has is named rather than `commonModes`: the whole problem is that the mode AppKit
  /// chose here is not one the common set drains. `CFRunLoopWakeUp` is required: the loop is
  /// asleep in `mach_msg` and a block alone does not rouse it.
  ///
  /// The block runs ON the main thread, which is what makes `assumeIsolated` true rather
  /// than hopeful: the run loop it is scheduled on is the main one.
  /// `nonisolated` on purpose: it is called from the detached shutdown, and requiring the
  /// main actor to deliver the reply would put it back in the queue that is waiting for it.
  private nonisolated static func replyToTerminate() {
    let runLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(runLoop, CFRunLoopCopyAllModes(runLoop)) {
      MainActor.assumeIsolated {
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
    }
    CFRunLoopWakeUp(runLoop)
  }

  /// Long enough for an orderly shutdown, short enough not to read as a hang. macOS raises
  /// its own "prevented logout" complaint well after this.
  ///
  /// `nonisolated` because the detached shutdown reads it, and that task must not need the
  /// main actor, which is the whole point of it being detached.
  private nonisolated static let shutdownDeadline: Duration = .seconds(8)

  /// Closing the window must NOT quit: the server keeps running in the menu bar, which is
  /// the whole point of a background service. Quitting on last-window-close is the default
  /// and would stop the server every time someone tidied their desktop.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Clicking the Dock icon with no window open reopens the main window rather than doing
  /// nothing, which is what users expect and what the default does not do here.
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    return true
  }
}

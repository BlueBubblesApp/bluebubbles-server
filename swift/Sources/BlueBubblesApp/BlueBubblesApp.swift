//  BlueBubblesApp
//  The application entry point.
//
//  Replaces the Electron main process, the tray, and the renderer. See `.claude/docs/architecture.md`.

import BBHandlers
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
  /// `NSApplicationMain`, which needs a connection to the WindowServer — measured, not
  /// assumed: launched detached from a login session this binary exits before it logs
  /// anything at all, while `bluebubbles-server` from the same bundle serves requests
  /// normally. So `--headless` here means "a login item with no Dock icon", and a genuine
  /// headless install — a launch daemon, a headless Mac, CI — uses the CLI beside it,
  /// which links no AppKit.
  ///
  /// That is why both products exist, and why the CLI ships INSIDE the bundle rather than
  /// being dropped once there was an app: it is covered by the same signature and the same
  /// notarization ticket.
  private static let launchOptions = LaunchOptions.parse()

  var body: some Scene {
    Window("BlueBubbles", id: "main") {
      RootView(model: model)
        // In the environment as well as passed explicitly: a deeply-nested row — the
        // connection-method picker inside a generated settings row — needs to navigate
        // and read integration state, and threading the model through every
        // intermediate view to reach it would be worse than either.
        .environment(model)
        .frame(minWidth: 900, minHeight: 560)
        .task {
          // Before `start`, so a signal arriving during a slow startup still finds
          // something to shut down.
          delegate.model = model
          // Installed HERE, and not from `applicationDidFinishLaunching`, which is
          // where it belongs and where it does not work: `NSApp.delegate` is
          // SwiftUI's own `SwiftUI.AppDelegate`, and an
          // `@NSApplicationDelegateAdaptor` object never receives that message —
          // verified by reading the live delegate's class out of the running
          // process. `applicationShouldTerminate` IS forwarded to it, which is why
          // the shutdown below still runs. Touching this installs it; it is a
          // global, so it happens exactly once.
          _ = terminationSignals
          if Self.launchOptions.isHeadless {
            // `.accessory`, NOT `.prohibited`.
            //
            // `.prohibited` suppresses the Dock icon AND every other way the app
            // can present itself — including the menu bar — so a headless server
            // ran with no indication whatsoever that it was running: no Dock icon,
            // no status item, nothing to click to stop it. `.accessory` is what
            // "no Dock icon" actually means, and it is the same policy the
            // `hide_dock_icon` setting uses (see AppBehaviour.applyDockVisibility).
            NSApplication.shared.setActivationPolicy(
              AppBehaviourPolicy.activationPolicy(headless: true)
            )
            // `.accessory` permits windows, so the main one is dismissed rather
            // than left on screen — headless means no window, not no menu bar.
            AppBehaviour.closeMainWindow()
          }
          await model.start(isAutomatic: true)
        }
    }
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          Task { await model.checkForUpdates() }
        }
        .disabled(!model.phase.isRunning)
      }
      CommandGroup(after: .help) {
        APIDocsMenuItem()
      }
    }

    // The API reference, in its own window rather than a sidebar page or a sheet.
    //
    // It is a reference: the thing people do with it is keep it open beside something else
    // while they write a client. A sidebar destination would make that impossible without
    // losing their place in the app, and a sheet would make it modal over a server they
    // may well want to look at at the same time.
    //
    // `Window` and not `WindowGroup` — one reference, opened repeatedly, is one window.
    // A group would hand out a new copy on every click, each regenerating the document.
    Window("API Reference", id: APIDocsView.windowID) {
      APIDocsView(model: model)
        .frame(minWidth: 720, minHeight: 480)
    }
    .defaultSize(width: 1180, height: 820)

    // Replaces the Electron tray. The server is a background service, so the menu bar is
    // where people actually interact with it day to day — and it is the ONLY indication
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

/// SIGTERM and SIGINT quit the app, the way the menu does.
///
/// This exists because something else was taking them. Hummingbird's `runService()` defaults
/// to claiming SIGTERM and SIGINT for its own graceful shutdown, PROCESS-WIDE — so a `pkill`,
/// a script, or `launchctl kill TERM` shut the HTTP server down and left the app running:
/// alive, no listening socket, UI still reporting "running", every client silently
/// disconnected. The listener now declines those signals (see `HTTPListener`), which leaves
/// them for their actual owner, which is this.
///
/// A file-scope `let`, NOT a property on the delegate. A `DispatchSourceSignal` stops
/// delivering the moment it is released, and `NSApplication.delegate` is a WEAK reference, so
/// sources parked on a delegate have a lifetime nothing here controls — and the failure mode
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
  // exactly the same path — including the server shutdown in `applicationShouldTerminate`.
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
    // than hopping to it — a hop would put the terminate in a later turn of the run
    // loop, which is the sort of gap a second signal arrives in.
    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
  }
  source.resume()
  return source
}

/// Termination and reopen behaviour, which `App` alone cannot express.
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
  /// **Blocking, deliberately, and NOT `.terminateLater`.** That reply exists for exactly
  /// this situation and it cannot be used with Swift concurrency here: while AppKit waits
  /// for `reply(toApplicationShouldTerminate:)` it runs a nested run loop that does not
  /// drain the main queue, so a `Task { @MainActor in … }` started from this method never
  /// runs at all — not the shutdown, and not the deadline task meant to rescue it. Measured
  /// with a stripped-down app: an immediate main-actor task scheduled here never executed,
  /// the reply never came, and the app hung so completely that a subsequent Quit did
  /// nothing, because AppKit considered a termination already in flight.
  ///
  /// So the work goes where the main actor is not needed. `RunningServer.stop()` drives the
  /// service registry and is not main-actor isolated, which is what makes it safe to run
  /// detached and wait for here. Bounded, because the process is about to exit either way
  /// and a wedged service must not hold a logout hostage.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let server = model?.server else { return .terminateNow }

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await server.stop()
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + Self.shutdownDeadline) == .timedOut {
      Logger(label: "bluebubbles.app").warning(
        "The server did not stop within \(Int(Self.shutdownDeadline))s; quitting anyway"
      )
    }
    return .terminateNow
  }

  /// Long enough for an orderly shutdown, short enough not to read as a hang. macOS raises
  /// its own "prevented logout" complaint well after this.
  private static let shutdownDeadline: TimeInterval = 8

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

//  BlueBubblesLauncher
//  A second process whose only job is that the first one keeps running.
//
//  Registered as a login item from `Contents/Library/LoginItems/`, it starts the server app at
//  login and brings it back if it stops without meaning to. That second half is the reason it
//  exists: `ServerLifecycle.replaceProcess` can `execv` itself for a DELIBERATE restart, but a
//  crash, an OOM kill or a `SIGKILL` leaves nothing running and nothing watching. A process
//  cannot supervise itself.
//
//  **It is deliberately tiny and depends on almost nothing.** A supervisor that fails to start
//  is worse than no supervisor, because the thing it was watching is not running either and
//  nobody is told. It links `BBCore` for the shared contract and AppKit for `NSWorkspace`, and
//  that is the whole dependency list: no database, no settings, no logging stack.
//
//  **Why it is an app bundle rather than a bare executable.** `SMAppService.loginItem` reads
//  `Contents/Library/LoginItems/` and takes a bundle identifier, so a bundle is the format.
//  It also buys the name: Background Task Management labels a bundle-based item from that
//  bundle, so System Settings > Login Items shows BlueBubbles. The retired launch agent would
//  have been named from the signing certificate's Organization field, which for an individual
//  Apple Developer enrolment is the developer's legal name.
//
//  `LSUIElement`, so it has no Dock icon and no menu bar. It is not an application a user
//  interacts with; it is the thing that makes sure the one they do is there.
//
//  The decision it makes on a stop is `LauncherPolicy`, which is pure and tested. This file is
//  the world around it: when to look, what to launch, and where the app is.

import AppKit
import BBCore
import Foundation

/// Watches the server app and restarts it when it stops unexpectedly.
@MainActor
final class Launcher {

  /// How often the launcher looks.
  ///
  /// Two seconds is imperceptible against a login, cheap against a LaunchServices lookup, and
  /// it bounds how long a crashed server stays down.
  private static let pollInterval: TimeInterval = 2

  /// Running → stopped edge detection. `RunStateTracker` rather than a `Bool`, because the
  /// distinction it encodes (expectation, not last sample) is the one that matters.
  private var runState = RunStateTracker()
  private var timer: Timer?

  /// When each unexpected relaunch happened. The decision is `LauncherPolicy`'s; this only
  /// holds the history it needs.
  private var recentRelaunches: [Date] = []

  /// The application bundle this launcher belongs to.
  ///
  /// Derived by PATH, four levels up from the launcher bundle, rather than by asking
  /// LaunchServices for the bundle identifier. A user with a copy in `~/Downloads` and another
  /// in `/Applications` has two bundles claiming that identifier, and LaunchServices is free to
  /// answer with either: a supervisor that relaunches a different copy of the app from the one
  /// it shipped inside is a very confusing bug. A path cannot be ambiguous.
  private let mainApplicationURL: URL = {
    Bundle.main.bundleURL
      .deletingLastPathComponent()  // LoginItems
      .deletingLastPathComponent()  // Library
      .deletingLastPathComponent()  // Contents
      .deletingLastPathComponent()  // BlueBubbles.app
  }()

  func start() {
    // Polling, not `NSWorkspace.didTerminateApplicationNotification`.
    //
    // That notification is the obvious mechanism and it did not arrive. Reduced to a minimal
    // observer: register on the workspace centre, run an accessory `NSApplication`, SIGKILL a
    // bundled `NSApplication` carrying a different bundle identifier; nothing was delivered,
    // whether the observer was started from a shell or launched through LaunchServices from
    // inside its own bundle.
    //
    // The cause was never established, and that is the argument rather than a caveat to it. A
    // supervisor whose wake-up depends on delivery it cannot verify fails in the one way that
    // matters most: silently, at the moment the thing it watches has died, with nobody watching
    // the watcher. A poll cannot be lost, costs one LaunchServices lookup every couple of
    // seconds, and is observable from outside.
    let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    // `.common`, so a modal panel or a menu tracking loop elsewhere in the session cannot
    // stall supervision.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer

    // At login the app is not running yet; if the user launched it themselves first, it is,
    // and starting a second copy would trip the single-instance lock.
    if runningMainApplication() == nil {
      launchMainApplication()
    }
    runState.expectRunning()
  }

  private func tick() {
    guard runState.observe(isRunning: runningMainApplication() != nil) else { return }
    handleStop()
  }

  private func handleStop() {
    let intent = LauncherContract.readIntent()
    // Reset before acting, not after. Every intent but `supervise` is a single instruction, and
    // leaving one in place would apply it again to the NEXT stop: a stale `quit` would leave
    // the app unsupervised for the rest of the login session, and a stale `restart` would mask
    // a crash as a deliberate restart.
    if intent != .supervise { LauncherContract.writeIntent(.supervise) }

    let outcome = LauncherPolicy.decide(intent: intent, recentRelaunches: recentRelaunches)
    recentRelaunches = outcome.recentRelaunches

    switch outcome.decision {
    case .standDown:
      NSApplication.shared.terminate(nil)
    case .relaunch:
      if intent == .supervise {
        NSLog("BlueBubbles: the server stopped unexpectedly; restarting it.")
      }
      launchMainApplication()
      // Before the next poll, which would otherwise sample an app that has not finished
      // starting and record "not running" as the expectation.
      runState.expectRunning()
    case .giveUp:
      NSLog(
        "BlueBubbles: the server stopped %d times in %.0f seconds; not restarting it again.",
        LauncherPolicy.relaunchLimit, LauncherPolicy.crashLoopWindow)
      NSApplication.shared.terminate(nil)
    }
  }

  /// The running copy of the app THIS launcher is inside, or nil.
  ///
  /// Matched on bundle URL as well as identifier, for the same reason the URL is derived by
  /// path: another copy of BlueBubbles running from somewhere else is not the one this is
  /// responsible for, and treating it as such would leave the real one down.
  private func runningMainApplication() -> NSRunningApplication? {
    NSRunningApplication
      .runningApplications(withBundleIdentifier: LauncherContract.mainBundleIdentifier)
      .first { $0.bundleURL?.standardizedFileURL == mainApplicationURL.standardizedFileURL }
  }

  private func launchMainApplication() {
    let configuration = NSWorkspace.OpenConfiguration()
    // The app decides its own window behaviour from its settings; the launcher must not
    // second-guess it. Activating would steal focus at login from whatever the user is doing.
    configuration.activates = false
    configuration.createsNewApplicationInstance = false

    NSWorkspace.shared.openApplication(at: mainApplicationURL, configuration: configuration) {
      _, error in
      if let error {
        NSLog("BlueBubbles: could not start the server app: %@", error.localizedDescription)
      }
    }
  }
}

// A run loop is all this needs, and `NSApplication` supplies one the rest of AppKit is happy
// inside; `NSWorkspace.openApplication` included. `.accessory` keeps it out of the Dock and
// the ⌘-Tab switcher.
let application = NSApplication.shared
let launcher = MainActor.assumeIsolated { Launcher() }
application.setActivationPolicy(.accessory)
MainActor.assumeIsolated { launcher.start() }
application.run()

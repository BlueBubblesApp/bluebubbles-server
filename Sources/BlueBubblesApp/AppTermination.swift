//  AppTermination
//  The one door out of the app, and the one way back in.
//
//  Every quit goes through `NSApplication.terminate`, so that it reaches
//  `applicationShouldTerminate`: the shutdown with a hard deadline, and the sweep for daemons
//  a lost race abandoned. The menu bar's Quit stopped the
//  server ITSELF and then terminated, so the delegate found no server and quit at once: a
//  service that hung on stop hung Quit for ever, and a tunnel's daemon outlived the app.
//  `SharedComponentPolicyTests` refuses `.terminate(` anywhere in the app but here.

import AppKit

enum AppTermination {

  /// Whether the quit in progress began with a termination signal rather than a person.
  /// `LaunchAgentContract.marksQuitRequest` is why it matters.
  @MainActor
  private(set) static var initiatedBySignal = false

  /// Quits through the delegate's shutdown.
  @MainActor
  static func quit() {
    NSApplication.shared.terminate(nil)
  }

  /// Quits through the delegate's shutdown because a termination signal arrived.
  @MainActor
  static func quitForSignal() {
    initiatedBySignal = true
    quit()
  }

  /// Quits from a button on a sheet.
  ///
  /// `terminate(nil)` made from inside a presented sheet never reaches the delegate:
  /// measured with a log line at the top of `applicationShouldTerminate`, which a press of
  /// the onboarding sheet's Quit never wrote while a `SIGTERM` to the same build did. So the
  /// sheet goes first and the quit follows on the next turn of the run loop.
  @MainActor
  static func quitFromSheet(dismiss: () -> Void) {
    dismiss()
    DispatchQueue.main.async { quit() }
  }
}

/// How a relaunch reaches a fresh process, decided off the model so it can be tested.
enum RelaunchRoute: Equatable {
  /// launchd started this copy as the agent: stop the server, then exit with
  /// `LaunchAgentContract.restartExitCode`, and launchd starts the new copy. Opening one
  /// ourselves would end this process with the 0 of an ordinary quit, which launchd reads as
  /// "stay down", and the copy it did not start would be supervised by nothing.
  case handToLaunchd
  /// Nothing is watching: stop the server first, which releases the single-instance lock
  /// the new copy has to take, then open it, then quit. Opened while this copy still held
  /// the lock, the new one started as "already running". The new copy hands itself to the
  /// agent if one is registered (`LaunchAtLogin.shouldHandOver`).
  case reopenAfterStopping

  static func choose(isAgentProcess: Bool) -> RelaunchRoute {
    isAgentProcess ? .handToLaunchd : .reopenAfterStopping
  }
}

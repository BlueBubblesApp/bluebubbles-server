//  AppTermination
//  The one door out of the app, and the one way back in.
//
//  Every quit goes through `NSApplication.terminate`, so that it reaches
//  `applicationShouldTerminate`: the shutdown with a hard deadline, the sweep for daemons a
//  lost race abandoned, and the launcher's instruction. The menu bar's Quit stopped the
//  server ITSELF and then terminated, so the delegate found no server and quit at once: a
//  service that hung on stop hung Quit for ever, and a tunnel's daemon outlived the app.
//  `SharedComponentPolicyTests` refuses `.terminate(` anywhere in the app but here.

import AppKit

enum AppTermination {

  /// Quits through the delegate's shutdown.
  @MainActor
  static func quit() {
    NSApplication.shared.terminate(nil)
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
  /// The launcher is watching: record `.restart` and quit, and it opens the new copy once
  /// this one is gone. Opening one ourselves would leave the launcher reading the `.quit`
  /// every ordinary quit records, and it stands down on that, so the next crash would bring
  /// nothing back.
  case handToLauncher
  /// Nothing is watching: stop the server first, which releases the single-instance lock
  /// the new copy has to take, then open it, then quit. Opened while this copy still held
  /// the lock, the new one started as "already running".
  case reopenAfterStopping

  static func choose(launcherIsSupervising: Bool) -> RelaunchRoute {
    launcherIsSupervising ? .handToLauncher : .reopenAfterStopping
  }
}

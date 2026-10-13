//  AppTerminationTests
//  How a relaunch reaches a new process.
//
//  Relaunch used to open a second copy and quit, whatever was watching. Under the launcher
//  that left `.quit` as the instruction, which it stands down on, so the next crash brought
//  nothing back; and the new copy raced the old one for the single-instance lock. The quit
//  side is held by `SharedComponentPolicyTests`, which refuses `.terminate(` outside
//  `AppTermination`.

import BBCore
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("App termination")
struct AppTerminationTests {

  @Test("Under the launcher, a relaunch is the launcher's to perform")
  func launcherRelaunches() {
    #expect(RelaunchRoute.choose(launcherIsSupervising: true) == .handToLauncher)
  }

  @Test("With nothing watching, the server stops before the new copy opens")
  func reopenAfterStopping() {
    #expect(RelaunchRoute.choose(launcherIsSupervising: false) == .reopenAfterStopping)
  }

  /// What the hand-off rests on: the instruction `.restart`, read by the launcher, is a
  /// relaunch, where the `.quit` an ordinary quit leaves is a stand-down.
  @Test("The instruction a relaunch leaves brings the app back")
  func restartIntentRelaunches() {
    #expect(LauncherPolicy.decide(intent: .restart, recentRelaunches: []).decision == .relaunch)
    #expect(LauncherPolicy.decide(intent: .quit, recentRelaunches: []).decision == .standDown)
  }
}

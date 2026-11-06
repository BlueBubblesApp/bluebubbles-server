//  LaunchAtLoginHealthTests
//  What the Start at Login row says while macOS answers, and when it says it.
//
//  A registration is a Background Task Management round trip that a busy Mac can take more
//  than ten minutes over, and nothing waits on it. Reported as `.starting` for that long, the
//  row held the startup bar open and read as the one service that hung, so until the work
//  finds something the service reports what it is.

import BBServiceKit
import BBSystem
import Testing

@testable import BlueBubblesServerCore

@Suite("Launch at login: the row while macOS answers")
struct LaunchAtLoginHealthTests {

  @Test("Before anything is read, the row is running, or off when the setting is")
  func beforeReconciling() {
    #expect(LaunchAtLoginService.healthBeforeReconciling(.loginItem) == .running)
    #expect(
      LaunchAtLoginService.healthBeforeReconciling(.none)
        == .inactive(reason: "not set to start at login"))
  }

  @Test("No state before reconciling is one the startup bar waits for")
  func neverStarting() {
    for mode in LaunchAtLogin.Mode.allCases {
      let health = LaunchAtLoginService.healthBeforeReconciling(mode)
      #expect(health != .starting)
      if case .waiting = health { Issue.record("\(mode) reads as waiting") }
    }
  }

  /// The recheck runs while, and only while, the reconciliation found this exact value.
  @Test("Waiting for approval is the one health the recheck runs on")
  func approvalIsTheRecheckTrigger() {
    let waiting = LaunchAtLogin.Observation(status: .requiresApproval)
    #expect(
      LaunchAtLoginService.health(mode: .loginItem, waiting)
        == LaunchAtLoginService.awaitingApproval)
    let enabled = LaunchAtLogin.Observation(status: .enabled)
    #expect(
      LaunchAtLoginService.health(mode: .loginItem, enabled)
        != LaunchAtLoginService.awaitingApproval)
  }
}

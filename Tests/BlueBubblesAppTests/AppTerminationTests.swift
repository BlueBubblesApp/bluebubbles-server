//  AppTerminationTests
//  How a relaunch reaches a new process.
//
//  Under the launch agent a relaunch is launchd's to perform: an ordinary quit ends the process
//  with 0, which launchd reads as "stay down", and a copy opened beside it would be supervised
//  by nothing. The quit side is held by `SharedComponentPolicyTests`, which refuses
//  `.terminate(` outside `AppTermination`.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("App termination")
struct AppTerminationTests {

  @Test("Started by the agent, a relaunch is launchd's to perform")
  func agentRelaunches() {
    #expect(RelaunchRoute.choose(isAgentProcess: true) == .handToLaunchd)
  }

  @Test("With nothing watching, the server stops before the new copy opens")
  func reopenAfterStopping() {
    #expect(RelaunchRoute.choose(isAgentProcess: false) == .reopenAfterStopping)
  }
}

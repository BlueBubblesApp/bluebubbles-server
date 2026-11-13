//  LaunchAtLoginDecisionTests
//  What the server does about its launch agent, given what macOS reports.
//
//  The decision follows the setting and nothing else: an `.enabled` registration is never
//  re-registered, an approval the person withheld is never fought, and a copy that is about to
//  disappear never registers itself. The handover and the Electron-agent match are here too,
//  because each decides something irreversible (exiting, deleting a file) on plain values.

import Testing

@testable import BBSystem

@Suite("Launch at login: what to do about the registration")
struct LaunchAtLoginDecisionTests {

  private typealias Observation = LaunchAtLogin.Observation

  @Test("Enabled is left alone, never re-registered")
  func enabledIsLeft() {
    #expect(LaunchAtLogin.decide(mode: .loginItem, Observation(status: .enabled)) == .leave)
  }

  @Test("Nothing registered is registered")
  func absentIsRegistered() {
    for status in [LaunchAtLogin.Status.notRegistered, .notFound, .unknown] {
      #expect(LaunchAtLogin.decide(mode: .loginItem, Observation(status: status)) == .register)
    }
  }

  /// Registering again puts the entry back after the person switched it off.
  @Test("Awaiting approval is never re-registered")
  func approvalIsNotFought() {
    let seen = Observation(status: .requiresApproval)
    #expect(LaunchAtLogin.decide(mode: .loginItem, seen) == .awaitApproval)
  }

  /// A copy on a disk image or translocated out of Downloads is the one that is about to go.
  @Test("A copy that will not last does not register")
  func unsuitableLocationRefuses() {
    for location in [LaunchAtLogin.UnsuitableLocation.translocated, .readOnlyVolume] {
      for status in [LaunchAtLogin.Status.enabled, .notRegistered] {
        let seen = Observation(status: status, unsuitableLocation: location)
        #expect(LaunchAtLogin.decide(mode: .loginItem, seen) == .refuse(location))
      }
    }
  }

  @Test("A bundle without the agent plist says so rather than registering nothing")
  func missingPlistIsNamed() {
    let seen = Observation(status: .notFound, agentIsBundled: false)
    #expect(LaunchAtLogin.decide(mode: .loginItem, seen) == .notBundled)
  }

  @Test("Switched off removes a registration, wherever this copy runs from")
  func offUnregisters() {
    for status in [LaunchAtLogin.Status.enabled, .requiresApproval] {
      let seen = Observation(status: status, unsuitableLocation: .readOnlyVolume)
      #expect(LaunchAtLogin.decide(mode: .none, seen) == .unregister)
    }
  }

  @Test("Switched off with nothing registered does nothing")
  func offAndAbsentIsLeft() {
    for status in [LaunchAtLogin.Status.notRegistered, .notFound, .unknown] {
      #expect(LaunchAtLogin.decide(mode: .none, Observation(status: status)) == .leave)
    }
  }
}

@Suite("Launch at login: handing a hand-opened copy to the agent")
struct LaunchHandoverDecisionTests {

  private static let idle = LaunchAtLogin.LaunchdJob.loaded(
    .init(state: "not running", runs: 3, lastExitCode: "0"))
  private static let running = LaunchAtLogin.LaunchdJob.loaded(.init(state: "running", runs: 1))

  @Test("A person's copy with a registered, idle agent hands over")
  func idleAgentTakesOver() {
    #expect(
      LaunchAtLogin.shouldHandOver(
        isAgentProcess: false, hasCommandLineOptions: false, agentJob: Self.idle))
    // A throttled restart waiting to happen is idle too: the person is there now.
    let scheduled = LaunchAtLogin.LaunchdJob.loaded(.init(state: "spawn scheduled"))
    #expect(
      LaunchAtLogin.shouldHandOver(
        isAgentProcess: false, hasCommandLineOptions: false, agentJob: scheduled))
  }

  @Test("The agent's own copy never hands over to itself")
  func agentRunsHere() {
    #expect(
      !LaunchAtLogin.shouldHandOver(
        isAgentProcess: true, hasCommandLineOptions: false, agentJob: Self.idle))
  }

  /// The agent starts the app with fixed arguments; handing over would drop these.
  @Test("A copy launched with options of its own runs here")
  func optionsRunHere() {
    #expect(
      !LaunchAtLogin.shouldHandOver(
        isAgentProcess: false, hasCommandLineOptions: true, agentJob: Self.idle))
  }

  @Test("No agent, a running agent, or no answer from launchd runs here")
  func otherJobsRunHere() {
    for job in [LaunchAtLogin.LaunchdJob.absent, .unreadable, Self.running] {
      #expect(
        !LaunchAtLogin.shouldHandOver(
          isAgentProcess: false, hasCommandLineOptions: false, agentJob: job))
    }
  }
}

@Suite("Launch at login: recognising the Electron server's launch agent")
struct ElectronAgentMatchTests {

  @Test("The Electron agent for a BlueBubbles app is recognised, by Program or by arguments")
  func recognised() {
    #expect(
      LaunchAtLogin.isElectronAgent([
        "Label": "com.bluebubbles.server",
        "Program": "/Applications/BlueBubbles.app/Contents/MacOS/BlueBubbles",
      ]))
    #expect(
      LaunchAtLogin.isElectronAgent([
        "Label": "com.bluebubbles.server",
        "ProgramArguments": [
          "/Users/someone/Applications/BlueBubbles.app/Contents/MacOS/BlueBubbles"
        ],
      ]))
  }

  /// Somebody's own agent that happens to share the name is never deleted.
  @Test("Another program under the same label, or another label, is left alone")
  func othersLeftAlone() {
    #expect(
      !LaunchAtLogin.isElectronAgent([
        "Label": "com.bluebubbles.server", "Program": "/usr/local/bin/something-else",
      ]))
    #expect(
      !LaunchAtLogin.isElectronAgent([
        "Label": "com.example.other",
        "Program": "/Applications/BlueBubbles.app/Contents/MacOS/BlueBubbles",
      ]))
    #expect(!LaunchAtLogin.isElectronAgent(["Label": "com.bluebubbles.server"]))
  }
}

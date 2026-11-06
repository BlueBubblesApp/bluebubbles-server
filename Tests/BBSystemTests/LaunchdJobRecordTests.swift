//  LaunchdJobRecordTests
//  Reading what launchd holds for a job: the launch agent at startup, and the retired helper
//  app's login item on an upgraded install.
//
//  The transcripts are the shape `launchctl print gui/<uid>/<label>` produced on macOS 27 for
//  a probe login item registered through `SMAppService.loginItem`, with the label and the
//  identifiers replaced. The format is for people rather than a contract, so what matters
//  is that a field it does not carry reads as nil, never as somebody else's value.

import Testing

@testable import BBSystem

@Suite("Launch at login: reading launchd's view of a job")
struct LaunchdJobRecordTests {

  private typealias Record = LaunchAtLogin.LaunchdJobRecord

  private static let running = """
    gui/501/app.example.helper = {
    \tactive count = 3
    \tpath = (submitted by smd.19763)
    \ttype = Submitted
    \tstate = running

    \tprogram identifier = app.example.helper (mode: 1)
    \tparent bundle identifier = app.example
    \tdomain = gui/501 [100014]
    \tminimum runtime = 10
    \truns = 1
    \tpid = 84414
    \tlast exit code = (never exited)

    \tsemaphores = {
    \t\tsuccessful exit => 0
    \t}

    \tendpoints = {
    \t\t"app.example.helper" = {
    \t\t\tstate = 0
    \t\t}
    \t}
    }
    """

  @Test("A running job reads its state, run count and exit code")
  func runningJob() {
    #expect(
      Record.parse(Self.running)
        == Record(state: "running", runs: 1, lastExitCode: "(never exited)"))
  }

  /// A nested block carries keys of the same name; only the job's own line is the job's.
  @Test("A key inside a nested block is not read as the job's")
  func nestedKeysAreIgnored() {
    let nestedOnly = """
      gui/501/app.example.helper = {
      \tendpoints = {
      \t\tstate = 0
      \t}
      }
      """
    #expect(Record.parse(nestedOnly) == Record())
  }

  @Test("A job that keeps failing reads how it last ended")
  func failingJob() {
    let failing = """
      gui/501/app.example.helper = {
      \tstate = spawn scheduled
      \truns = 14
      \tlast exit code = 78: EX_CONFIG
      \tlast terminating signal = Killed: 9
      }
      """
    #expect(
      Record.parse(failing)
        == Record(
          state: "spawn scheduled", runs: 14, lastExitCode: "78: EX_CONFIG",
          lastTerminatingSignal: "Killed: 9"))
  }

  @Test("launchctl's 'Could not find service' status is a job that does not exist")
  func missingJobIsAbsent() {
    let transcript = "Bad request.\nCould not find service \"app.example.helper\" in domain"
    #expect(LaunchAtLogin.interpretLaunchctl(status: 113, transcript: transcript) == .absent)
  }

  @Test("Any other failure, or a success carrying no job fields, is unreadable")
  func otherAnswersAreUnreadable() {
    #expect(LaunchAtLogin.interpretLaunchctl(status: 1, transcript: Self.running) == .unreadable)
    #expect(LaunchAtLogin.interpretLaunchctl(status: 0, transcript: "") == .unreadable)
  }

  @Test("A successful print is the job it describes")
  func successIsLoaded() {
    #expect(
      LaunchAtLogin.interpretLaunchctl(status: 0, transcript: Self.running)
        == .loaded(Record(state: "running", runs: 1, lastExitCode: "(never exited)")))
  }
}

//  ProcessTerminationTests
//  Finding the processes an app is actually running.
//
//  REGRESSION TEST. `terminate` measured progress with `NSWorkspace.runningApplications`,
//  which did not see apps this server had launched itself from a headless process. The polite
//  pass matched nothing, the wait loop concluded the app had exited, and the relaunch produced
//  a SECOND copy — measured, two Messages processes at once, both writing chat.db, while the
//  restart endpoint reported success. Progress is now measured by process path.

import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("Process termination")
struct ProcessTerminationTests {

  /// The lookup must see a process REGARDLESS of how it was started — the whole point, since
  /// the ones that were missed had been spawned directly rather than through LaunchServices.
  @Test("A directly-spawned process is found by its executable path")
  func findsDirectlySpawnedProcess() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate() }

    // Give it a moment to appear in the process table.
    var found: [pid_t] = []
    for _ in 0..<40 where found.isEmpty {
      found = SystemProcessRunner.processIdentifiers(running: "/bin/sleep")
      if found.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(found.contains(process.processIdentifier))
  }

  @Test("A path nothing is running reports no processes")
  func reportsNothingForAbsentExecutable() {
    #expect(
      SystemProcessRunner.processIdentifiers(
        running: "/nonexistent/executable-\(UUID().uuidString)"
      ).isEmpty
    )
  }

  /// An exact path match, so `/bin/sleep` never matches some other binary that merely ends
  /// in "sleep" — killing the wrong process here would be killing a user's application.
  @Test("Matching is on the whole path, not a suffix")
  func matchesWholePath() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate() }
    try await Task.sleep(for: .milliseconds(200))

    #expect(SystemProcessRunner.processIdentifiers(running: "sleep").isEmpty)
    #expect(SystemProcessRunner.processIdentifiers(running: "/usr/bin/sleep").isEmpty)
  }

  /// Resolution matches `Target.executablePath`, so termination and launch always agree on
  /// which binary they mean.
  @Test("Application paths resolve the same way the injector's target does")
  func resolvesApplicationPaths() {
    let messages = SystemProcessRunner.executablePath(forApplicationNamed: "Messages")
    #expect(messages == "/System/Applications/Messages.app/Contents/MacOS/Messages")
    #expect(
      SystemProcessRunner.executablePath(
        forApplicationNamed: "NoSuchApp-\(UUID().uuidString)"
      ) == nil
    )
  }
}

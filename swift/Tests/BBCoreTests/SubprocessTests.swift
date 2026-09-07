//  SubprocessTests
//  The properties every call site would otherwise re-establish for itself.
//
//  The large-output test is the one that earns its keep: a pipe holds 64 KB, and reading it
//  after `waitUntilExit()` rather than during deadlocks the moment a child writes more than
//  that. It is also the failure that never shows up in development, because the commands we
//  run are quiet until the day one of them isn't — a `tar` listing a large archive, a tool
//  printing a stack trace.

import Foundation
import Testing

@testable import BBCore

@Suite("Subprocess")
struct SubprocessTests {

  @Test("Exit status and stdout come back")
  func capturesOutput() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "echo hello"], timeout: .seconds(10)
    )
    #expect(result.succeeded)
    #expect(result.status == 0)
    #expect(result.trimmedText == "hello")
  }

  @Test("A non-zero exit is reported, not thrown")
  func reportsFailureStatus() async throws {
    // Distinct from `Failure.launchFailed`: the command RAN. Throwing here would make
    // every caller that cares about the status write a catch block to recover it.
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "exit 3"], timeout: .seconds(10)
    )
    #expect(!result.succeeded)
    #expect(result.status == 3)
  }

  @Test("Merged output captures stderr")
  func mergedCapturesStandardError() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "echo out; echo err >&2"], output: .merged, timeout: .seconds(10)
    )
    #expect(result.text.contains("out"))
    #expect(result.text.contains("err"))
  }

  @Test("standardOutputOnly discards stderr")
  func standardOutputOnlyDropsStandardError() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "echo out; echo err >&2"],
      output: .standardOutputOnly, timeout: .seconds(10)
    )
    #expect(result.trimmedText == "out")
    #expect(!result.text.contains("err"))
  }

  @Test("Discarded output returns nothing but still reports the status")
  func discardedOutput() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "echo noise; exit 7"], output: .discarded, timeout: .seconds(10)
    )
    #expect(result.output.isEmpty)
    #expect(result.status == 7)
  }

  /// THE regression test. A pipe holds 64 KB; this writes about a megabyte.
  ///
  /// Draining after the child exits would deadlock here — the child blocks writing into a
  /// full pipe, and the parent blocks waiting for a child that can never finish. It would
  /// hang rather than fail, which is why it is written with a timeout well above what the
  /// command needs: a regression shows up as this test timing out, not as a wrong answer.
  @Test("Output larger than the pipe buffer does not deadlock", .timeLimit(.minutes(1)))
  func largeOutputDoesNotDeadlock() async throws {
    let result = try await Subprocess.run(
      "/bin/sh",
      ["-c", "for i in $(seq 1 20000); do echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; done"],
      timeout: .seconds(45)
    )
    #expect(result.succeeded)
    #expect(result.output.count > 800_000)
  }

  @Test("A command past its deadline is killed and reported")
  func timesOut() async throws {
    let started = ContinuousClock.now
    await #expect(throws: Subprocess.Failure.self) {
      try await Subprocess.run("/bin/sh", ["-c", "sleep 30"], timeout: .milliseconds(300))
    }
    // Returned on the deadline rather than after the command would have finished.
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  @Test("A binary that cannot be started throws rather than reporting an exit status")
  func launchFailure() async throws {
    await #expect(throws: Subprocess.Failure.self) {
      try await Subprocess.run("/nonexistent/binary", timeout: .seconds(5))
    }
  }

  /// stdin is `/dev/null` with no way to ask otherwise, so a child that reads it sees EOF
  /// immediately. Without that this test hangs — which is exactly what `unzip` did to the
  /// tool installer when an archive contained a name that already existed.
  @Test("A command that reads stdin sees EOF instead of hanging", .timeLimit(.minutes(1)))
  func stdinIsDetached() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "cat; echo done"], timeout: .seconds(20)
    )
    #expect(result.succeeded)
    #expect(result.trimmedText == "done")
  }

  @Test("The synchronous form behaves the same")
  func synchronousForm() throws {
    let result = try Subprocess.runSynchronously(
      "/bin/sh", ["-c", "echo sync"], timeout: .seconds(10)
    )
    #expect(result.succeeded)
    #expect(result.trimmedText == "sync")
  }

  @Test("The synchronous form also honours its deadline")
  func synchronousTimesOut() throws {
    #expect(throws: Subprocess.Failure.self) {
      try Subprocess.runSynchronously(
        "/bin/sh", ["-c", "sleep 30"], timeout: .milliseconds(300)
      )
    }
  }

  @Test("Environment entries are added to the inherited environment, not replacing it")
  func environmentIsMerged() async throws {
    let result = try await Subprocess.run(
      "/bin/sh", ["-c", "echo $BB_TEST_VALUE:$HOME"],
      environment: ["BB_TEST_VALUE": "set"],
      timeout: .seconds(10)
    )
    #expect(result.trimmedText.hasPrefix("set:"))
    // HOME is inherited; a replaced environment would leave this empty.
    #expect(result.trimmedText.count > "set:".count)
  }

  @Test("launch does not wait for the command to finish")
  func launchReturnsImmediately() throws {
    let started = ContinuousClock.now
    try Subprocess.launch("/bin/sh", ["-c", "sleep 5"])
    #expect(ContinuousClock.now - started < .seconds(2))
  }
}

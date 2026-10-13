//  ContinuationDeadlinePolicyTests
//  A wait that somebody else resumes, with a deadline, goes through `awaitContinuation`.
//
//  The hand-written shape is a raw continuation parked in a list plus a `Task` that sleeps and
//  then resumes it. It works until the caller is cancelled: cancellation does not resume a
//  continuation, so a client that hung up on a long poll stayed parked until the timer fired,
//  and a task group cancelling an injection that waited on one could not end until that
//  injection's own timeout. Five of them existed. `awaitContinuation` ends on the owner's
//  resume, the deadline or the caller's cancellation, and hands the owner its handle back to
//  drop.
//
//  The scan is per function: a raw continuation and a sleep in the same body is the shape. A
//  continuation bridging a one-shot callback, with no deadline, is not matched.
//
//  The second rule is the same failure in a loop. `try? await Task.sleep` is fine where the
//  loop then checks for cancellation; in a loop bounded only by a deadline or a count, a
//  cancelled sleep returns at once and the loop spins to its end, and the line after it was,
//  three times, an escalation (force-quit Messages, SIGKILL a tunnel) done for a caller that
//  had already gone. `poll(_:within:)` ends on cancellation.

import BBTestSupport
import Foundation
import Testing

@Suite("Continuation deadlines")
struct ContinuationDeadlinePolicyTests {

  private static let allowed: [String: String] = [
    "Sources/BBCore/Timeout.swift": "`awaitContinuation` itself",
    "Sources/BlueBubblesApp/BlueBubblesApp.swift":
      "`stopWithHardDeadline` abandons the loser on purpose, which no waiter shape does: the "
      + "process is exiting and a wedged stop must not hold a logout",
  ]

  @Test("No raw continuation is raced against a sleep")
  func deadlinesUseTheDoor() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 100)
      .filter { Self.allowed[$0.path] == nil }
    let function = try Regex(#"^\s*(@\w+(\(.*?\))? +)*(\w+ +)*func "#)
    let continuation = try Regex(#"with(Checked|Unsafe)(Throwing)?Continuation"#)
    let sleep = try Regex(#"\.sleep\(|asyncAfter"#)

    var offences: [Offence] = []
    for file in files {
      var start: SourceLine?
      var parks = false
      var sleeps = false
      func close() {
        if parks, sleeps, let start { offences.append(Offence(file, start)) }
      }
      for line in file.codeLines {
        if line.code.contains(function) {
          close()
          (start, parks, sleeps) = (line, false, false)
        }
        if line.code.contains(continuation) { parks = true }
        if line.code.contains(sleep) { sleeps = true }
      }
      close()
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "these race a raw continuation against a sleep; use `awaitContinuation` "
          + "(BBCore/Timeout.swift):\n" + offences.report))
  }

  @Test("A loop bounded by a deadline or a count does not sleep with try?")
  func deadlineLoopsEndOnCancellation() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 100)
    let bounded = try Regex(#"^\s*(while\b.*\b(deadline|now)\b|for _ in 0\.\.<)"#)
    let swallowedSleep = try Regex(#"try\? await [\w.]*sleep\("#)
    var offences: [Offence] = []
    for file in files {
      let lines = file.codeLines
      for (index, line) in lines.enumerated()
      where line.code.contains(bounded) && !line.code.contains("isCancelled") {
        // The whole loop, by brace depth: a sleep at the bottom of a long body is the
        // usual place for one.
        var depth = 0
        for body in lines[index...] {
          depth += body.code.filter { $0 == "{" }.count - body.code.filter { $0 == "}" }.count
          if body.code.contains(swallowedSleep) {
            offences.append(Offence(file, line))
            break
          }
          if depth <= 0, body.number != line.number { break }
        }
      }
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a bounded loop sleeps with try? and spins once cancelled; use "
          + "`poll(_:within:)` (BBCore/Polling.swift):\n" + offences.report))
  }
}

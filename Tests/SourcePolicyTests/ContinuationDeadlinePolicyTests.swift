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
//
//  The third is the same failure with `try` instead of `try?`: a loop whose catch-all wraps a
//  throwing sleep counts the cancellation as one more failure and goes round again. The
//  injector's retry loop did this, quitting Messages on every pass until its failure cap and
//  then blaming SIP. A loop that sleeps with `try` and catches everything has to say what it
//  does with cancellation: `catch is CancellationError`, `checkCancellation` or `isCancelled`.

import BBTestCore
import Foundation
import Testing

@Suite("Continuation deadlines")
struct ContinuationDeadlinePolicyTests {

  static let deadlines = PolicyRule(
    rule: "A wait that somebody else resumes, with a deadline, is never a raw continuation "
      + "raced against a sleep.",
    fix: "Use `awaitContinuation(timeout:timeoutError:register:abandon:)` in BBCore/Timeout.swift "
      + "and store the `OnceContinuation` it hands back.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

  static let boundedLoops = PolicyRule(
    rule: "A loop bounded by a deadline or a count never sleeps with `try?`, which spins the "
      + "loop to its end once the caller is cancelled.",
    fix: "Use `poll(_:within:)` or `retrying` with a `RetrySchedule` in BBCore/Polling.swift, "
      + "which end on cancellation.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

  static let catchAllLoops = PolicyRule(
    rule: "A loop whose catch-all wraps a throwing sleep says what it does with cancellation, "
      + "or it counts the cancellation as one more failure and goes round again.",
    fix: "Rethrow with `catch is CancellationError`, or check `isCancelled` or `checkCancellation` "
      + "inside the loop.",
    home: #"CLAUDE.md, "Never hand-roll a timeout""#)

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
    #expect(offences.isEmpty, Self.deadlines.comment(offences))
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
    #expect(offences.isEmpty, Self.boundedLoops.comment(offences))
  }

  @Test("A loop that catches everything around a sleep handles cancellation")
  func catchAllLoopsHonourCancellation() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", "Helper", minimum: 100)
    let loop = try Regex(#"^\s*(while|for|repeat)\b"#)
    let sleep = try Regex(#"try await [\w.]*sleep\("#)
    let catchAll = try Regex(#"\}\s*catch\s*\{"#)
    let cancellation = try Regex(#"CancellationError|checkCancellation|isCancelled"#)
    // A task spawned inside the loop is its own scope: its catch does not send the loop
    // round, so its lines are not the loop's.
    let spawned = try Regex(#"\bTask(\.detached)?\s*(\(.*\))?\s*\{"#)
    var offences: [Offence] = []
    for file in files {
      let lines = file.codeLines
      for (index, line) in lines.enumerated() where line.code.contains(loop) {
        var depth = 0
        var spawnedAt: Int?
        var (sleeps, catches, handles) = (false, false, false)
        for body in lines[index...] {
          let before = depth
          depth += body.code.filter { $0 == "{" }.count - body.code.filter { $0 == "}" }.count
          if spawnedAt == nil, body.number != line.number, body.code.contains(spawned) {
            spawnedAt = before
          }
          if spawnedAt == nil {
            if body.code.contains(sleep) { sleeps = true }
            if body.code.contains(catchAll) { catches = true }
            if body.code.contains(cancellation) { handles = true }
          }
          if let opened = spawnedAt, depth <= opened { spawnedAt = nil }
          if depth <= 0, body.number != line.number { break }
        }
        if sleeps, catches, !handles { offences.append(Offence(file, line)) }
      }
    }
    #expect(offences.isEmpty, Self.catchAllLoops.comment(offences))
  }
}

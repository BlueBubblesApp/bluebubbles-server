//  ListenerStopPolicyTests
//  No test stops a server from a detached task.
//
//  `defer` cannot await, so `defer { Task { await listener.stop() } }` hands the stop to a
//  task nobody waits for. The test returns, the next one starts, and the previous listener
//  may still be up; a stop that fails or hangs is never seen. A server a test starts is stopped inside the function that started it, after the body
//  returns or throws: `TestHTTPServer.run` in `CompositionTests` and `ReplayServer.run`
//  here are the two doors. This scan holds every file under `Tests/` to that.

import BBTestSupport
import Foundation
import Testing

@Suite("Servers are stopped, not abandoned")
struct ListenerStopPolicyTests {

  /// A `defer` whose body is a `Task { … }` (or `Task.detached`) that calls `.stop()` on
  /// anything. Matched on comment-free code across lines, so the layout does not matter.
  private static var detachedStop: Regex<AnyRegexOutput> {
    try! Regex(
      #"defer\s*\{\s*Task(\s*\.\s*detached)?\s*(\([^)]*\))?\s*"#
        + #"\{[^{}]*\.\s*stop\s*\(\s*\)[^{}]*\}\s*\}"#)
  }

  /// Every match in `file`, reported at the line the `defer` is on.
  static func offences(in file: SourceFile) -> [Offence] {
    let code = file.code
    let lines = file.lines
    return code.matches(of: detachedStop).map { match in
      let number = code[..<match.range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      let text = lines.indices.contains(number - 1) ? lines[number - 1].text : ""
      return Offence(path: file.path, line: number, text: text)
    }
  }

  @Test("No test stops a listener or server from a task spawned in a defer")
  func noDetachedStops() throws {
    let ownName = URL(fileURLWithPath: #filePath).lastPathComponent
    let files = try SourceScanner.swiftFiles(under: "Tests", minimum: 100)
      .filter { $0.name != ownName }
    let offenders = files.flatMap(Self.offences(in:))
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: """
          a server is stopped from a detached task, so the test can end while it is still \
          listening. Run it through TestHTTPServer.run (or ReplayServer.run), or stop it with \
          do/catch and `await` on both paths:
          \(offenders.report)
          """))
  }

  /// The matcher, against the shapes it must and must not catch, so a scan that finds
  /// nothing is known to be looking.
  @Test("The matcher finds the detached shape and leaves an awaited stop alone")
  func matcherSelfTest() {
    func count(_ text: String) -> Int {
      Self.offences(
        in: SourceFile(path: "t.swift", url: Repository.url("t.swift"), text: text)
      ).count
    }
    #expect(count("defer { Task { await listener.stop() } }") == 1)
    #expect(count("x()\ndefer {\n  Task {\n    await server.stop()\n  }\n}") == 1)
    #expect(count("defer { Task.detached { await holder.stop() } }") == 1)
    #expect(count("defer { Task(priority: .low) { await listener.stop() } }") == 1)
    let reported = Self.offences(
      in: SourceFile(
        path: "t.swift", url: Repository.url("t.swift"),
        text: "let a = 1\ndefer { Task { await listener.stop() } }"))
    #expect(reported.map(\.line) == [2])

    #expect(count("await listener.stop()") == 0)
    #expect(count("defer { session.finishTasksAndInvalidate() }") == 0)
    #expect(count("defer { helper.stop() }") == 0)
    #expect(count("// defer { Task { await listener.stop() } }") == 0)
  }
}

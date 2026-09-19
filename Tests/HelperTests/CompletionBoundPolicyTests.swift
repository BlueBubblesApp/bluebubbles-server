//  CompletionBoundPolicyTests
//  Every wait on an IMCore completion has a deadline.
//
//  `ResumeOnce`'s header states the contract it exists to keep: "It may never fire... The
//  wait is bounded, and a timeout is reported as a value rather than as a crash or a hang."
//  Twelve call sites honoured it and four called the untimed `wait()`.
//
//  This is not the usual hang. The waits are `async`, so nothing blocks Messages' main
//  thread; the request task simply never resumes, and it holds the retained IMCore objects
//  and the heap block for the life of the host process. The worst of the four sat on
//  `IMChatHistoryController.load`, which every reply, tapback, sticker, edit, unsend and
//  delete passes through, so one unanswered completion costs a transaction that never
//  replies and a leak that nothing reclaims.
//
//  A scan rather than a per-site assertion because the sites are the point: this rule is
//  exactly the kind the compiler cannot check and a reviewer forgets, and the file it
//  governs already carries the reasoning.

import Foundation
import Testing

@Suite("Completion waits are bounded")
struct CompletionBoundPolicyTests {

  @Test("No helper source calls the untimed wait")
  func everyWaitHasADeadline() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Helper")
    let walker = try #require(FileManager.default.enumerator(atPath: root.path))

    var scanned = 0
    var offenders: [String] = []
    for case let relative as String in walker where relative.hasSuffix(".swift") {
      // `ResumeOnce` itself declares both forms; the timed one is built on the untimed one.
      if relative.hasSuffix("ResumeOnce.swift") { continue }
      let source = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
      scanned += 1
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        guard code.contains(".wait()") else { continue }
        offenders.append("Helper/\(relative):\(index + 1): \(code)")
      }
    }

    #expect(scanned > 20, "the scan found only \(scanned) files; it is not reading Helper/")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: """
          these wait on a completion that may never fire. Use \
          `wait(timeout:onTimeout:)` and say what the absent answer is:

          \(offenders.joined(separator: "\n"))
          """))
  }
}

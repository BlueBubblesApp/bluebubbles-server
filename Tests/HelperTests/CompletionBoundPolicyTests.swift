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

import BBTestSupport
import Testing

@Suite("Completion waits are bounded")
struct CompletionBoundPolicyTests {

  @Test("No helper source calls the untimed wait")
  func everyWaitHasADeadline() throws {
    // `ResumeOnce` itself declares both forms; the timed one is built on the untimed one.
    let files = try SourceScanner.swiftFiles(under: "Helper", minimum: 21)
      .filter { !$0.path.hasSuffix("ResumeOnce.swift") }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(".wait()") }

    #expect(
      offences.isEmpty,
      Comment(
        rawValue: """
          these wait on a completion that may never fire. Use \
          `wait(timeout:onTimeout:)` and say what the absent answer is:

          \(offences.report)
          """))
  }
}

//  ServerStoppedNoticeTests
//  A page does not write its own "server not running" state.
//
//  `ServerStoppedNotice` is the one place that sentence lives, and the one place with the
//  Start button on it. A page that writes the sentence itself is a page with no remedy, which
//  is what nine of them were. A source scan, in the shape of `AccessibilityPolicyTests`,
//  because a SwiftUI view cannot be inspected from a test without trapping.

import BBTestSupport
import Testing

@testable import BlueBubblesApp

@Suite("Server-stopped placeholders")
struct ServerStoppedNoticeTests {

  /// A settings tab draws live rows during the start delay, because the settings door is
  /// attached before it; the notice under them must not say "not running" over rows that
  /// plainly work.
  @Test("While the server is coming up, the notice says so rather than 'not running'")
  func startingIsNotStopped() {
    for phase in [ServerPhase.starting, .waiting(.seconds(5))] {
      #expect(phase.isComingUp)
      #expect(phase.unavailableHeadline == "Server starting")
      #expect(!phase.unavailableDetail.contains("not running"))
      #expect(phase.unavailableExplanation(purpose: "view contacts").hasSuffix("view contacts."))
    }
    for phase in [ServerPhase.idle, .failed("x"), .migrationRequired] {
      #expect(!phase.isComingUp)
      #expect(phase.unavailableHeadline == "Server not running")
    }
  }

  @Test("Only ServerStoppedNotice spells the server-not-running placeholder")
  func onePlaceholder() throws {
    let pattern = try Regex(#""Server not running"|"Start the server to "#)
    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule this file
    // enforces then stops being enforced while looking exactly like compliance.
    // The notice, and the phase's words it draws (off the view so they can be asserted).
    let files = try SourceScanner.swiftFiles(under: "Sources/BlueBubblesApp", minimum: 11)
      .filter {
        !$0.path.hasSuffix("ServerStoppedNotice.swift")
          && !$0.path.hasSuffix("ServerAvailability.swift")
      }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a page writes its own stopped-server placeholder; use `ServerStoppedNotice`:\n"
          + offences.report)
    )
  }
}

//  RealSenderPolicyTests
//  Only the composition root builds what sends, and tests stay away from it.
//
//  The `swift test` host runs what the real runner is given, so a test that reaches it puts a
//  send through Messages from the developer's own account, to whatever address the test made
//  up. Nothing reports it: the send path answers, and the test passes. The sender, the Shortcut
//  manager and the interfaces take these with no default, so the compiler makes every caller
//  name one, and this is what stops a caller naming the real one.

import BBTestSupport
import Foundation
import Testing

@Suite("What really sends stays out of the tests")
struct RealSenderPolicyTests {

  static let noRealRunner = PolicyRule(
    rule: "No test names the real `AppleScriptRunner`, which sends through Messages from the "
      + "developer's own account.",
    fix: "Give the test a stub runner, such as `InterfaceFixtures.noSender`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let noRealShortcut = PolicyRule(
    rule: "No test builds the real `ShortcutsCommand`, because running the Shortcut sends.",
    fix: "Give the test a stub, such as `InterfaceFixtures.noShortcuts`.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  static let oneRealSender = PolicyRule(
    rule: "Shipping code builds what sends in one place, the composition root's shared "
      + "services, so a test composition can replace it.",
    fix: "Move the construction into `ServerComposition+SharedServices.swift` and take the "
      + "value from there.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  /// Run a real runner on a script that names no application, to test the runner itself.
  private static let runnerTests: Set<String> = [
    "Tests/BBAppleScriptTests/SendFailureTests.swift",
    "Tests/BBAppleScriptTests/ScriptCacheReentrancyTests.swift",
  ]
  /// Sends for real on purpose, so it is exempt only while a run has to ask for it.
  private static let liveSuite = "Tests/BBAppleScriptTests/LiveSendTests.swift"
  private static let thisFile = "Tests/CompatibilityTests/RealSenderPolicyTests.swift"
  private static let compositionRoot =
    "Sources/BlueBubblesServerCore/Composition/ServerComposition+SharedServices.swift"

  @Test("No test names the real runner, except those testing it on a script that sends nothing")
  func testsDoNotNameTheRealRunner() throws {
    let files = try SourceScanner.swiftFiles(under: "Tests", minimum: 200)
    let offences = SourceScanner.offences(in: files) { file, line in
      !Self.runnerTests.contains(file.path) && file.path != Self.liveSuite
        && file.path != Self.thisFile
        // The substring first: a `Regex` per line of every test file was most of this test.
        && line.code.contains("AppleScriptRunner") && line.code.contains(/\bAppleScriptRunner\b/)
    }
    #expect(offences.isEmpty, Self.noRealRunner.comment(offences))

    for path in Self.runnerTests {
      let file = try SourceScanner.file(path)
      #expect(file.code.contains("AppleScriptRunner"), "\(path) no longer needs its exemption")
      #expect(!file.code.contains("tell application"), "\(path) runs a script that names an app")
    }
  }

  /// Without the gate, an ordinary `swift test` sends a real message on every run.
  @Test("The live suite sends only when a run names the chat")
  func liveSuiteIsGated() throws {
    let code = try SourceScanner.file(Self.liveSuite).code
    #expect(code.contains("AppleScriptRunner"), "\(Self.liveSuite) no longer needs its exemption")
    #expect(code.contains(#"environment["BB_LIVE_SEND_GUID"]"#))
    #expect(code.contains("if: liveGUID != nil"), "the suite runs without being asked to")
  }

  /// The Private API counterpart: it reaches Messages through a server the developer runs,
  /// so what has to be gated is the request, and a run must name the server, its password
  /// and the chat before it sends.
  @Test("The live app-message suite sends only when a run names the server and the chat")
  func liveAppMessageSuiteIsGated() throws {
    let code = try SourceScanner.file("Tests/BBInterfacesTests/LiveAppMessageSendTests.swift").code
    #expect(code.contains(#"environment["BB_LIVE_SERVER_URL"]"#))
    #expect(code.contains(#"environment["BB_LIVE_SERVER_PASSWORD"]"#))
    #expect(code.contains(#"environment["BB_LIVE_SEND_GUID"]"#))
    #expect(code.contains("if: liveServer != nil"), "the suite runs without being asked to")
  }

  @Test("No test builds the real Shortcut command")
  func testsDoNotBuildTheRealShortcutCommand() throws {
    let files = try SourceScanner.swiftFiles(under: "Tests", minimum: 200)
    let offences = SourceScanner.offences(in: files) { file, line in
      file.path != Self.thisFile && line.code.contains("ShortcutsCommand(")
        && line.code.contains(/\bShortcutsCommand\(/)
    }
    #expect(offences.isEmpty, Self.noRealShortcut.comment(offences))
  }

  @Test("Shipping code builds what sends in one place")
  func oneRealSender() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 500)
    let construction =
      /\b(AppleScriptRunner|AppleScriptMessageSender|ShortcutsCommand|GroupChatShortcutManager)\(/
    // Every name above contains one of these, and a substring is far cheaper than a `Regex`.
    func mayConstruct(_ line: SourceLine) -> Bool {
      (line.code.contains("AppleScript") || line.code.contains("Shortcut"))
        && line.code.contains(construction)
    }
    let built = SourceScanner.offences(in: files) { _, line in mayConstruct(line) }
    let elsewhere = SourceScanner.offences(in: files) { file, line in
      file.path != Self.compositionRoot && mayConstruct(line)
    }
    #expect(!built.isEmpty, "found no construction at all; the scan has stopped matching")
    #expect(elsewhere.isEmpty, Self.oneRealSender.comment(elsewhere))
  }
}

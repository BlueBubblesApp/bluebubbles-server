//  SharedUtilityPolicyTests
//  Each of BBCore's shared values-and-formats utilities is the ONLY place its job is done,
//  scanned for in the source in the same shape as `LogRedactionPolicyTests`.
//
//  Hand-written copies of each of these drift apart without anything failing: a second
//  constant-time comparison picks a different length policy, a second version read picks a
//  different fallback, a second epoch conversion a different rounding, and a client sees
//  the difference. A comment saying "use the shared one" is read once; this runs on every
//  build. Each rule names its one door, and an exception is listed with the reason it
//  cannot go through it.

import BBTestSupport
import Foundation
import Testing

@Suite("Shared utilities have one implementation")
struct SharedUtilityPolicyTests {

  private struct Rule {
    let name: String
    /// Any of these on a code line is an offence.
    let patterns: [String]
    /// Paths relative to `Sources/`, which may contain the pattern.
    let allowed: [String: String]
    /// Where the work belongs, for the failure message.
    let door: String
  }

  private static let rules: [Rule] = [
    Rule(
      name: "home directory",
      // A sandboxed process gets its container from both of these, which is how a path
      // two processes compute ends up different on each side (CLAUDE.md rule 5). The
      // server is not sandboxed, so for it they agree with `getpwuid`, by accident rather
      // than by design.
      patterns: ["NSHomeDirectory()", "homeDirectoryForCurrentUser"],
      allowed: [
        "BBCore/ApplicationSupport.swift": "the door itself, as its last-resort fallback"
      ],
      door: "ApplicationSupport.realHomeDirectory"),
    Rule(
      name: "constant-time comparison",
      patterns: ["|= left ^ right", "difference |="],
      allowed: ["BBCore/ConstantTime.swift": "the implementation"],
      door: "ConstantTime.equals"),
    Rule(
      name: "base64url",
      patterns: [#"(of: "+", with: "-")"#, #"(of: "-", with: "+")"#],
      allowed: ["BBCore/Base64URL.swift": "the implementation"],
      door: "Base64URL.encode / Base64URL.decode"),
    Rule(
      name: "bundle version",
      patterns: ["CFBundleShortVersionString"],
      allowed: ["BBCore/AppVersion.swift": "the implementation"],
      door: "AppVersion.bundled / AppVersion.current"),
    Rule(
      name: "epoch milliseconds",
      patterns: ["timeIntervalSince1970 * 1000", "timeIntervalSince1970 * 1_000"],
      // The helper wire has its own door in the contract, `Date.wireMilliseconds`, because
      // `BBPrivateAPIContract` is compiled into Messages.app and cannot link BBCore.
      allowed: ["BBCore/EpochMilliseconds.swift": "the implementation"],
      door: "Date.epochMilliseconds / epochMilliseconds(rounded:), or on the helper wire "
        + "Date.wireMilliseconds"),
    Rule(
      name: "plural",
      patterns: [#"== 1 ? "" : "s""#],
      allowed: [
        "BBAppleScript/AppleScriptMessageSender.swift":
          "its sentence reaches a client inside an `iMessage Error`, and `counted` formats "
          + "the number for the server's locale"
      ],
      door: "Int.counted"),
    Rule(
      name: "withheld secret",
      // One spelling for "a secret was here and is not shown", so an alert, a diagnostic
      // report and an audit record all read the same. The app's longer `••••••••` is a
      // different thing, the mask over a stored field in a form, and does not match.
      patterns: [#""••••""#],
      allowed: ["BBCore/BBError.swift": "`DiagnosticValue.secret`, the spelling itself"],
      door: "DiagnosticValue.secret.redactedDescription (JSONValue.redacted in an audit record)"),
    Rule(
      name: "loose boolean",
      // Six readers of "is this text true" disagreed; one took only `"true"`.
      patterns: [#"["1", "true""#, #"case "1", "true""#],
      allowed: ["BBCore/LooseBool.swift": "the reading itself"],
      door: "Bool(loose:)"),
    Rule(
      name: "hexadecimal",
      patterns: [#"String(format: "%02x""#, #"String(format: "%02X""#],
      // A byte at a time. A pair of bytes (an IPv6 group) and percent-encoding are other
      // jobs, and their formats do not match.
      allowed: [:],
      door: "Sequence<UInt8>.hexString(uppercase:)"),
    Rule(
      name: "state directory",
      // One root, which `BB_SUPPORT_DIRECTORY` redirects. A path spelled beside it is not
      // redirected with it, so a test or a migration run pointed at a throwaway directory
      // shared the real install's uploads, tool downloads and tailnet identity.
      patterns: [
        "Application Support/bluebubbles-server", "Application Support/BlueBubbles",
        "SocketLocation.supportDirectory",
      ],
      allowed: [
        "BBCore/ApplicationSupport.swift": "the root itself, and the pre-release folder it adopts",
        "BlueBubblesServerCore/Composition/SingleInstanceLock.swift":
          "the lock guards what the override does not move: the port and the helper sockets",
      ],
      door: "ApplicationSupport.directory and the paths beside it"),
  ]

  /// Every Swift file under `Sources/`, keyed by its path relative to `Sources/`, which is
  /// how the rules name their exceptions.
  private func sources() throws -> [String: SourceFile] {
    // A floor, so a scan that silently read nothing is not mistaken for a pass.
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 101)
    return Dictionary(
      uniqueKeysWithValues: files.map { (String($0.path.dropFirst("Sources/".count)), $0) })
  }

  @Test("Each job is done through its one door")
  func oneDoorEach() throws {
    let files = try sources()
    for rule in Self.rules {
      let checked = files.filter { rule.allowed[$0.key] == nil }.values.sorted { $0.path < $1.path }
      let offences = SourceScanner.offences(in: checked) { _, line in
        rule.patterns.contains(where: line.code.contains)
      }
      #expect(
        offences.isEmpty,
        """
        \(rule.name): use \(rule.door).
        \(offences.report)
        """)
    }
  }

  /// The reading direction of epoch milliseconds, which a substring cannot name: a division
  /// by a thousand inside `Date(timeIntervalSince1970:)`. Twenty-one sites wrote it out, and
  /// the ones reading a request did so through `intValue`, which a numeric string fails.
  @Test("Epoch milliseconds are read through one door")
  func epochMillisecondsAreReadThroughOneDoor() throws {
    let allowed = ["Sources/BBCore/EpochMilliseconds.swift": "the door itself"]
    let division = try Regex(#"timeIntervalSince1970:[^\n]*/\s*1_?000\b"#)
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 101)
      .filter { allowed[$0.path] == nil }
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(division) }
    #expect(
      offences.isEmpty,
      Comment(rawValue: "use Date(epochMilliseconds:):\n" + offences.report))
  }

  /// An exception that no longer matches anything is a stale reason, and a stale reason is
  /// how an allowlist turns into a list of places nobody looks.
  @Test("Every exception is still needed")
  func exceptionsAreLive() throws {
    let files = try sources()
    for rule in Self.rules {
      for path in rule.allowed.keys {
        let lines = files[path]?.codeLines ?? []
        #expect(
          lines.contains { line in rule.patterns.contains(where: line.code.contains) },
          "\(rule.name): \(path) is allowed but no longer matches; remove the exception")
      }
    }
  }
}

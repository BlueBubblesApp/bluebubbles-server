//  ScannerMessagePolicyTests
//  Every source-scanning policy test says what its rule is, how to fix an offender and where
//  the rule is written, through `PolicyRule`.
//
//  A policy scanner's failure used to be its offenders and a fragment of a sentence, and the
//  fragment was different in every file: some named the fix, some named the rule, none named
//  the document the rule came from. The reader is usually an agent mid-task, and it acts on
//  the message without opening the test, so a fragment costs a guess at the rule, a guess at
//  the fix, and no way to tell whether the rule is one it may argue with. `PolicyRule` frames
//  every failure the same way, and this scan is what keeps a scanner added later on it.
//
//  A scanner is a test file that does any of three things: walks the tree through
//  `SourceScanner` (`swiftFiles`, `files` or `offences`); is named `*PolicyTests.swift` and
//  reads through `SourceScanner` at all, which is the filter the table in docs/TESTING.md is
//  held to; or scans through a sibling's walker, `ViewPlumbingPolicyTests.scan`. A test of
//  another name that reads ONE named file through `SourceScanner.file(_:)` or `family(_:)` is a
//  wiring check, whose failure names the missing line and the file it belongs in, and it is not
//  held to this.
//
//  An exemption names a scanner with no rule to frame (the scanner's own tests, a test that
//  pins numbers) or one that still reports through its own wrapper, and a stale one fails the
//  build so the list cannot outlive what it names.

import BBTestCore
import Testing

@Suite("Policy scanners report through PolicyRule")
struct ScannerMessagePolicyTests {

  static let framedFailures = PolicyRule(
    rule: "A source-scanning policy test reports its offenders through a `PolicyRule`, so the "
      + "failure says what the rule is, how to fix an offender and where the rule is written.",
    fix: "Declare a `static let` `PolicyRule` near the top of the suite and hand the offenders "
      + "to its `comment(_:)` in the `#expect`.",
    home: "CLAUDE.md, "
      + #""A rule the compiler cannot check ships with a test that scans the source for it""#)

  /// The calls that walk the tree. A file whose code makes one is a scanner.
  private static let walks = [
    "SourceScanner.swiftFiles(", "SourceScanner.files(", "SourceScanner.offences(",
    "ViewPlumbingPolicyTests.scan(", "ViewPlumbingPolicyTests.forEachSource(",
  ]

  /// Scanners that do not report through a `PolicyRule`, by repository path, with the reason.
  private static let exempt: [String: String] = [
    "Tests/SourcePolicyTests/SourceScannerTests.swift":
      "tests the scanner itself and states no rule",
    "Tests/SourcePolicyTests/DocumentationDriftTests.swift":
      "pins counts and sizes against the documents; a failure names the number and the "
      + "document rather than an offending line",
    "Tests/BBIMessageTests/ChatDatabaseSafetyTests.swift":
      "reports through its own wrapper; converting it is an edit to BBIMessageTests",
    "Tests/BBIMessageTests/ChatGUIDClausePolicyTests.swift":
      "reports through its own wrapper; converting it is an edit to BBIMessageTests",
    "Tests/SourcePolicyTests/UnarchivePolicyTests.swift":
      "reports through its own wrapper; converting it is an edit to BBIMessageTests",
  ]

  /// Every test file that is a scanner, outside the scanner's own module.
  private static func scanners() throws -> [SourceFile] {
    try SourceScanner.swiftFiles(under: "Tests", minimum: 101)
      .filter {
        !$0.path.hasPrefix("Tests/BBTestCore/") && !$0.path.hasPrefix("Tests/BBTestSupport/")
      }
      .filter { file in
        let walksTheTree = file.codeLines.contains { line in
          walks.contains(where: line.code.contains)
        }
        let isNamedPolicy =
          file.name.hasSuffix("PolicyTests.swift") && file.code.contains("SourceScanner.")
        return walksTheTree || isNamedPolicy
      }
  }

  /// The line that makes `file` a scanner, for the report.
  private static func firstScan(in file: SourceFile) -> String {
    let line =
      file.codeLines.first { line in walks.contains(where: line.code.contains) }
      ?? file.codeLines.first { $0.code.contains("SourceScanner.") }
    return line?.text.trimmingCharacters(in: .whitespaces) ?? ""
  }

  @Test("Every scanner frames its failure with a PolicyRule")
  func everyScannerHasARule() throws {
    let scanners = try Self.scanners()
    // A floor: a tree with no scanners in it is a moved directory, not a clean one.
    #expect(scanners.count >= 40, "found only \(scanners.count) scanners; the walk is not reading")

    let offenders =
      scanners
      .filter { Self.exempt[$0.path] == nil && !$0.code.contains("PolicyRule(") }
      .map { "\($0.path): \(Self.firstScan(in: $0))" }
    #expect(offenders.isEmpty, Self.framedFailures.comment(offenders))
  }

  /// An exemption that names a file that no longer walks the tree, or that reports through a
  /// `PolicyRule` after all, is a stale reason.
  @Test("Every exemption is still needed")
  func exemptionsAreLive() throws {
    let scanners = Dictionary(uniqueKeysWithValues: try Self.scanners().map { ($0.path, $0) })
    for (path, reason) in Self.exempt.sorted(by: { $0.key < $1.key }) {
      let file = scanners[path]
      #expect(file != nil, "\(path) is exempt (\(reason)) but no longer walks the tree")
      #expect(
        file?.code.contains("PolicyRule(") != true,
        "\(path) reports through a PolicyRule; remove its exemption")
    }
  }
}

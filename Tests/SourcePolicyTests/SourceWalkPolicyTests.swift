//  SourceWalkPolicyTests
//  A test that reads the tree reads it through `SourceScanner`, never a walk of its own.
//
//  `SourceScanner` (`Tests/BBTestCore`) decides, once, what a comment is, which
//  directories are skipped and how few files a scan may find before it throws. A test that
//  reaches for `FileManager` to walk a directory makes those decisions again, differently,
//  and nothing reports it: the walk compiles, the same line becomes a finding in one policy
//  and invisible to the next, and a scan that reads too little still passes. So the walking
//  calls themselves are refused outside the test-support targets, `BBTestCore` and
//  `BBTestSupport`.
//
//  An exemption is a walk over something that is not source: a temporary directory a test
//  made, or a corpus of data the scanner has no opinion about. Each names its reason, and a
//  stale one fails the build.

import BBTestCore
import Testing

@Suite("Source walks go through SourceScanner")
struct SourceWalkPolicyTests {

  static let oneWalk = PolicyRule(
    rule: "A test outside the test-support targets reads the tree through `SourceScanner`, never a "
      + "directory walk of its own.",
    fix: "Read through `SourceScanner.files(under:)` or `SourceScanner.file(_:)`, or list the "
      + "file in `exempt` with the reason what it walks is not source.",
    home: #"docs/TESTING.md, "Source-scanning policy tests read through one scanner""#)

  /// The calls that walk a directory.
  private static let walks = [".enumerator(", "contentsOfDirectory(", "subpathsOfDirectory("]

  /// Files allowed to walk a directory themselves, by repository path, with the reason.
  private static let exempt: [String: String] = [
    "Tests/SourcePolicyTests/SourceWalkPolicyTests.swift":
      "this file spells the calls it refuses",
    "Tests/BBInterfacesTests/AttachmentCacheTests.swift":
      "lists the temporary cache directory the test created",
    "Tests/BBToolingTests/ToolInstallTests.swift":
      "lists the installed versions under the test's temporary tool root",
    "Tests/CompositionTests/ServerExportTests.swift":
      "checks the test's temporary export directory is empty, reads the members an "
      + "inspection extracted, and looks for extractions a failed import left behind",
    "Tests/CompositionTests/AttachmentChunkTests.swift":
      "lists what the test's temporary upload store assembled",
    "Tests/BBPrivateAPICatalogTests/CapabilityCatalogTests.swift":
      "lists the release directories under docs/headers, which hold header dumps, not source",
    "Tests/BBSerializationTests/RowLiteralTests.swift":
      "lists the per-release schema sample directories under docs/database/samples",
    "Tests/BBOpenAPITests/FixtureCoverageTests.swift":
      "reads the recorded fixture corpus, which is data",
    "Tests/CompatibilityTests/CompatibilityContractTests.swift":
      "reads the recorded fixture corpus, which is data",
    "Tests/CompatibilityTests/DenyListedShapeCoverageTests.swift":
      "reads the recorded fixture corpus, which is data",
  ]

  private static func walksByHand() throws -> [Offence] {
    let tests = try SourceScanner.swiftFiles(under: "Tests", minimum: 101)
      .filter {
        !$0.path.hasPrefix("Tests/BBTestCore/") && !$0.path.hasPrefix("Tests/BBTestSupport/")
      }
    return SourceScanner.offences(in: tests) { _, line in
      walks.contains(where: line.code.contains)
    }
  }

  @Test("No test outside the test-support targets walks a directory by hand")
  func noHandRolledWalks() throws {
    let offences = try Self.walksByHand().filter { Self.exempt[$0.path] == nil }
    #expect(offences.isEmpty, Self.oneWalk.comment(offences))
  }

  /// An exemption that no longer matches anything is a stale reason, and a stale reason is
  /// how an allowlist turns into a list of places nobody looks.
  @Test("Every exemption is still needed")
  func exemptionsAreLive() throws {
    let walking = Set(try Self.walksByHand().map(\.path))
    for path in Self.exempt.keys.sorted() {
      #expect(walking.contains(path), "\(path) is exempt but no longer walks a directory")
    }
  }
}

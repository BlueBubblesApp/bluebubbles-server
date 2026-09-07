//  CompatibilityContractTests
//  What the corpus IS, and what the diff engine does with two objects. Not the replay.
//
//  This header used to open with "Replays fixtures recorded from the running Node server
//  against the Swift server", and no test in the file did: one counts the files, one checks
//  they cover more than 200s, one scans them for personal data, and `StrictDiffTests` drives
//  `ResponseDiff` against hand-built dictionaries. None of them decoded a fixture, let alone
//  issued one. So "the compatibility contract is mechanically enforced" meant "it was
//  enforced once, by hand, on one Mac, in August" — and while it meant that, the envelope's
//  `message` and `error.message` sat swapped on every error response the server sent.
//
//  The replay is `FixtureReplayTests`, in this directory. These two suites are the halves it
//  needs — a corpus worth replaying, and a diff that fails in both directions.
//
//  Fixtures are produced by Tools/conformance-recorder. See `.claude/docs/decisions.md` and
//  `.claude/docs/workflow.md` § "The parity harness is the important one".

import BBParity
import Foundation
import Testing

@Suite("Fixture corpus")
struct FixtureCorpusTests {

  @Test("Fixture directory is present and discoverable")
  func fixtureDirectoryExists() throws {
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(atPath: Self.corpusRoot.path, isDirectory: &isDirectory),
      "swift/Fixtures/http must exist for the parity harness to find it"
    )
    #expect(isDirectory.boolValue)
  }

  /// The corpus is not empty, which for most of this project's life it was.
  ///
  /// Every "the parity harness asserts this" claim in the design notes was an intention
  /// until these were recorded, and the cost was measurable: `GET /server/alert` had drifted
  /// three ways, `chat/count` returned a different shape entirely, and about forty routes
  /// answered "Success" where the reference sends its own message. A floor rather than an
  /// exact count, so adding fixtures does not fail the suite.
  @Test("The corpus has fixtures in it")
  func corpusIsRecorded() throws {
    let files = try Self.fixtureFiles()
    #expect(
      files.count >= 40,
      "only \(files.count) fixtures; re-record with Tools/conformance-recorder"
    )
  }

  /// Error envelopes are contract too — the status/error-type pairing is one of the
  /// compatibility invariants (`.claude/docs/decisions.md` § "1. The compatibility
  /// contract"), and a corpus of nothing but 200s would not pin it.
  ///
  /// This also guards the recorder itself: fixture names carry their status precisely
  /// because they did not, and the error cases silently overwrote the success cases
  /// recorded alongside them.
  @Test("The corpus covers failure statuses, not only 200")
  func corpusCoversErrors() throws {
    let names = try Self.fixtureFiles().map(\.lastPathComponent)
    for status in ["400", "401", "404"] {
      #expect(
        names.contains { $0.hasSuffix("-\(status).json") },
        "no \(status) fixture recorded"
      )
    }
  }

  /// No personal data reaches the repository.
  ///
  /// A corpus recorded against a real Mac carries the operator's address book and the text
  /// of real conversations. The recorder scrubs by default; this fails if someone records
  /// with `--no-scrub` and commits the result, which is the one mistake here that cannot be
  /// undone by a later commit.
  @Test("No real addresses are committed in the corpus")
  func corpusCarriesNoPersonalData() throws {
    let email = try Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")

    for file in try Self.fixtureFiles() {
      let text = try String(contentsOf: file, encoding: .utf8)
      let addresses = text.matches(of: email)
        .map { String(text[$0.range]) }
        .filter { $0 != "person@example.com" && !$0.hasSuffix("@V.Y") }
      #expect(
        addresses.isEmpty,
        "\(file.lastPathComponent) carries \(addresses.prefix(3))"
      )
      #expect(!text.contains("+1616"), "\(file.lastPathComponent) carries a real number")
    }
  }

  /// The recorded corpus, which lives OUTSIDE this test target.
  ///
  /// NOT a bundled resource, because it is not parity-only: the same recordings are what
  /// `bb-openapi` reads to report which endpoints have a documented response, and burying
  /// them in a migration-specific test target would make that read look like a layering
  /// violation. `node-route-table.json` IS a bundled resource — it is generated from
  /// `httpRoutes.ts` purely to diff route tables, and nothing outside this target wants it.
  ///
  /// Reached by path from this file rather than through `Bundle.module`, because SwiftPM
  /// only bundles resources that live inside the target directory.
  static let corpusRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // CompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // swift
    .appendingPathComponent("Fixtures/http")

  static func fixtureFiles() throws -> [URL] {
    let root = corpusRoot
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default
      .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
  }
}

@Suite("Strict two-way diff")
struct StrictDiffTests {

  /// The property that matters most: adding a key to a response is a compatibility break,
  /// not a harmless enhancement. A one-way diff would let it through.
  @Test("An added key fails the diff")
  func addedKeyIsRejected() {
    let recorded: [String: Any] = ["status": 200, "message": "Success"]
    let actual: [String: Any] = ["status": 200, "message": "Success", "title": "Extra"]
    let differences = diff(expected: recorded, actual: actual)
    #expect(differences.contains { $0.contains("title") })
  }

  /// The requirement, stated as a test: every field the reference sends must be present.
  /// This is the half that matters — a field of ours that the reference lacks is tolerable,
  /// a field of the reference's that we lack is the bug this whole harness exists to catch.
  @Test("A declared addition is allowed; a missing reference field never is")
  func additionsAreDeclarable() {
    let recorded: [String: Any] = ["status": 200, "guid": "A"]

    // Undeclared: reported, because one-way the diff stops detecting a replaced field.
    // (A name nothing else declares — `backend` is in the shipping list.)
    let added: [String: Any] = ["status": 200, "guid": "A", "somethingOfOurs": 1]
    #expect(!diff(expected: recorded, actual: added).isEmpty)

    // Declared: allowed. `acceptedDifferences` did not cover added keys at all before —
    // the entry silenced a value check for a key the unexpected-key pass had already
    // failed on, so declaring one changed nothing.
    #expect(
      ResponseDiff.compare(
        expected: recorded, actual: added,
        accepting: ["somethingOfOurs": "additive, on purpose"]
      ).isEmpty
    )

    // And no declaration lets a reference field go missing.
    let dropped: [String: Any] = ["status": 200]
    let missing = ResponseDiff.compare(
      expected: recorded, actual: dropped, accepting: ["guid": "declared anyway"]
    )
    #expect(missing.contains { $0.kind == .missingKey && $0.path == "guid" })
  }

  @Test("A missing key fails the diff")
  func missingKeyIsRejected() {
    let recorded: [String: Any] = ["status": 200, "message": "Success", "data": "pong"]
    let actual: [String: Any] = ["status": 200, "message": "Success"]
    let differences = diff(expected: recorded, actual: actual)
    #expect(differences.contains { $0.contains("data") })
  }

  /// `data` and `metadata` are omitted when absent — never emitted as null. Clients
  /// distinguish the two, so null-vs-absent is a real difference.
  @Test("An explicit null is not the same as an omitted key")
  func nullIsNotAbsent() {
    let recorded: [String: Any] = ["status": 200]
    let actual: [String: Any] = ["status": 200, "data": NSNull()]
    #expect(!diff(expected: recorded, actual: actual).isEmpty)
  }

  @Test("Volatile fields compare by presence, not value")
  func volatileFieldsIgnoreValue() {
    let recorded: [String: Any] = ["guid": "A", "created": 1_700_000_000_000]
    let actual: [String: Any] = ["guid": "A", "created": 1_800_000_000_000]
    #expect(diff(expected: recorded, actual: actual).isEmpty)
  }

  @Test("A volatile field still may not disappear")
  func volatileFieldsMustStillExist() {
    let recorded: [String: Any] = ["guid": "A", "created": 1_700_000_000_000]
    let actual: [String: Any] = ["guid": "A"]
    #expect(!diff(expected: recorded, actual: actual).isEmpty)
  }
}

/// Structural comparison of two decoded JSON objects.
///
/// Returns a human-readable description of every difference; an empty array means the two
/// are compatible. Volatile fields are compared for presence only.
/// The tests' existing shape, onto the shared implementation.
///
/// The comparison itself now lives in `BBParity.ResponseDiff`, because Phase 12's live
/// side-by-side runner needs the same one. Two copies would drift, and a live run reporting
/// "no differences" because its copy had stopped checking something would be worse than no
/// run at all.
func diff(expected: [String: Any], actual: [String: Any], path: String = "") -> [String] {
  ResponseDiff.compare(expected: expected, actual: actual, path: path).map(\.description)
}

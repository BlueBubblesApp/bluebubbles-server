//  CompatibilityContractTests
//  Replays fixtures recorded from the running Node server against the Swift server and
//  diffs them STRICTLY IN BOTH DIRECTIONS — an added key fails exactly like a missing one.
//
//  That bidirectional strictness is the point. It is what mechanically enforces the
//  compatibility contract, rather than relying on everyone remembering it: every opt-in
//  field (?fields=extended on alerts, replay=1 on the socket, negotiated payload codecs) is
//  proven absent from the default response instead of merely intended to be.
//
//  Fixtures are produced by Tools/conformance-recorder. See `.claude/docs/decisions.md` and § Verification.

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
  /// invariants § 11 names, and a corpus of nothing but 200s would not pin it.
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
  /// It used to be a bundled resource here, and it is not one any more because it stopped
  /// being parity-only: the same recordings are what `bb-openapi` reads to report which
  /// endpoints have a documented response, and burying them in a migration-specific test
  /// target made that read look like a layering violation. `node-route-table.json` DID stay
  /// a bundled resource — it is generated from `httpRoutes.ts` purely to diff route tables,
  /// and nothing outside this target wants it.
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

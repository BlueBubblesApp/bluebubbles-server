//  DenyListedShapeCoverageTests
//  Every deny-listed fixture that records a reference payload is diffed by some suite.
//
//  `FixtureReplay` refuses to replay anything that would reach Messages or act on this Mac,
//  and it is right to: its first run locked the developer's screen. But the refusal was
//  SILENT about the consequence. Thirteen fixtures in the corpus hold a response a real Node
//  server gave, on routes the replay never touches, and nothing said which of them were
//  compared and which were merely sitting there. Two were not, and both had drifted:
//  `POST /chat/new` answered with one key against the reference's twelve, and
//  `PUT /chat/:guid` answered `data: null`.
//
//  This is the ratchet that makes the gap countable. It does not compare anything itself —
//  the three suites named below do that, each building its own subject — it asserts that
//  every fixture which SHOULD be compared is claimed by one of them. A new deny-listed route
//  with a recorded payload fails here until someone either diffs it or writes down why not.
//
//  Two filters decide what is in scope, and both matter:
//
//    - DENY-LISTED only. Everything else is replayed by `FixtureReplayTests` on every build,
//      which is a stronger check than a key-set diff.
//    - NODE-RECORDED only. A fixture this server produced is not a contract; diffing it
//      compares the candidate with a photograph of the candidate. `CorpusProvenanceTests`
//      owns the separate problem of v1 routes that have no reference recording at all.

import BBParity
import Foundation
import Testing

@Suite("Deny-listed fixtures are shape-checked")
struct DenyListedShapeCoverageTests {

  /// Fixture file name to the suite that diffs its response against ours.
  ///
  /// Keyed by FILE NAME rather than by route: a recorded path carries the concrete chat GUID
  /// or message GUID it was recorded against (`put_api_v1_chat_any;+;49d0b6…`), so there is
  /// no route string to key on that the corpus and this table would spell the same way.
  ///
  /// **This table may only shrink or be corrected, never grow to silence a failure.** An
  /// entry is a claim that a named suite compares that fixture; if it does not, the claim is
  /// false and the check below is worth nothing.
  static let comparedBy: [String: String] = [
    // The eight message-bearing sends, one parameterised test over a table.
    "post_api_v1_message_text-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_text-5baa61-200-apple-script.json": "SendShapeTests",
    "post_api_v1_message_multipart-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_attachment-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_attachment_chunk-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_react-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_:id_edit-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_:id_unsend-5baa61-200.json": "SendShapeTests",
    "post_api_v1_message_:id_notify-5baa61-200.json": "SendShapeTests",

    // The two chat writes.
    "post_api_v1_chat_new-5baa61-200.json": "ChatWriteShapeTests",
    "put_api_v1_chat_any;+;49d0b618798a414c9a74291223a99b6e-5baa61-200.json":
      "ChatWriteShapeTests",

    // The two scheduled-message writes.
    "post_api_v1_message_schedule-5baa61-200.json": "ScheduleWriteShapeTests",
    "put_api_v1_message_schedule_:id-5baa61-200.json": "ScheduleWriteShapeTests",
  ]

  @Test("Every deny-listed fixture recording a reference payload is claimed by a suite")
  func everyRecordedPayloadIsCompared() throws {
    let inScope = try Self.inScope()

    // A FLOOR. A scan that finds nothing passes while looking exactly like full coverage,
    // which is the failure this whole file exists to stop happening again.
    #expect(
      inScope.count >= 13,
      Comment(
        rawValue: "found \(inScope.count) deny-listed fixtures with a reference payload; "
          + "the scan is not reading the corpus"))

    let unclaimed = inScope.map(\.name).filter { Self.comparedBy[$0] == nil }.sorted()
    #expect(
      unclaimed.isEmpty,
      Comment(
        rawValue: """
          These fixtures record what a real Node server answered on a route the replay \
          harness never touches, and nothing diffs them against what we answer. Add a shape \
          test in the shape of `SendShapeTests` and name it in `comparedBy`:
            \(unclaimed.joined(separator: "\n  "))
          """))
  }

  /// The other direction: a claim that names a fixture the corpus no longer has.
  ///
  /// Without this the table rots into a list of suites covering files that were renamed or
  /// re-recorded, which reads as coverage and is not.
  @Test("Every claim names a fixture that is still in scope")
  func everyClaimIsLive() throws {
    let inScope = Set(try Self.inScope().map(\.name))
    let stale = Self.comparedBy.keys.filter { !inScope.contains($0) }.sorted()
    #expect(
      stale.isEmpty,
      Comment(
        rawValue: "claimed as compared, but no longer a deny-listed fixture with a "
          + "reference payload:\n  " + stale.joined(separator: "\n  ")))
  }

  // MARK: - Reading the corpus

  /// Deny-listed, Node-recorded, and carrying a non-empty `data`.
  ///
  /// `FixtureReplay.isDestructive` rather than a second copy of the deny list: one
  /// implementation, and it is the one that RUNS. A rule restated in a test drifts from the
  /// rule the driver applies, and then this measures the wrong set.
  static func inScope() throws -> [RecordedFixture] {
    let corpus = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/http")
    let files = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
      .filter { $0.hasSuffix(".json") }
    #expect(files.count > 100, "the corpus scan found \(files.count) files")

    var results: [RecordedFixture] = []
    for name in files.sorted() {
      let fixture = try RecordedFixture.load(from: corpus.appendingPathComponent(name))
      guard FixtureReplay.isDestructive(fixture) else { continue }
      guard fixture.recordedFrom == .node else { continue }
      guard let data = fixture.response.body.jsonObject?["data"] else { continue }
      if let object = data as? [String: Any], !object.isEmpty {
        results.append(fixture)
      } else if let array = data as? [Any], !array.isEmpty {
        results.append(fixture)
      }
    }
    return results
  }
}

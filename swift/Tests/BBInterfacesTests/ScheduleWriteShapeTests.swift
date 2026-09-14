//  ScheduleWriteShapeTests
//  The two scheduled-message write responses, diffed against the recorded reference.
//
//  The last two deny-listed fixtures carrying a Node-recorded payload that nothing compared.
//  `SendShapeTests` covers the eight message sends and `ChatWriteShapeTests` the two chat
//  writes; `DenyListedShapeCoverageTests` is the ratchet that says so and fails if a
//  thirteenth appears.
//
//  Both routes return `ScheduledMessage.json`, so one subject serves both and the test is
//  about what the reference asked for rather than about two code paths. That is also the
//  finding: the reference's PUT answers with FIVE keys where its POST answers with nine, and
//  ours answers with nine either way. A superset is tolerable — clients ignore what they do
//  not know — but an undeclared one is drift, so the four extras are named below with the
//  reason they are kept.

import BBParity
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Scheduled message write response shape")
struct ScheduleWriteShapeTests {

  /// A one-shot send-message row, in the shape the recorded fixture's row was in.
  static func record() throws -> ScheduledMessage {
    ScheduledMessage(
      id: 4,
      type: "send-message",
      payload: Data(
        #"{"chatGuid":"any;-;person@example.com","message":"Fixture","method":"apple-script"}"#
          .utf8),
      scheduledFor: Date(timeIntervalSince1970: 1_787_869_718),
      schedule: Data(#"{"type":"once"}"#.utf8),
      status: "pending",
      error: nil,
      sentAt: nil,
      createdAt: Date(timeIntervalSince1970: 1_787_869_700)
    )
  }

  @Test("A created scheduled message carries every field the reference sends")
  func createMatchesTheRecordedResponse() throws {
    let expected = try Self.recordedData("post_api_v1_message_schedule-5baa61-200.json")
    let ours = try Self.record().json.objectKeys
    let theirs = Set(expected.keys)

    // Stated so the comparison cannot pass by diffing two empty sets.
    #expect(theirs.count == 9)
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference sends on POST /message/schedule and we do not")
    #expect(
      ours.subtracting(theirs).sorted() == [],
      "fields we add to POST /message/schedule")
  }

  /// The reference's update answers with a SUBSET of what its create answers with.
  ///
  /// Five keys against nine: `status`, `error`, `sentAt` and `created` are absent. That is
  /// not a shape we reproduce, and deliberately: its create and its update return different
  /// objects (the stored entity one way, the request echoed back the other), where both of
  /// ours return the stored row. Answering with the row is the more useful of the two and is
  /// safe in the direction that matters — a client reads the five it knows and ignores the
  /// rest — so the extras are declared here rather than dropped.
  static let updateAdditions: Set<String> = ["status", "error", "sentAt", "created"]

  @Test("An updated scheduled message carries every field the reference sends")
  func updateMatchesTheRecordedResponse() throws {
    let expected = try Self.recordedData("put_api_v1_message_schedule_:id-5baa61-200.json")
    let ours = try Self.record().json.objectKeys
    let theirs = Set(expected.keys)

    #expect(theirs.count == 5)

    // THE REQUIREMENT, and it is the same one on every route: a field the reference sends
    // and we do not is the break.
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference sends on PUT /message/schedule/:id and we do not")

    // The drift half, held to the declared list so an addition nobody chose still fails.
    #expect(
      ours.subtracting(theirs).subtracting(Self.updateAdditions).sorted() == [],
      "fields we add to PUT /message/schedule/:id that are not declared above")

    // And the declaration has to stay true: an addition that quietly stopped being sent
    // would leave a stale entry here claiming a difference that no longer exists.
    #expect(
      Self.updateAdditions.subtracting(ours).sorted() == [],
      "declared as an addition and no longer sent")
  }

  // MARK: - Reading the corpus

  static func recordedData(_ fixture: String) throws -> [String: Any] {
    let corpus = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/http")
    let recorded = try RecordedFixture.load(from: corpus.appendingPathComponent(fixture))
    return try #require(recorded.response.body.jsonObject?["data"] as? [String: Any])
  }
}

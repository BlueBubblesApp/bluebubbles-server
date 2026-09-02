//  SendShapeTests
//  The send response, diffed against the recorded reference response.
//
//  The parity replay cannot reach this route — sends are deny-listed, because the harness
//  drives a real server — so the fixture is compared here instead, by serialising a real row
//  through the same path the handler uses and diffing the KEY SET against the recording.
//  Values cannot match (different Mac, different message); the shape is the contract.

import BBIMessage
import BBParity
import BBPersistence
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Send response shape")
struct SendShapeTests {

  /// Every route that answers with a message, against the response the reference gave.
  ///
  /// One test over a table rather than seven copies: the shape is decided in one place
  /// (`MessageInterface.serialize`), so seven assertions of the same thing would drift into
  /// six that are checked and one that is not.
  ///
  /// `tempGuid` is the only difference between them. The reference echoes it on `text` and
  /// `multipart` — the two routes whose recorded requests carried one — and on nothing else,
  /// which is why it is per-row here rather than passed everywhere.
  @Test(
    "Each message-bearing route carries every field the reference sends",
    arguments: [
      ("post_api_v1_message_text-5baa61-200.json", "fixture-58F98003-54B8-4D3F-AB0D-88F7B4B2F03C"),
      ("post_api_v1_message_multipart-5baa61-200.json", "fixture-multipart"),
      ("post_api_v1_message_attachment-5baa61-200.json", nil),
      ("post_api_v1_message_attachment_chunk-5baa61-200.json", nil),
      ("post_api_v1_message_react-5baa61-200.json", nil),
      ("post_api_v1_message_:id_edit-5baa61-200.json", nil),
      ("post_api_v1_message_:id_unsend-5baa61-200.json", nil),
      ("post_api_v1_message_:id_notify-5baa61-200.json", nil),
    ] as [(String, String?)]
  )
  func matchesTheRecordedResponse(fixture: String, tempGUID: String?) async throws {
    let recorded = try RecordedFixture.load(
      from: Self.corpus.appendingPathComponent(fixture)
    )
    let expected = try #require(recorded.response.body.jsonObject?["data"] as? [String: Any])

    let interface = try await Self.interface()
    let hydrated = try #require(
      try await interface.awaitSentMessage(guid: "11111111-0000-0000-0000-000000000007")
    )
    let actual = interface.serialize(
      MessageInterface.SendOutcome(backend: .privateAPI, message: hydrated),
      tempGUID: tempGUID
    )

    let ours = Set(actual.objectKeys ?? [])
    let theirs = Set(expected.keys)

    // Stated so the comparison cannot pass by comparing two empty sets, which is exactly
    // how a shape test rots into a no-op. 51 keys, or 52 with the echoed `tempGuid`.
    #expect(theirs.count == (tempGUID == nil ? 51 : 52))

    // THE REQUIREMENT. Every field the reference sends must be here; a client reads it and
    // finding it absent is the break. Nothing may silence this half.
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "\(fixture): fields the reference sends and we do not"
    )

    // The other half is a drift check, not the requirement — an extra field of ours is
    // tolerable, and `acceptedDifferences` is where a deliberate one is declared. Held to
    // that list so an addition nobody chose still shows up here.
    #expect(
      ours.subtracting(theirs).subtracting(acceptedDifferences.keys).sorted() == [],
      "\(fixture): fields we add that are not declared in acceptedDifferences"
    )
  }

  static let corpus = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/http")

  static func interface() async throws -> MessageInterface {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-send-shape-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile)
    )
  }
}

//  ChatWriteShapeTests
//  The two chat-write responses, diffed against the recorded reference responses.
//
//  `SendShapeTests` in the shape it established, and for the same reason: the parity replay
//  deny-lists everything under `/api/v1/chat/` as a send, so the recorded Node responses for
//  `POST /chat/new` and `PUT /chat/:guid` sit in the corpus and are never compared. Both
//  routes had drifted all the way to a one-key object and a `null` while every check stayed
//  green — `POST /chat/new` answered `{"guid": …}` against the reference's twelve keys, and
//  `PUT /chat/:guid` answered `data: null`. Nothing in the suite could see it.
//
//  Values cannot match (a different Mac, a different chat); the KEY SET is the contract.
//  `messages` is asserted element-deep rather than by presence, because the empty array was
//  the whole defect on the create route: the key existed, the type was right, and the message
//  the client had just sent was not in it.

import BBIMessage
import BBParity
import BBPersistence
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Chat write response shape")
struct ChatWriteShapeTests {

  /// The fixture database's group chat: style 43, a display name, two participants — the
  /// shape a create answers with. Its `…0007` message is `is_from_me`, so it stands in for
  /// the message a create just sent.
  static let groupChatGUID = "iMessage;+;chat000000000000000001"
  static let sentMessageGUID = "11111111-0000-0000-0000-000000000007"

  // MARK: - POST /api/v1/chat/new

  @Test("A created chat carries every field the reference sends")
  func createMatchesTheRecordedResponse() async throws {
    let recorded = try RecordedFixture.load(
      from: Self.corpus.appendingPathComponent("post_api_v1_chat_new-5baa61-200.json"))
    let expected = try #require(recorded.response.body.jsonObject?["data"] as? [String: Any])

    let actual = try await Self.serializedCreate(tempGUID: "fixture-group-1")
    let ours = actual.objectKeys
    let theirs = Set(expected.keys)

    // Stated so the comparison cannot pass by diffing two empty sets, which is how a shape
    // test rots into a no-op.
    #expect(theirs.count == 12)

    // THE REQUIREMENT. Every field the reference sends has to be here; a client reads it
    // and finding it absent is the break. Nothing may silence this half.
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference sends on POST /chat/new and we do not")

    // A drift check rather than the requirement: an extra field is tolerable, and a
    // deliberate one is declared in `acceptedDifferences`.
    #expect(
      ours.subtracting(theirs).subtracting(acceptedFieldNames).sorted() == [],
      "fields we add to POST /chat/new that are not declared in acceptedDifferences")
  }

  /// The half that the top-level key set cannot see.
  ///
  /// `messages` was present and EMPTY, so a key-set diff would have passed it. The reference
  /// puts the message the create sent in there (`chat.messages = [sentMessage]` on both of
  /// its backends) and the router writes the client's `tempGuid` onto it, which is how a
  /// client matches the bubble it drew optimistically to the row Messages wrote.
  @Test("The created chat carries the message it sent, with tempGuid echoed onto it")
  func createCarriesTheSentMessage() async throws {
    let recorded = try RecordedFixture.load(
      from: Self.corpus.appendingPathComponent("post_api_v1_chat_new-5baa61-200.json"))
    let data = try #require(recorded.response.body.jsonObject?["data"] as? [String: Any])
    let theirMessages = try #require(data["messages"] as? [[String: Any]])
    let theirs = Set(try #require(theirMessages.first).keys)

    let actual = try await Self.serializedCreate(tempGUID: "fixture-group-1")
    let ourMessages = try #require(actual["messages"]?.arrayValue)
    #expect(ourMessages.count == 1, "the message the create sent is not in `messages`")
    let ours = try #require(ourMessages.first).objectKeys

    // 50 message fields plus the echoed `tempGuid`. One fewer than the 51 a send answers
    // with, because a message nested in a chat omits `chats`.
    #expect(theirs.count == 51)
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference's nested message carries and ours does not")
    #expect(
      ourMessages.first?["tempGuid"] == .string("fixture-group-1"),
      "the client's tempGuid is not echoed onto the message")

    // `chats` is the one key the nested message must NOT have: the reference's
    // `ChatSerializer` overrides `includeChats: false` for a message inside a chat, and
    // emitting it would nest a chat inside the chat that contains it.
    #expect(!ours.contains("chats"))
  }

  @Test("A create with no tempGuid omits the key rather than sending null")
  func createWithoutTempGUID() async throws {
    let actual = try await Self.serializedCreate(tempGUID: nil)
    let message = try #require(actual["messages"]?.arrayValue?.first)
    #expect(!message.objectKeys.contains("tempGuid"))
  }

  // MARK: - PUT /api/v1/chat/:guid

  @Test("An updated chat carries every field the reference sends")
  func updateMatchesTheRecordedResponse() async throws {
    let recorded = try RecordedFixture.load(
      from: Self.corpus.appendingPathComponent(
        "put_api_v1_chat_any;+;49d0b618798a414c9a74291223a99b6e-5baa61-200.json"))
    let expected = try #require(recorded.response.body.jsonObject?["data"] as? [String: Any])

    let chat = try await Self.chatInterface()
    let projection = try #require(
      try await chat.find(
        guid: Self.groupChatGUID, query: ChatInterface.Query(withParticipants: true)))
    let actual = chat.serialize(projection)

    let ours = actual.objectKeys
    let theirs = Set(expected.keys)

    #expect(theirs.count == 11)
    #expect(
      theirs.subtracting(ours).sorted() == [],
      "fields the reference sends on PUT /chat/:guid and we do not")
    #expect(
      ours.subtracting(theirs).subtracting(acceptedFieldNames).sorted() == [],
      "fields we add to PUT /chat/:guid that are not declared in acceptedDifferences")

    // NOT `messages`. The update route serializes with `DEFAULT_CHAT_CONFIG`, whose
    // `includeMessages` is false, so the key is absent entirely — the third of the three
    // states `ChatSerializer`'s `messages:` parameter has to be able to express.
    #expect(!ours.contains("messages"))
  }

  // MARK: - Reading the tree

  static let corpus = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/http")

  /// The create response, built through the same call the handler makes.
  static func serializedCreate(tempGUID: String?) async throws -> JSONValue {
    let chat = try await chatInterface()
    let projection = try #require(
      try await chat.find(
        guid: groupChatGUID, query: ChatInterface.Query(withParticipants: true)))
    let sent = try #require(
      try await messageInterface().awaitSentMessage(guid: sentMessageGUID))
    #expect(!projection.participants.isEmpty, "the fixture chat lost its participants")

    return chat.serialize(
      ChatInterface.CreatedChat(projection: projection, firstMessage: sent),
      tempGUID: tempGUID)
  }

  static func repository() async throws -> (MessageRepository, MessageSerializer) {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-chat-write-shape-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return (
      MessageRepository(database: database, profile: profile),
      MessageSerializer(profile: profile)
    )
  }

  static func chatInterface() async throws -> ChatInterface {
    let (repository, serializer) = try await Self.repository()
    return ChatInterface(repository: repository, serializer: serializer)
  }

  static func messageInterface() async throws -> MessageInterface {
    let (repository, serializer) = try await Self.repository()
    return MessageInterface(repository: repository, serializer: serializer)
  }
}

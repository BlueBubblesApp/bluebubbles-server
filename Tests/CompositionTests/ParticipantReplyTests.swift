//  ParticipantReplyTests
//  What `POST/DELETE /chat/:guid/participant` (and `…/participant/{add,remove}`) answer.
//
//  The reference answers with the chat, serialized with its participants: `toggleParticipant`
//  reads it `withParticipants: true` and sends `ChatSerializer.serialize({ chat })` as `data`
//  (`routers/chatRouter.ts:257-270`). This server answered `data: null`, which is a v1 field
//  MISSING (root guide, rule 1): a client reading the new roster out of the reply found
//  nothing. Asserted through the handler, with a helper that lets the change through and the
//  committed fixture database behind it.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBContacts
import BBCore
import BBHTTPAPI
import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBHandlers
@testable import BBInterfaces

@Suite("Participant routes answer with the chat", .removingChatDBCopies)
struct ParticipantReplyTests {

  private static let guid = "iMessage;-;+12025550143"

  private struct Host: InterfaceProviding {
    let built: ServerInterfaces
    func interfaces() async -> ServerInterfaces? { built }
    func requireInterfaces() async throws -> ServerInterfaces { built }
  }

  private func host() async throws -> Host {
    let path = try CommittedChatDB.copy()
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let serializer = MessageSerializer(profile: profile)

    var helper = FailingPrivateAPI()
    helper.succeeding = [.addParticipant, .removeParticipant]

    let appDatabase = AppDatabase(queue: try DatabaseQueue())
    try appDatabase.migrate(contributors: [ContactsSchema.self])
    return Host(
      built: ServerInterfaces(
        message: MessageInterface(repository: repository, serializer: serializer),
        chat: ChatInterface(repository: repository, serializer: serializer, privateAPI: helper),
        handle: HandleInterface(repository: repository),
        attachment: AttachmentInterface(repository: repository),
        contact: ContactInterface(index: ContactIndex(database: appDatabase))
      ))
  }

  private func request() throws -> APIRequestContext {
    APIRequestContext(
      method: .post, path: "/api/v1/chat/\(Self.guid)/participant",
      pathParameters: ["guid": Self.guid],
      headers: ["content-type": "application/json"],
      body: try JSONValue.object(["address": .string("someone@example.com")]).serialize())
  }

  @Test(
    "Adding and removing both answer with the serialized chat and its participants",
    arguments: [true, false])
  func answersWithTheChat(adding: Bool) async throws {
    let result = try await WriteHandlers.participant(
      try request(), context: try await host(), adding: adding)

    guard case .data(let data?, _, _) = result else {
      Issue.record("expected the chat as `data`, got \(result)")
      return
    }
    #expect(data["guid"]?.stringValue.map { ChatGUID.sameChat($0, Self.guid) } == true)
    let participants = try #require(data["participants"]?.arrayValue)
    #expect(!participants.isEmpty, "the chat is serialized with its participants")
  }
}

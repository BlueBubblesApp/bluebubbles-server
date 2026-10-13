//  PrivateAPIChatCreationTests
//  A Private API create resolves to the chat the helper named, and to the message it sent.
//
//  Over a real `chat.db`, because the bug was in the lookup: the helper's chat GUID was used
//  to look for a MESSAGE, so the wait could never succeed, and `POST /chat/new` failed after
//  thirty seconds on every server with the helper connected.

import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Private API chat creation", .removingChatDBCopies)
struct PrivateAPIChatCreationTests {

  /// The group chat in the committed fixture, and a message the account sent into it.
  private static let fixtureChat = "iMessage;+;chat000000000000000001"
  private static let fixtureMessage = "11111111-0000-0000-0000-000000000007"

  private func interface(answering created: NewChat) async throws -> ChatInterface {
    let path = try CommittedChatDB.copy()
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    var helper = FailingPrivateAPI(error: PrivateAPIError.rejectedByMessages(reason: "unused"))
    helper.onCreateChat = { _, _ in created }
    return ChatInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile),
      privateAPI: helper
    )
  }

  /// Both spellings: a constructed legacy prefix, and the `any` macOS 26 writes everywhere.
  @Test(
    "The chat the helper names is the chat answered, with the message it sent",
    arguments: [fixtureChat, "any;+;chat000000000000000001"])
  func resolvesTheNamedChat(_ named: String) async throws {
    let chat = try await interface(
      answering: NewChat(
        chat: ChatIdentifier(named), firstMessage: MessageGUID(Self.fixtureMessage)))

    let clock = ContinuousClock()
    let started = clock.now
    let created = try await chat.create(
      addresses: ["someone@example.com", "else@example.com"], message: "BB test")

    #expect(created.guid == Self.fixtureChat)
    #expect(created.firstMessage?.row.guid == Self.fixtureMessage)
    // Found on the first look, not after a wait that happened to give up gracefully.
    #expect(clock.now - started < .seconds(5))
  }

  @Test("A create with no first message answers the chat alone")
  func resolvesWithoutAMessage() async throws {
    let chat = try await interface(
      answering: NewChat(chat: ChatIdentifier(Self.fixtureChat), firstMessage: nil))
    let created = try await chat.create(addresses: ["someone@example.com"], message: nil)
    #expect(created.guid == Self.fixtureChat)
    #expect(created.firstMessage == nil)
  }
}

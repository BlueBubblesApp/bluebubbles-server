//  CreateChatWireTests
//  What a create-chat reply names, as the server reads it.
//
//  The helper answers with the CHAT's GUID and, when it sent one, the first message's. The
//  server once read the answer as a message GUID and waited thirty seconds for a row that
//  never comes, failing every Private API create after Messages had already sent.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("Create chat on the wire")
struct CreateChatWireTests {

  private static let chat = "any;+;chat000000000000000001"
  private static let message = "11111111-0000-0000-0000-000000000007"

  @Test("The chat and the first message are read from their own fields")
  func readsBothIdentifiers() async throws {
    let transport = StubHelperTransport(replies: [
      MessagesHelperAction.createChat.rawValue: .object([
        "chatGuid": .string(Self.chat), "messageGuid": .string(Self.message),
      ])
    ])
    let created = try await PrivateAPIClient(transport: transport).createChat(
      addresses: ["someone@example.com"], service: "iMessage", message: "BB test")
    #expect(
      created == NewChat(chat: ChatIdentifier(Self.chat), firstMessage: MessageGUID(Self.message)))
  }

  @Test("A create that sent nothing names no message")
  func noFirstMessage() async throws {
    let transport = StubHelperTransport(replies: [
      MessagesHelperAction.createChat.rawValue: .object(["chatGuid": .string(Self.chat)])
    ])
    let created = try await PrivateAPIClient(transport: transport).createChat(
      addresses: ["someone@example.com"], service: "iMessage", message: nil)
    #expect(created == NewChat(chat: ChatIdentifier(Self.chat), firstMessage: nil))
  }

  /// A helper injected before the fields were named answered `identifier`, and it was the
  /// chat's GUID there too. Read as the chat, never as a message.
  @Test("An earlier helper's `identifier` is the chat")
  func legacyIdentifierIsTheChat() async throws {
    let transport = StubHelperTransport(replies: [
      MessagesHelperAction.createChat.rawValue: .object(["identifier": .string(Self.chat)])
    ])
    let created = try await PrivateAPIClient(transport: transport).createChat(
      addresses: ["someone@example.com"], service: "iMessage", message: "BB test")
    #expect(created.chat == ChatIdentifier(Self.chat))
    #expect(created.firstMessage == nil)
  }

  @Test("A reply with no chat GUID is refused")
  func refusesMissingChat() async throws {
    let transport = StubHelperTransport(replies: [
      MessagesHelperAction.createChat.rawValue: .object(["messageGuid": .string(Self.message)])
    ])
    await #expect(throws: PrivateAPIError.self) {
      _ = try await PrivateAPIClient(transport: transport).createChat(
        addresses: ["someone@example.com"], service: "iMessage", message: "BB test")
    }
  }
}

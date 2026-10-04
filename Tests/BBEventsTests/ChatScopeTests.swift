//  ChatScopeTests
//  Reading an event's conversation, and narrowing a webhook to chosen ones.
//
//  Both halves fail silently. An event in `EventName.chatScoped` whose payload the reader
//  looks in the wrong place for has no chat, so a filtered webhook withholds it forever; and a
//  match on the GUID's spelling rather than on the chat stops delivering a conversation the
//  day macOS 26 rewrites its prefix to `any`. Neither shows up anywhere but here.
//
//  The payloads are built in the shape each emitter builds; `ChatScopeEmitterTests` in
//  CompositionTests runs the emitters that can be run without a database.

import BBSerialization
import Foundation
import Testing

@testable import BBEvents

@Suite("Chat scope")
struct ChatScopeTests {

  private static let direct = "iMessage;-;+12025550143"
  private static let migrated = "any;-;+12025550143"
  private static let other = "iMessage;-;someone@example.com"
  private static let group = "iMessage;+;chat100000000000000001"

  /// A serialized message as `.full` renders one: the conversation is in `chats`.
  private static func message(_ name: EventName, chats: [String]) -> ServerEvent {
    ServerEvent(
      name: name,
      fullPayload: .object([
        "guid": .string("message-guid"),
        "chats": .array(chats.map { .object(["guid": .string($0)]) }),
      ]),
      // Deliberately chat-less, as `.notificationUpdate` renders an update: the reader must
      // not depend on the projection a webhook is sent.
      notificationPayload: .object(["guid": .string("message-guid")])
    )
  }

  // MARK: - Reading the chat

  @Test("A message-shaped event names the chats in its full payload")
  func messageShapedEvents() {
    for name in EventName.messageShaped {
      #expect(Self.message(name, chats: [Self.group]).chatGUIDs == [Self.group], "\(name)")
    }
  }

  @Test("Typing, read state and scheduled messages name their chat where they keep it")
  func otherChatEvents() {
    let typing = ServerEvent(
      name: .typingIndicator,
      fullPayload: .object(["guid": .string(Self.direct), "display": .bool(true)]))
    #expect(typing.chatGUIDs == [Self.direct])

    let read = ServerEvent(
      name: .chatReadStatusChanged,
      fullPayload: .object(["chatGuid": .string(Self.direct), "read": .bool(true)]))
    #expect(read.chatGUIDs == [Self.direct])

    for name in [EventName.scheduledMessageError, .scheduledMessageSent] {
      let scheduled = ServerEvent(
        name: name,
        fullPayload: .object([
          "id": .int64(1),
          "payload": .object(["chatGuid": .string(Self.group), "message": .string("hi")]),
        ]))
      #expect(scheduled.chatGUIDs == [Self.group], "\(name)")
    }
  }

  /// Every chat-scoped event has a reading. An event added to the set and not to the reader
  /// falls through to the scheduled-message case and finds nothing, which this catches.
  @Test("Every chat-scoped event is covered by a test payload above")
  func everyChatScopedEventIsCovered() {
    let covered = EventName.messageShaped.union([
      .typingIndicator, .chatReadStatusChanged, .scheduledMessageError, .scheduledMessageSent,
    ])
    #expect(EventName.chatScoped == covered)
  }

  @Test("An event that is not about a chat has no chat, rather than an empty list")
  func nonChatEvents() {
    for name in EventName.webhookSubscribable where !EventName.chatScoped.contains(name) {
      #expect(ServerEvent(name: name, fullPayload: .object([:])).chatGUIDs == nil, "\(name)")
    }
  }

  @Test("A chat event whose chat cannot be read has an empty list, not nil")
  func unreadableChat() {
    #expect(Self.message(.newMessage, chats: []).chatGUIDs == [])
    #expect(ServerEvent(name: .typingIndicator, fullPayload: .null).chatGUIDs == [])
  }

  // MARK: - Admitting

  @Test("Every conversation admits every event")
  func allChatsAdmitsEverything() {
    #expect(ChatScope.allChats.admits(Self.message(.newMessage, chats: [Self.other])))
    #expect(ChatScope.allChats.admits(Self.message(.newMessage, chats: [])))
  }

  @Test("A chosen chat is admitted and any other is not")
  func onlyChosenChats() {
    let scope = ChatScope.only([Self.direct, Self.group])
    #expect(scope.admits(Self.message(.newMessage, chats: [Self.direct])))
    #expect(scope.admits(Self.message(.updatedMessage, chats: [Self.group])))
    #expect(!scope.admits(Self.message(.newMessage, chats: [Self.other])))
  }

  /// A filter saved before a macOS 26 upgrade, and the events that arrive after it.
  @Test("The service prefix does not decide the match")
  func comparedOnTheChat() {
    #expect(ChatScope.only([Self.direct]).admits(Self.message(.newMessage, chats: [Self.migrated])))
    #expect(ChatScope.only([Self.migrated]).admits(Self.message(.newMessage, chats: [Self.direct])))
  }

  @Test("An event that is not about a chat passes any chat filter")
  func nonChatEventsPass() {
    let update = ServerEvent(name: .serverUpdate, fullPayload: .string("1.2.3"))
    #expect(ChatScope.only([Self.direct]).admits(update))
    #expect(ChatScope.only([]).admits(update))
  }

  @Test("A chat event whose chat cannot be read is withheld from a filtered endpoint")
  func unreadableChatIsWithheld() {
    #expect(!ChatScope.only([Self.direct]).admits(Self.message(.newMessage, chats: [])))
  }

  @Test("An empty filter withholds every chat event")
  func emptyFilter() {
    #expect(!ChatScope.only([]).admits(Self.message(.newMessage, chats: [Self.direct])))
  }
}

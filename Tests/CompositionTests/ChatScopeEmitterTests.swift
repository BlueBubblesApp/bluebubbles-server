//  ChatScopeEmitterTests
//  That `ServerEvent.chatGUIDs` finds the chat in what the emitters actually build.
//
//  `ChatScopeTests` in BBEventsTests reads payloads written in each emitter's shape. This
//  runs the emitters that can be run without a database, so a payload key renamed at the
//  emitter fails here rather than leaving every chat-filtered webhook without that event.

import BBAppStore
import BBEvents
import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Chat scope at the emitters")
struct ChatScopeEmitterTests {

  @Test("A typing indicator from the helper names its chat")
  func typingIndicator() throws {
    let chat = "any;-;+12025550143"
    let mapped = try #require(
      PrivateAPIGatedService.serverEvent(
        for: .typingChanged(chat: ChatIdentifier(chat), isTyping: true)))
    #expect(mapped.event.name == .typingIndicator)
    #expect(mapped.event.chatGUIDs == [chat])
  }

  @Test("A scheduled message's outcome names the chat it was sent to")
  func scheduledMessageOutcome() {
    let chat = "iMessage;+;chat100000000000000001"
    let record = ScheduledMessage(
      id: 1,
      type: "send-message",
      payload: Data(#"{"chatGuid":"iMessage;+;chat100000000000000001","message":"hi"}"#.utf8),
      scheduledFor: Date(timeIntervalSince1970: 1_756_567_000),
      schedule: nil,
      status: "error",
      error: "refused",
      sentAt: nil,
      createdAt: Date(timeIntervalSince1970: 1_756_567_000)
    )
    // The expression `ScheduledMessageService` emits.
    let event = ServerEvent(
      name: .scheduledMessageError, fullPayload: record.json,
      notificationPayload: record.json)
    #expect(event.chatGUIDs == [chat])
  }
}

//  TypingEventProjectionTests
//  A typing event names its chat by GUID, whatever shape the listener handed the chat in.
//
//  The daemon listener's `chat:` argument is a string in some call shapes and an `IMChat` in
//  others, and the string can be the chat IDENTIFIER (an address, or a `chat…` id) rather
//  than its GUID. The event's field is `chatGuid`, and a client matches it against the GUIDs
//  it holds, so an identifier there names no chat and the indicator never shows. These pin
//  the projection: a string is resolved, an `IMChat` answers its own `guid`, and anything
//  that resolves to nothing is dropped rather than forwarded as it arrived.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesHelper

/// An `IMMessageItem` stand-in carrying the typing flags the classifier reads.
@objc final class StandInTypingItem: NSObject {
  @objc var isTypingMessage: Bool
  @objc var isCancelTypingMessage: Bool
  @objc var isFromMe: Bool
  init(typing: Bool = true, cancel: Bool = false, fromMe: Bool = false) {
    isTypingMessage = typing
    isCancelTypingMessage = cancel
    isFromMe = fromMe
  }
}

/// An `IMChat` stand-in that answers `guid`.
@objc final class StandInChatWithGUID: NSObject {
  @objc let guid: String
  @objc let chatIdentifier: String
  init(guid: String, chatIdentifier: String) {
    self.guid = guid
    self.chatIdentifier = chatIdentifier
  }
}

/// A chat object that offers only its identifier.
@objc final class StandInChatWithIdentifierOnly: NSObject {
  @objc let chatIdentifier: String
  init(chatIdentifier: String) { self.chatIdentifier = chatIdentifier }
}

@Suite("Typing event projection")
struct TypingEventProjectionTests {

  private static let identifier = "+12025550143"
  private static let guid = "any;-;+12025550143"

  /// The registry, as a table: the identifier resolves to the chat's GUID, and so does the
  /// GUID itself, which is what `existingChatWithGUID:` answers.
  private static func registry(_ value: String) -> String? {
    [identifier: guid, guid: guid][value]
  }

  private func event(chat: Any?, item: Any? = StandInTypingItem()) -> ObservedEvent? {
    DaemonEventHandler.typingEvent(item: item, chat: chat, resolving: Self.registry)
  }

  @Test("A chat identifier string is resolved to the chat's GUID")
  func identifierStringIsResolved() {
    let projected = event(chat: Self.identifier)
    #expect(projected == ObservedEvent(name: .startedTyping, payload: [.chatGuid: Self.guid]))
  }

  @Test("A string that resolves to no chat is dropped, not forwarded as it arrived")
  func unresolvedStringIsDropped() {
    #expect(event(chat: "chat000000000000000001") == nil)
    #expect(event(chat: "") == nil)
  }

  @Test("An IMChat answers its own GUID, never its identifier")
  func chatObjectAnswersGUID() {
    let chat = StandInChatWithGUID(guid: Self.guid, chatIdentifier: Self.identifier)
    #expect(event(chat: chat)?.payload[.chatGuid] == Self.guid)
  }

  @Test("A chat object offering only its identifier is resolved like a string")
  func identifierOnlyObjectIsResolved() {
    let resolvable = StandInChatWithIdentifierOnly(chatIdentifier: Self.identifier)
    #expect(event(chat: resolvable)?.payload[.chatGuid] == Self.guid)

    let unknown = StandInChatWithIdentifierOnly(chatIdentifier: "chat000000000000000001")
    #expect(event(chat: unknown) == nil)
  }

  @Test("Every typing event carries a chat GUID")
  func everyEventCarriesAGUID() {
    let chats: [Any?] = [
      Self.identifier, Self.guid,
      StandInChatWithGUID(guid: Self.guid, chatIdentifier: Self.identifier),
      StandInChatWithIdentifierOnly(chatIdentifier: Self.identifier),
    ]
    let items = [
      StandInTypingItem(typing: true), StandInTypingItem(typing: false, cancel: true),
    ]
    for chat in chats {
      for item in items {
        let projected = event(chat: chat, item: item)
        #expect(projected?.payload == [.chatGuid: Self.guid])
      }
    }
  }

  @Test("Start, stop, ordinary messages and our own typing classify as before")
  func classification() {
    #expect(event(chat: Self.guid, item: StandInTypingItem())?.name == .startedTyping)
    #expect(
      event(chat: Self.guid, item: StandInTypingItem(typing: false, cancel: true))?.name
        == .stoppedTyping)
    #expect(event(chat: Self.guid, item: StandInTypingItem(typing: false)) == nil)
    #expect(event(chat: Self.guid, item: StandInTypingItem(fromMe: true)) == nil)
  }
}

//  TapbackSenderArgumentsTests
//  A tapback's sender is built from the values Messages itself gathers, with the summary from
//  ChatKit's chat item rather than the part's own getter.
//
//  On macOS 27.0.1 the three-argument `IMTapbackSender` initializer raised for every tapback,
//  because it takes the summary from `-[IMMessagePartChatItem messageSummaryInfo]`, which
//  Messages never calls. Messages builds it with `+[IMChat configureMessageSummaryInfoForChatItem:]`
//  from a ChatKit item; `IMTapbacks.messagesArguments` does the same.
//
//  Messages is not here, so the part, the ChatKit item constructor and the summary builder
//  are stand-ins that answer the same selectors with the same type encodings.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BlueBubblesHelper

/// An `IMMessagePartChatItem` stand-in: the three getters Messages reads.
@objc final class StandInMessagePart: NSObject {
  @objc let guid: String?
  @objc let originalMessagePartRange: NSRange
  @objc let threadIdentifierForTapback: String?

  init(guid: String?, range: NSRange, thread: String?) {
    self.guid = guid
    self.originalMessagePartRange = range
    self.threadIdentifierForTapback = thread
  }
}

/// What `+[CKChatItem chatItemWithIMChatItem:balloonMaxWidth:]` answers: an item wrapping
/// the part.
@objc final class StandInChatKitItem: NSObject {
  @objc let wrapped: AnyObject
  let width: Double
  init(wrapping part: AnyObject, width: Double) {
    self.wrapped = part
    self.width = width
  }
}

/// A `CKChatItem` stand-in: the one class method used.
@objc final class StandInChatItemType: NSObject {
  @objc(chatItemWithIMChatItem:balloonMaxWidth:)
  class func chatItem(with part: AnyObject, balloonMaxWidth: Double) -> AnyObject {
    StandInChatKitItem(wrapping: part, width: balloonMaxWidth)
  }
}

/// An `IMChat` stand-in for ChatKit's summary builder. It records what it was handed, so the
/// test can tell a ChatKit item from the bare part.
@objc final class StandInSummaryBuilder: NSObject {
  nonisolated(unsafe) static var handed: AnyObject?

  @objc(configureMessageSummaryInfoForChatItem:)
  class func configure(_ item: AnyObject) -> NSDictionary {
    handed = item
    return ["ams": "a summary"]
  }
}

@Suite("Tapback sender arguments", .serialized)
struct TapbackSenderArgumentsTests {

  @Test("The GUID, range and thread come from the part; the summary from a ChatKit item")
  func gathersWhatMessagesGathers() throws {
    let part = StandInMessagePart(
      guid: "p:0/TARGET-0001", range: NSRange(location: 0, length: 55), thread: "THREAD-0001")
    StandInSummaryBuilder.handed = nil

    let arguments = try IMTapbacks.messagesArguments(
      for: part, chatItemType: StandInChatItemType.self, chatType: StandInSummaryBuilder.self)

    #expect(arguments.guid == "p:0/TARGET-0001")
    #expect(arguments.range == NSRange(location: 0, length: 55))
    #expect(arguments.threadIdentifier == "THREAD-0001")
    #expect((arguments.summary as? NSDictionary)?["ams"] as? String == "a summary")
    // Handed the ChatKit item wrapping the part, never the part itself: the builder branches
    // on ChatKit classes, and the part's own summary getter is what raised on 27.
    let handed = try #require(StandInSummaryBuilder.handed as? StandInChatKitItem)
    #expect(handed.wrapped === part)
  }

  @Test("A part with no thread is sent with none, as a part outside a thread is")
  func noThreadIsNil() throws {
    let part = StandInMessagePart(
      guid: "p:1/TARGET-0002", range: NSRange(location: 3, length: 4), thread: nil)
    let arguments = try IMTapbacks.messagesArguments(
      for: part, chatItemType: StandInChatItemType.self, chatType: StandInSummaryBuilder.self)
    #expect(arguments.threadIdentifier == nil)
    #expect(arguments.range == NSRange(location: 3, length: 4))
  }

  @Test("A part with no GUID is refused before anything is built")
  func missingGUIDIsRefused() {
    let part = StandInMessagePart(guid: nil, range: NSRange(location: 0, length: 1), thread: nil)
    StandInSummaryBuilder.handed = nil
    #expect(throws: (any Error).self) {
      _ = try IMTapbacks.messagesArguments(
        for: part, chatItemType: StandInChatItemType.self, chatType: StandInSummaryBuilder.self)
    }
    #expect(StandInSummaryBuilder.handed == nil)
  }
}

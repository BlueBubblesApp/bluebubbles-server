//  SendCorrelationTests
//  A send answers with the GUID of the message it sent, never the chat's last sent message.
//
//  `-[IMChat sendMessage:]` returns nothing, and `chat.lastSentMessage` read after it is the
//  PREVIOUS message whenever ours has not landed there yet: the client is told its new
//  message has an older one's GUID and reconciles the wrong row. The helper gives every
//  message it builds a GUID at construction and reads it off the object it sent; the one
//  path that cannot (a void `-[IMTapbackSender send]` on 14 and 15) accepts the chat's last
//  sent message only when it is confirmably the new tapback.
//
//  Messages itself is not here, so the IMCore objects are stand-ins that answer the same
//  selectors.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesHelper

/// An `IMMessage` stand-in: the selectors the correlation reads, and nothing else.
@objc final class StandInMessage: NSObject {
  @objc var guid: String?
  @objc var associatedMessageGUID: String?
  init(guid: String?, associatedMessageGUID: String? = nil) {
    self.guid = guid
    self.associatedMessageGUID = associatedMessageGUID
  }
}

/// An `IMChat` stand-in whose `lastSentMessage` is whatever the test says was sent last.
@objc final class StandInChat: NSObject {
  @objc var lastSentMessage: StandInMessage?
}

@Suite("Send correlation")
@MainActor
struct SendCorrelationTests {

  private let chat = ChatIdentifier("any;-;someone@example.com")

  @Test("The reply names the message that was sent, not one the chat sent before it")
  func replyNamesTheSentMessage() throws {
    let ours = StandInMessage(guid: "OURS-0001")
    let sent = try IMCoreBridge().sent([ours], to: chat, assignedGUID: "OURS-0001", sending: "x")
    #expect(sent.guid == MessageGUID("OURS-0001"))
  }

  @Test("A message that will not say its GUID is named by the GUID it was built with")
  func assignedGUIDIsTheFallback() throws {
    let silent = StandInMessage(guid: nil)
    let sent = try IMCoreBridge().sent(
      [silent], to: chat, assignedGUID: "BUILT-0001", sending: "x")
    #expect(sent.guid == MessageGUID("BUILT-0001"))
  }

  @Test("Nothing to correlate is refused rather than answered")
  func nothingIsRefused() {
    // `PrivateAPIErrorShim.rejected`, which the bridge's boundary reports as a refusal.
    #expect(throws: (any Error).self) {
      try IMCoreBridge().sent([nil], to: chat, sending: "reaction")
    }
    #expect(throws: (any Error).self) {
      try IMCoreBridge().sent([StandInMessage(guid: "")], to: chat, sending: "reaction")
    }
  }

  @Test("Each built message gets its own GUID")
  func newGUIDsDiffer() {
    let first = IMMessageBuilder.newGUID()
    let second = IMMessageBuilder.newGUID()
    #expect(first != second)
    #expect(UUID(uuidString: first) != nil)
  }

  @Test("A factory-built message keeps its own GUID, or is given one before the send")
  func factoryMessagesAreGivenAGUID() throws {
    let named = StandInMessage(guid: "FACTORY-0001")
    #expect(try IMMessageBuilder.assignedGUID(of: named) == "FACTORY-0001")

    let unnamed = StandInMessage(guid: nil)
    let given = try IMMessageBuilder.assignedGUID(of: unnamed)
    #expect(!given.isEmpty)
    #expect(unnamed.guid == given, "the GUID was not written onto the message that is sent")
  }

  // MARK: - The void-send tapback path

  private let target = "TARGET-0001"

  @Test("A chat whose last sent message is still the previous one confirms nothing")
  func previousMessageIsNotConfirmed() throws {
    let standIn = StandInChat()
    standIn.lastSentMessage = StandInMessage(
      guid: "PREVIOUS-0001", associatedMessageGUID: "p:0/\(target)")
    let chat = IMChat(standIn)
    let before = try chat.lastSentMessageGUID()
    // The send has not landed: lastSentMessage is unchanged.
    #expect(try chat.sentTapback(since: before, on: target) == nil)
  }

  @Test("The new tapback on the target is confirmed")
  func newTapbackIsConfirmed() throws {
    let standIn = StandInChat()
    standIn.lastSentMessage = StandInMessage(guid: "PREVIOUS-0001")
    let chat = IMChat(standIn)
    let before = try chat.lastSentMessageGUID()
    standIn.lastSentMessage = StandInMessage(
      guid: "TAPBACK-0001", associatedMessageGUID: "p:0/\(target)")
    let confirmed = try #require(try chat.sentTapback(since: before, on: target))
    #expect((confirmed as? StandInMessage)?.guid == "TAPBACK-0001")

    // A balloon part is prefixed `bp:` rather than `p:N/`.
    standIn.lastSentMessage = StandInMessage(
      guid: "TAPBACK-0002", associatedMessageGUID: "bp:\(target)")
    #expect(try chat.sentTapback(since: before, on: target) != nil)
  }

  @Test("A newer message that is not a tapback on the target is not confirmed")
  func unrelatedMessageIsNotConfirmed() throws {
    let standIn = StandInChat()
    let chat = IMChat(standIn)
    standIn.lastSentMessage = StandInMessage(guid: "OTHER-0001")
    #expect(try chat.sentTapback(since: nil, on: target) == nil)
    standIn.lastSentMessage = StandInMessage(
      guid: "OTHER-0002", associatedMessageGUID: "p:0/SOMETHING-ELSE")
    #expect(try chat.sentTapback(since: nil, on: target) == nil)
  }
}

/// The shape the bug had: a send path reading the chat's last sent message.
///
/// `lastSentMessage` is read in exactly two places, both in `IMCoreChats.swift`: the
/// `before` half and the confirmed half of the void-send tapback path. `lastSentMessageGUID`
/// is called only from that path. A send path that reaches for either again is the bug.
@Suite("Send correlation policy")
struct SendCorrelationPolicyTests {

  @Test("No send path answers with the chat's last sent message")
  func noLastSentShortcut() throws {
    let sources = try SourceScanner.swiftFiles(under: "Helper", minimum: 11)
    let readers = SourceScanner.offences(in: sources) { file, line in
      line.code.contains("\"lastSentMessage\"")
        && file.path != "Helper/BlueBubblesHelper/IMCoreChats.swift"
    }
    #expect(
      readers.isEmpty,
      Comment(rawValue: "read the GUID off the message that was sent:\n" + readers.report))

    let callers = SourceScanner.offences(in: sources) { file, line in
      line.code.contains("lastSentMessageGUID()")
        && !line.code.contains("func lastSentMessageGUID")
        && file.path != "Helper/BlueBubblesHelper/IMCoreTapbacks.swift"
    }
    #expect(
      callers.isEmpty,
      Comment(
        rawValue: "`lastSentMessageGUID` is the `before` half of `IMTapbacks.send` only:\n"
          + callers.report))
  }
}

//  LinkScanTests
//  `ddScan` reaches the helper on every send that can carry it, and is refused where none can.
//
//  It is the parameter that was accepted and dropped: the handler read a name no client
//  sends, multipart had no field for it, and the helper parsed it and never used it. Each
//  of those was invisible, because a send without the scan still succeeds. These pin the
//  interface's half: the request the helper is handed carries the flag.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBInterfaces
import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing
import os

@testable import BBInterfaces

/// Records the send it is handed, then refuses it so nothing waits for a chat.db row.
private final class RecordingSender: PrivateAPIConnection, MessageSending, MessageMutation,
  MessageQuerying, ScheduledMessaging, PollControl
{
  private let recorded = OSAllocatedUnfairLock<
    (text: SendMessageRequest?, multipart: SendMultipartRequest?)
  >(initialState: (nil, nil))

  var text: SendMessageRequest? { recorded.withLock { $0.text } }
  var multipart: SendMultipartRequest? { recorded.withLock { $0.multipart } }

  private let refusal = PrivateAPIError.rejectedByMessages(reason: "recorded")

  var isConnected: Bool { get async { true } }
  var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }

  func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage {
    recorded.withLock { $0.text = request }
    throw refusal
  }
  func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    recorded.withLock { $0.multipart = request }
    throw refusal
  }
  func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    throw refusal
  }
  func sendAppMessage(_ request: SendAppMessageRequest) async throws -> SentMessage {
    throw refusal
  }
  func react(_ request: ReactionRequest) async throws -> SentMessage { throw refusal }
  func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage { throw refusal }
  func editMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String,
    backwardCompatibilityText: String
  ) async throws { throw refusal }
  func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int) async throws {
    throw refusal
  }
  func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw refusal
  }
  func notifyAnyways(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw refusal
  }
  func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    throw refusal
  }
  func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String? { throw refusal }
  func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw refusal
  }
  func rescheduleMessage(_ guid: MessageGUID, in chat: ChatIdentifier, to date: Date)
    async throws
  { throw refusal }
  func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws { throw refusal }
  func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw refusal
  }
  func createPoll(_ request: PollCreateRequest) async throws -> SentMessage { throw refusal }
  func votePoll(_ request: PollVoteRequest) async throws -> SentMessage { throw refusal }
  func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage { throw refusal }
}

@Suite("Link scanning")
struct LinkScanTests {

  private let chat = "iMessage;-;+15551234567"

  private func interface(privateAPI: MessageInterface.Helper?) throws -> MessageInterface {
    MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: privateAPI
    )
  }

  @Test("A text send hands the helper the flag it was given", arguments: [true, false])
  func textCarriesTheFlag(_ scan: Bool) async throws {
    let sender = RecordingSender()
    let message = try interface(privateAPI: sender)
    _ = try? await message.sendText(
      MessageInterface.SendTextRequest(
        chatGUID: chat, text: "BB test https://example.com", scanForLinks: scan))
    #expect(sender.text?.scanForLinks == scan)
  }

  @Test("A multipart send hands the helper the flag it was given", arguments: [true, false])
  func multipartCarriesTheFlag(_ scan: Bool) async throws {
    let sender = RecordingSender()
    let message = try interface(privateAPI: sender)
    _ = try? await message.sendMultipart(
      MessageInterface.SendMultipartRequest(
        chatGUID: chat, parts: [MessagePart(text: "BB test https://example.com")],
        scanForLinks: scan))
    #expect(sender.multipart?.scanForLinks == scan)
  }

  @Test("Through AppleScript a scan is refused rather than dropped")
  func appleScriptRefuses() async throws {
    // No helper, so the send resolves to AppleScript, which has no way to run the scan.
    // The refusal comes before AppleScript is touched, which is what lets this run here.
    let message = try interface(privateAPI: nil)
    let error = await #expect(throws: InterfaceError.self) {
      try await message.sendText(
        MessageInterface.SendTextRequest(
          chatGUID: chat, text: "BB test https://example.com", scanForLinks: true))
    }
    guard case .invalidRequest(let reason) = error else {
      Issue.record("expected a 400, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("ddScan"))
  }
}

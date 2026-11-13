//  LiveSendTests
//  One real message through the real runner, confirmed in the real `chat.db`.
//
//  Everything else in this target stops at `AppleScriptRunning`, so nothing else can notice a
//  script Messages no longer accepts. The row is the proof, not the sender's answer: a send
//  that returns can still land nowhere, or land with an error on it. And it is waited for,
//  because Messages writes the message row first, the `chat_message_join` row after it, and
//  `is_sent` after that.
//
//  Opt in with `BB_LIVE_SEND_GUID`, naming a chat you may message. It is read from the
//  environment so no real address is ever committed, and a run without it sends nothing:
//
//      BB_LIVE_SEND_GUID='iMessage;-;someone@example.com' swift test --filter LiveSend
//
//  It needs Automation permission for Messages and Full Disk Access for `chat.db`. Each run
//  really sends one message from the signed-in account, so run it to answer a question and
//  not in a loop. `RealSenderPolicyTests` holds this file to its gate.

import BBAppleScript
import BBCore
import BBIMessage
import BBPersistence
import Foundation
import Testing

private let liveGUID: String? = {
  let value = ProcessInfo.processInfo.environment["BB_LIVE_SEND_GUID"]
  return value?.isEmpty == false ? value : nil
}()

@Suite(
  "Live send",
  .enabled(
    if: liveGUID != nil,
    "Set BB_LIVE_SEND_GUID to a chat you may message. This sends one real message."
  ))
struct LiveSendTests {

  /// How long Messages gets to finish writing the row once the send has answered.
  private static let rowDeadline = Duration.seconds(30)

  @Test("A send reaches the chat it named and is marked as sent")
  func sendLandsInChatDatabase() async throws {
    let guid = try #require(liveGUID)
    let started = Date()
    // The time makes the text unique, so the row found below can only be this run's.
    let text = "BB test live send \(Int(started.timeIntervalSince1970))"

    let sender = AppleScriptMessageSender(runner: AppleScriptRunner())
    let resolved = try await sender.send(chatGUID: guid, text: text)
    #expect(ChatGUID.sameChat(resolved, guid), "the send went to a different chat")

    let database = try ReadOnlyDatabase(path: ChatDatabase.defaultPath)
    let repository = MessageRepository(
      database: database,
      profile: try await SchemaProfile.detect(
        in: database, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
    // Filtering on the chat is what proves the join row: a message in no chat is not returned.
    let query = MessageRepository.MessageQuery(
      chatGUID: guid, after: started.addingTimeInterval(-5), limit: 25, onlyFromMe: true)

    let row = try await poll(.every(.milliseconds(500)), within: Self.rowDeadline) { _ in
      let rows = try await repository.messages(query)
      // Matched on `universalText()`, because an AppleScript send can land with `text` NULL and
      // the words only in `attributedBody`.
      return rows.first { $0.universalText() == text && ($0.isSent || $0.error != 0) }
    }

    let settled = try #require(
      row, "no sent row for this message in the chat within \(Self.rowDeadline)")
    // Messages answered the script either way, so this is the only place a refusal shows. 22 is
    // `imagent` reporting "Remote user isn't registered": the address, not this server.
    #expect(settled.error == 0, "Messages refused the send with error \(settled.error)")
    #expect(settled.isSent)
  }
}

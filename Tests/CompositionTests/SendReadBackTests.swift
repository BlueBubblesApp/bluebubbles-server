//  SendReadBackTests
//  A send Messages accepted is never answered as a failure because the row could not be read.
//
//  The read-back after a send is a `chat.db` query, and a query can fail. Propagated, it
//  answers a send that has gone out with a 500, which the client's outgoing handler takes as a
//  failed send and offers to repeat. Driven here end to end through the
//  AppleScript backend with a runner that accepts the script and runs nothing, over an empty
//  database whose profile declares no columns, so every read throws. No Messages, no send: the
//  runner is a stub.

import BBAppleScript
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Send read-back")
struct SendReadBackTests {

  /// Accepts every script and does nothing, standing in for Messages taking the send.
  private struct AcceptingRunner: AppleScriptRunning {
    func run(
      key: String, source: String, handler: String,
      arguments: [AppleScriptValue], target: String, timeout: Duration
    ) async throws -> String? { nil }
  }

  @Test("A send whose read-back fails answers 200 with the identifiers, not an error")
  func failedReadBackIsNotAFailedSend() async throws {
    let interface = MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: nil,
      appleScript: AppleScriptMessageSender(runner: AcceptingRunner())
    )

    let outcome = try await interface.sendText(
      MessageInterface.SendTextRequest(
        chatGUID: "iMessage;-;someone@example.com", text: "BB test read-back",
        forcedBackend: .appleScript)
    )

    #expect(outcome.message == nil)
    #expect(outcome.chatGUID != nil)
    #expect(!MessageInterface.sendFailed(outcome))

    // What `WriteHandlers.sendResult` answers with: no send error on the outcome is a 200, and
    // this is its body, the identifiers the backend reported, which is the timeout's answer.
    let data = interface.serialize(outcome, tempGUID: "temp-1")
    #expect(data["chatGuid"]?.stringValue == outcome.chatGUID)
    #expect(data["tempGuid"]?.stringValue == "temp-1")
    #expect(data["error"] == nil)
  }
}

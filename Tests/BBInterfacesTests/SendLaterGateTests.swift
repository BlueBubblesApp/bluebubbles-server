//  SendLaterGateTests
//  Every Send Later operation refuses on a Mac that cannot schedule, with the same sentence.
//
//  The gate used to be three implementations (a version check on send and reschedule, a schema
//  check on the pending list) and absent from cancel, edit and send-now, which went on to the
//  helper and failed there with whatever IMCore said about a selector it does not have. Each
//  operation here is driven on Sonoma against a helper that would refuse anything, so a
//  refusal that is not the gate's sentence means the operation reached past it.

import BBIMessage
import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Send Later gate")
struct SendLaterGateTests {

  private static let sentence = "Send Later is only supported on macOS Sequoia (15) and newer"

  /// A database whose profile declares the schedule columns, so only the OS half can refuse.
  private func interface(osMajorVersion: Int) throws -> MessageInterface {
    let profile = SchemaProfile(
      tables: ["message"], messageColumns: ["schedule_type", "schedule_state"],
      chatColumns: [], handleColumns: [], attachmentColumns: [], dateUnit: .nanoseconds)
    return MessageInterface(
      repository: MessageRepository(
        database: try InterfaceFixtures.emptyDatabase(), profile: profile),
      serializer: InterfaceFixtures.serializer,
      privateAPI: FailingPrivateAPI(),
      osMajorVersion: osMajorVersion
    )
  }

  private func refusal(_ operation: () async throws -> Void) async -> String? {
    do {
      try await operation()
      return nil
    } catch InterfaceError.invalidRequest(let detail) {
      return detail
    } catch {
      return "\(error)"
    }
  }

  @Test("Cancel, edit, send-now, reschedule, send and list all refuse on Sonoma")
  func everyOperationIsGated() async throws {
    let interface = try interface(osMajorVersion: 14)
    let chat = "iMessage;-;someone@example.com"
    let guid = "11111111-0000-0000-0000-000000000007"
    let later = Date().addingTimeInterval(3600)

    let refusals: [(String, String?)] = [
      (
        "cancel",
        await refusal {
          try await interface.cancelScheduledMessage(chatGUID: chat, messageGUID: guid)
        }
      ),
      (
        "edit",
        await refusal {
          try await interface.editScheduledMessage(
            chatGUID: chat, messageGUID: guid, newText: "BB test edit")
        }
      ),
      (
        "send-now",
        await refusal {
          try await interface.sendScheduledMessageNow(chatGUID: chat, messageGUID: guid)
        }
      ),
      (
        "reschedule",
        await refusal {
          try await interface.rescheduleMessage(chatGUID: chat, messageGUID: guid, to: later)
        }
      ),
      (
        "send",
        await refusal {
          _ = try await interface.sendText(
            MessageInterface.SendTextRequest(
              chatGUID: chat, text: "BB test send later", scheduledFor: later,
              forcedBackend: .privateAPI))
        }
      ),
      ("list", await refusal { _ = try await interface.pendingScheduledMessages() }),
    ]
    for (operation, refusal) in refusals {
      #expect(refusal == Self.sentence, "\(operation) answered \(refusal ?? "nothing")")
    }
  }

  @Test("On Sequoia the gate lets the operation through to whatever comes next")
  func sequoiaPasses() async throws {
    let interface = try interface(osMajorVersion: 15)
    try interface.requireSendLaterSupported()
    // Past the gate, the operation reaches the message lookup, which this empty database
    // cannot answer: anything but the gate's sentence proves the gate let it by.
    let refused = await refusal {
      try await interface.cancelScheduledMessage(
        chatGUID: "iMessage;-;someone@example.com",
        messageGUID: "11111111-0000-0000-0000-000000000007")
    }
    #expect(refused != Self.sentence)
  }
}

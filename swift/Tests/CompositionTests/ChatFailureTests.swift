//  ChatFailureTests
//  What a client receives when Messages refuses a chat operation.
//
//  The companion to `SendFailureTests`, and the same contract: a failure that came from
//  Messages is reported as `InterfaceError.messagesFailed`, which projects to the 500
//  `iMessage Error` clients read — never as a generic server error. `ChatInterface` has no
//  AppleScript fallback, so this drives all of it against `FailingPrivateAPI`.
//
//  The first test walks ALL of them rather than sampling. That is the point of it: the risk
//  with a translation applied call site by call site is not that the translation is wrong, it
//  is that one call site was missed, and only an exhaustive walk finds the one that was.

import BBHTTPAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Chat failure translation")
struct ChatFailureTests {

  private static let guid = "iMessage;-;person@example.com"

  private func interface(
    error: any Error = PrivateAPIError.rejectedByMessages(reason: "Messages said no")
  ) throws -> ChatInterface {
    ChatInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: FailingPrivateAPI(error: error)
    )
  }

  /// Every operation that reaches Messages, by name, so a failure says which one.
  ///
  /// Built as a list rather than as twenty-three tests because the assertion is identical for
  /// all of them and the value is in the coverage being total. A new chat operation added
  /// without a line here is the gap this cannot close — but one added and then forgotten in
  /// `throughMessages` is exactly what it catches.
  private func operations(
    _ chat: ChatInterface, photoPath: String
  ) -> [(String, () async throws -> Void)] {
    [
      ("create", { _ = try await chat.create(addresses: ["person@example.com"]) }),
      ("delete", { try await chat.delete(guid: Self.guid) }),
      ("leave", { try await chat.leave(guid: Self.guid) }),
      ("setPinned", { try await chat.setPinned(guid: Self.guid, pinned: true) }),
      ("pinned", { _ = try await chat.pinned() }),
      ("muteState", { _ = try await chat.muteState(guid: Self.guid) }),
      (
        "setMute",
        {
          _ = try await chat.setMute(
            guid: Self.guid, until: Date().addingTimeInterval(3600), syncToPairedDevice: false)
        }
      ),
      ("unmute", { _ = try await chat.unmute(guid: Self.guid, syncToPairedDevice: false) }),
      ("refetchBackground", { try await chat.refetchBackground(guid: Self.guid) }),
      ("clearHistory", { _ = try await chat.clearHistory(guid: Self.guid) }),
      ("filterState", { _ = try await chat.filterState(guid: Self.guid) }),
      (
        "markSenderKnown",
        { _ = try await chat.markSenderKnown(guid: Self.guid, saveInContacts: false) }
      ),
      (
        "markSpam",
        { _ = try await chat.markSpam(guid: Self.guid, reportToCarrier: false, dryRun: true) }
      ),
      (
        "reportJunk",
        { _ = try await chat.reportJunk(guid: Self.guid, reportToCarrier: false, dryRun: true) }
      ),
      ("setFilter", { _ = try await chat.setFilter(guid: Self.guid, category: 0) }),
      ("setDisplayName", { try await chat.setDisplayName(guid: Self.guid, to: "Name") }),
      ("setGroupPhoto", { try await chat.setGroupPhoto(guid: Self.guid, imagePath: photoPath) }),
      ("addParticipant", { try await chat.addParticipant("person@example.com", to: Self.guid) }),
      (
        "removeParticipant",
        { try await chat.removeParticipant("person@example.com", from: Self.guid) }
      ),
      ("setTyping(true)", { try await chat.setTyping(guid: Self.guid, typing: true) }),
      ("setTyping(false)", { try await chat.setTyping(guid: Self.guid, typing: false) }),
      ("markRead", { try await chat.markRead(guid: Self.guid) }),
      ("markUnread", { try await chat.markUnread(guid: Self.guid) }),
      ("deleteMessage", { try await chat.deleteMessage("message-guid", in: Self.guid) }),
    ]
  }

  @Test("Every chat operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let chat = try interface()
    let photoPath = try InterfaceFixtures.temporaryFile()

    for (name, operation) in operations(chat, photoPath: photoPath) {
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        // The helper's own sentence, not the case name — `PrivateAPIError` is a
        // `LocalizedError`, and `DiagnosticText.sentence(for:)` prefers that over
        // `rejectedByMessages(reason: "…")`.
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  /// The rendered envelope for one of them, since that is what a client actually parses.
  @Test("A refused chat operation renders as 500 with the iMessage error type")
  func rendersWithTheDocumentedShape() async throws {
    let chat = try interface()

    do {
      try await chat.leave(guid: Self.guid)
      Issue.record("leaving should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
      #expect(envelope.error?.message == "Messages said no")
      #expect(envelope.data == nil)
    }
  }

  // MARK: - What must NOT be translated

  /// A validation failure belongs to the caller, and stays a 400.
  ///
  /// Three operations check the request before they reach Messages. Wrapping their refusals
  /// would tell a client its own mistake was a server fault, and — because `IMessageError` is
  /// a 500 — invite it to retry a request that can never succeed.
  @Test(
    "A request the interface rejects itself keeps its 400",
    arguments: [
      "create with no addresses", "setMute in the past", "setFilter with a negative category",
    ])
  func validationErrorsPassThrough(_ scenario: String) async throws {
    let chat = try interface()

    do {
      switch scenario {
      case "create with no addresses":
        _ = try await chat.create(addresses: [])
      case "setMute in the past":
        _ = try await chat.setMute(
          guid: Self.guid, until: Date(timeIntervalSince1970: 0), syncToPairedDevice: false)
      default:
        _ = try await chat.setFilter(guid: Self.guid, category: -1)
      }
      Issue.record("\(scenario) should have been rejected")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
    }
  }

  /// A missing file is also the caller's problem, and is checked before Messages is asked.
  @Test("A group photo that is not on disk is a 400, not a Messages failure")
  func missingPhotoIsABadRequest() async throws {
    let chat = try interface()

    do {
      try await chat.setGroupPhoto(guid: Self.guid, imagePath: "/nonexistent/photo.png")
      Issue.record("the photo should have been rejected")
    } catch let error as InterfaceError {
      #expect(error == .invalidRequest("no file at /nonexistent/photo.png"))
    }
  }

  /// No helper at all is a different answer from a helper that refused, and it is the one
  /// `requirePrivateAPI` gives: the canonical message clients match on, plus the feature name
  /// in `data`. Re-wrapping it in `throughMessages` would discard both.
  @Test("With no helper connected, the canonical unavailable message survives")
  func missingHelperKeepsItsPayload() async throws {
    let chat = ChatInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: nil
    )

    do {
      try await chat.leave(guid: Self.guid)
      Issue.record("leaving should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "leaving a chat"))
    }
  }
}

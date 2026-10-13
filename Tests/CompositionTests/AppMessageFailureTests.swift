//  AppMessageFailureTests
//  What a client receives when Messages refuses an app balloon.
//
//  The last operation in the tree that reaches Messages, and the last entry in
//  `FailureTranslationCoverageTests.knownUncovered`. Same contract as the other five walks:
//  a refusal from Messages is `InterfaceError.messagesFailed`, projecting to the 500
//  `iMessage Error`, never a generic server error.
//
//  **Five things can throw before this one reaches Messages**, which is why it was the entry
//  left over: an unbuildable payload URL, a missing helper, an empty bundle id, the Polls
//  refusal, an unparseable session id, and an encode failure. Every one of them is an
//  `.invalidRequest` or a `.helperUnavailable` that must NOT be reported as a Messages
//  failure, because Messages was never asked — so the walk has to pick its way past all of
//  them to reach the translation at all, and the tests below pin each as the 400 it is.
//
//  `AppBalloonRefusalTests` covers what `refusal(forBalloon:payload:)` decides, as a pure
//  function. What it does not cover is that a refusal surfaces through the real send path as
//  a 400 rather than as a Messages failure, which is the one assertion borrowed here.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBHTTPAPI
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("App message failure translation")
struct AppMessageFailureTests {

  private static let chat = "iMessage;-;person@example.com"
  /// Any third-party balloon: specifically NOT Polls, which this route refuses on purpose.
  private static let balloon =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID123:com.example.game"

  private func interface(
    privateAPI: MessageInterface.Helper? = FailingPrivateAPI()
  ) throws -> MessageInterface {
    MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: privateAPI
    )
  }

  /// Every app-message operation that reaches Messages, by name.
  ///
  /// The payload is a `.url`, which is the one shape that reaches `throughMessages` without
  /// touching the JSON encoder: the point here is the translation, not the payload builder,
  /// which `AppBalloonRefusalTests` exercises on its own.
  private func operations(
    _ message: MessageInterface
  ) -> [(String, () async throws -> Void)] {
    [
      (
        "sendAppMessage",
        {
          _ = try await message.sendAppMessage(
            chatGUID: Self.chat, balloonBundleID: Self.balloon,
            payload: .url("https://example.com/move?state=1"))
        }
      )
    ]
  }

  @Test("Every app-message operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let message = try interface()

    for (name, operation) in operations(message) {
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  @Test("A refused app balloon renders as 500 with the iMessage error type")
  func rendersWithTheDocumentedShape() async throws {
    let message = try interface()

    do {
      _ = try await message.sendAppMessage(
        chatGUID: Self.chat, balloonBundleID: Self.balloon,
        payload: .url("https://example.com/move?state=1"))
      Issue.record("the send should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
      #expect(envelope.error?.message == "Messages said no")
    }
  }

  // MARK: - What must NOT be translated

  @Test(
    "A request this server rejects itself keeps its 400",
    arguments: [
      ("an empty payload URL", "", Self.balloon, String?.none),
      ("an empty bundle id", "https://example.com/x", "", String?.none),
      ("a session id that is not a UUID", "https://example.com/x", Self.balloon, "not-a-uuid"),
    ]
  )
  func validationKeepsIts400(
    label: String, url: String, balloon: String, session: String?
  ) async throws {
    // Each of these is decided BEFORE the helper is asked, so reporting any of them as a
    // Messages failure would tell a client its own mistake was a server fault — and a 500
    // invites a retry of a request that can never succeed.
    let message = try interface()

    do {
      _ = try await message.sendAppMessage(
        chatGUID: Self.chat, balloonBundleID: balloon, payload: .url(url), sessionID: session)
      Issue.record("\(label) should have been rejected")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("\(label): expected .invalidRequest, got \(error)")
        return
      }
    }
  }

  @Test("The Polls refusal surfaces as a 400 through the real send path")
  func pollBalloonIsRefusedAsABadRequest() async throws {
    // `AppBalloonRefusalTests` proves what `refusal(forBalloon:payload:)` decides. This
    // proves the decision reaches the caller as a 400 rather than being swallowed into a
    // Messages failure — the route writes a TEMPLATE layout and a poll needs a LIVE one, so
    // a poll sent from here renders as "Sent a poll" with no options. It reached a real
    // conversation twice.
    let message = try interface()

    do {
      _ = try await message.sendAppMessage(
        chatGUID: Self.chat, balloonBundleID: PollsApp.balloonBundleID,
        payload: .url("https://example.com/x"))
      Issue.record("a poll balloon should have been refused")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
    }
  }

  @Test("With no helper, an app balloon is unavailable rather than refused")
  func missingHelperIsNotAMessagesFailure() async throws {
    let message = try interface(privateAPI: nil)

    do {
      _ = try await message.sendAppMessage(
        chatGUID: Self.chat, balloonBundleID: Self.balloon,
        payload: .url("https://example.com/x"))
      Issue.record("the send should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "app messages"))
    }
  }
}

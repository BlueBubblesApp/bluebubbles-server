//  SendFailureTests
//  What a client receives when Messages refuses to send.
//
//  A failed send is HTTP 500 with `error.type = "iMessage Error"` — the response clients
//  depend on most. Neither backend produces it directly: AppleScript throws
//  `MessageSendError` and the helper throws `PrivateAPIError`, and untranslated both reach
//  the renderer's fallback as a generic `Server Error`, indistinguishable from the server
//  itself having broken.
//
//  What these assert is the DOMAIN case — `InterfaceError.messagesFailed` — not the status.
//  The interfaces layer no longer speaks HTTP, and the mapping is asserted once in
//  `InterfaceErrorHTTPTests` rather than re-derived in every suite.
//
//  Both branches are driven here — AppleScript through a failing `AppleScriptRunning`, the
//  helper through `FailingPrivateAPI` — because the two throw different error types and only
//  one of them is a `LocalizedError`. The translation itself is shared: it lives on
//  `MessagesBackedInterface`, which `ChatInterface` also conforms to. See `ChatFailureTests`
//  for the exhaustive walk over that side.

import BBAppleScript
import BBSerialization
import Foundation
import Testing

@testable import BBHTTPAPI
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Send failure translation")
struct SendFailureTests {

  // MARK: - Harness

  /// A runner that always fails, standing in for Messages refusing the script.
  ///
  /// `scriptFailed` is the realistic case and the one that motivated this: a real response
  /// carried `scriptFailed(number: -1728, message: "Messages got an error: …")` as the
  /// client-facing string.
  private struct FailingRunner: AppleScriptRunning {
    let error: any Error
    func run(
      key: String, source: String, handler: String,
      arguments: [AppleScriptValue], target: String
    ) async throws -> String? {
      throw error
    }
  }

  /// A `MessageInterface` whose AppleScript backend fails.
  private func interface(failingWith error: any Error) throws -> MessageInterface {
    MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: nil,
      appleScript: AppleScriptMessageSender(runner: FailingRunner(error: error))
    )
  }

  /// The same interface with a helper that refuses, so the OTHER backend can be driven.
  ///
  /// `FailingPrivateAPI` reports itself connected, so `availableBackend()` chooses it and the
  /// send reaches `PrivateAPIError` rather than falling back to AppleScript.
  private func privateAPIInterface() throws -> MessageInterface {
    MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: FailingPrivateAPI()
    )
  }

  private func send(_ interface: MessageInterface) async throws -> JSONValue {
    try await interface.sendText(
      MessageInterface.SendTextRequest(
        chatGUID: "iMessage;-;person@example.com",
        text: "hello",
        forcedBackend: .appleScript
      )
    )
  }

  // MARK: - The contract

  @Test("A backend failure comes back as an iMessage error, not a server error")
  func backendFailureIsAnIMessageError() async throws {
    let interface = try interface(
      failingWith: MessageSendError.scriptFailed(
        number: -1728, message: "Messages got an error: Can't get chat id"
      )
    )

    await #expect(throws: InterfaceError.self) { try await send(interface) }

    do {
      _ = try await send(interface)
      Issue.record("the send should have failed")
    } catch let error as InterfaceError {
      // The domain case, not its status. What a client sees is asserted once in
      // `InterfaceErrorHTTPTests` rather than re-derived here.
      #expect(
        error
          == .messagesFailed(
            "Messages refused the request (AppleScript error -1728): "
              + "Messages got an error: Can't get chat id"))
    }
  }

  /// The rendered envelope, not just the thrown type — this is what a client parses.
  @Test("The failure renders as 500 with the iMessage error type on the wire")
  func failureRendersWithTheDocumentedShape() async throws {
    let interface = try interface(failingWith: MessageSendError.messagesNotRunning)

    do {
      _ = try await send(interface)
      Issue.record("the send should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
      // `MessageSendError.messagesNotRunning`'s own sentence, carried through the
      // translation rather than replaced by a generic one.
      #expect(envelope.error?.message == "Messages is not running.")
      // No message was created, so there is nothing to put in `data` — and the key is
      // omitted rather than emitted as null.
      #expect(envelope.data == nil)
    }
  }

  /// The half that must NOT be translated.
  ///
  /// `sendText` rejects a request asking for a reply on the AppleScript backend with a
  /// `BadRequest`, because AppleScript cannot express one. That is the client's mistake and
  /// already has a deliberate status; wrapping it would turn a clear 400 into a 500 and tell
  /// the caller their own request was a server fault.
  @Test("A validation error thrown by the send path keeps its own status")
  func validationErrorsPassThrough() async throws {
    let interface = try interface(failingWith: MessageSendError.messagesNotRunning)

    do {
      _ = try await interface.sendText(
        MessageInterface.SendTextRequest(
          chatGUID: "iMessage;-;person@example.com",
          text: "hello",
          replyToGUID: "some-guid",
          forcedBackend: .appleScript
        )
      )
      Issue.record("the send should have been rejected")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
    }
  }

  /// The other error that must survive untranslated: no helper connected.
  ///
  /// `requirePrivateAPI` already throws the canonical `IMessageError` with the feature name
  /// in `data`, and clients match on its message text. Re-wrapping it would drop the `data`
  /// and replace a string some clients compare against.
  @Test("A missing helper keeps the canonical unavailable message and its data")
  func missingHelperKeepsItsPayload() async throws {
    let interface = try interface(failingWith: MessageSendError.messagesNotRunning)

    do {
      try await interface.react(
        chatGUID: "iMessage;-;person@example.com",
        targetGUID: "guid",
        reaction: "love"
      )
      Issue.record("the reaction should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "reactions"))
    }
  }

  /// The other backend, same contract.
  ///
  /// `PrivateAPIError` is a `LocalizedError` but not an `HTTPError`, so before the
  /// translation it rendered as a 500 `Server Error` with a readable message — right words,
  /// wrong type, and the type is what a client branches on.
  @Test("A helper refusal is an iMessage error too, not just an AppleScript one")
  func privateAPIFailureAlsoTranslates() async throws {
    let interface = try privateAPIInterface()

    do {
      _ = try await interface.sendText(
        MessageInterface.SendTextRequest(
          chatGUID: "iMessage;-;person@example.com", text: "hello"
        )
      )
      Issue.record("the send should have failed")
    } catch let error as InterfaceError {
      #expect(error == .messagesFailed("Messages said no"))
    }
  }
}

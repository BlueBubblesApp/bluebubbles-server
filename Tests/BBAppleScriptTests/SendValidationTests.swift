//  SendValidationTests
//  The checks that happen BEFORE anything reaches Messages.
//
//  Everything below the Apple Event boundary is asserted here, against a sender that fails the
//  test if it is reached. The boundary itself really sends, so it is exercised only on request:
//  by `LiveSendTests` and `Tools/send-probe`, each against a GUID supplied at run time. See
//  `.claude/docs/imessage.md`.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBTestSupport
import Foundation
import Testing

@testable import BBAppleScript

@Suite("Send validation")
struct SendValidationTests {

  /// The current server returns null rather than scripting a no-op. Reaching AppleScript at
  /// all for an empty send would cost a process hop to accomplish nothing.
  @Test("An empty send is rejected before it reaches AppleScript")
  func rejectsEmptySend() async {
    let sender = InterfaceFixtures.noSender
    await #expect(throws: MessageSendError.nothingToSend) {
      try await sender.send(chatGUID: "iMessage;-;someone@example.com", text: "")
    }
    await #expect(throws: MessageSendError.nothingToSend) {
      try await sender.send(chatGUID: "iMessage;-;someone@example.com")
    }
  }

  /// `as POSIX file` on a missing path fails with -43, which names no file. Checking here
  /// means the error says which attachment was missing.
  @Test("A missing attachment is reported by path, not as an opaque -43")
  func reportsMissingAttachment() async {
    let sender = InterfaceFixtures.noSender
    await #expect(throws: MessageSendError.attachmentMissing(path: "/nope/missing.png")) {
      try await sender.send(
        chatGUID: "iMessage;-;someone@example.com",
        attachmentPath: "/nope/missing.png"
      )
    }
  }

  @Test("A malformed chat GUID is rejected before scripting")
  func rejectsMalformedGUID() async {
    let sender = InterfaceFixtures.noSender
    await #expect(throws: MessageSendError.invalidChatGUID("not-a-guid")) {
      try await sender.send(chatGUID: "not-a-guid", text: "hello")
    }
  }

  /// The one-to-one fallback addresses a participant, which a group does not have.
  @Test("The direct-address fallback refuses a group identifier")
  func rejectsGroupFallback() async {
    let sender = InterfaceFixtures.noSender
    await #expect(throws: MessageSendError.cannotFallbackForGroupChat("chat000000000000000001")) {
      try await sender.send(address: "chat000000000000000001", text: "hello")
    }
  }

  /// Every interface a test builds is given this sender, so reaching it has to fail the test
  /// and not only throw: a `try?` at the call site would swallow the throw.
  @Test("Reaching the sender that tests are given fails the test")
  func noSenderFailsTheTest() async {
    await withKnownIssue {
      _ = try? await InterfaceFixtures.noSender.send(
        chatGUID: "iMessage;-;someone@example.com", text: "hello")
    }
  }
}

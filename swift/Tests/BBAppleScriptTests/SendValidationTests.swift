//  SendValidationTests
//  The checks that happen BEFORE anything reaches Messages.
//
//  Why there is no end-to-end send test here
//  -----------------------------------------
//  There cannot be one, and the reason is worth recording so nobody adds it back.
//
//  AppleScript's remote send does not wait on the Foundation run loop. A stack sample of a
//  hung run shows it inside the CARBON event loop:
//
//      UASRemoteSend -> InternalComponentActive -> AEDefaultActiveProc
//        -> WNEInternal -> GetNextEventMatchingMask -> RunCurrentEventLoopInMode -> mach_msg
//
//  That reply is delivered through a main event loop. An ordinary process has one, so the
//  send works — verified by `Tools/send-probe`, which sends for real. The `swift test` bundle
//  host does not pump one, so the same call blocks forever. A test that can never pass is
//  worse than no test.
//
//  So: everything below the Apple Event boundary is asserted here, and the boundary itself is
//  exercised by `Tools/send-probe` against a GUID supplied on the command line. See
//  `.claude/docs/imessage.md`.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAppleScript

@Suite("Send validation")
struct SendValidationTests {

  /// The current server returns null rather than scripting a no-op. Reaching AppleScript at
  /// all for an empty send would cost a process hop to accomplish nothing.
  @Test("An empty send is rejected before it reaches AppleScript")
  func rejectsEmptySend() async {
    let sender = AppleScriptMessageSender()
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
    let sender = AppleScriptMessageSender()
    await #expect(throws: MessageSendError.attachmentMissing(path: "/nope/missing.png")) {
      try await sender.send(
        chatGUID: "iMessage;-;someone@example.com",
        attachmentPath: "/nope/missing.png"
      )
    }
  }

  @Test("A malformed chat GUID is rejected before scripting")
  func rejectsMalformedGUID() async {
    let sender = AppleScriptMessageSender()
    await #expect(throws: MessageSendError.invalidChatGUID("not-a-guid")) {
      try await sender.send(chatGUID: "not-a-guid", text: "hello")
    }
  }

  /// The one-to-one fallback addresses a participant, which a group does not have.
  @Test("The direct-address fallback refuses a group identifier")
  func rejectsGroupFallback() async {
    let sender = AppleScriptMessageSender()
    await #expect(throws: MessageSendError.cannotFallbackForGroupChat("chat000000000000000001")) {
      try await sender.send(address: "chat000000000000000001", text: "hello")
    }
  }

}

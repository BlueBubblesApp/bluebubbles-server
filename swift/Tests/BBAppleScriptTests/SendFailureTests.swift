//  SendFailureTests
//  What a caller is told when Messages refuses, and whether it is worth trying again.
//
//  The send itself cannot be tested here: actuating it needs Messages.app, a signed-in
//  account, and — for the remote-send path — a Carbon event loop the `swift test` host does
//  not pump. That boundary is real and `Tools/send-probe` exists because of it.
//
//  What DOES stop at this side of the boundary is everything the server decides about a
//  failure: which AppleScript error number means what, whether another spelling of the chat
//  GUID is worth attempting, and what the caller finally sees when none of them work. Those
//  were unreachable until `AppleScriptRunning` existed, and they are what a user meets when
//  something is wrong — an unhelpful answer here reads as "the server is broken" rather than
//  "grant Automation permission".

import Foundation
import Testing

@testable import BBAppleScript

/// A runner that fails on command, and records what it was asked to do.
///
/// The recording is the point for the retry tests: whether a second attempt happened at all
/// is the behaviour under test, and it is invisible from the thrown error alone.
private final class StubRunner: AppleScriptRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var _handlers: [String] = []
  private var _arguments: [[AppleScriptValue]] = []
  private let outcome: @Sendable (Int) throws -> String?

  /// - Parameter outcome: called with the attempt number, 1-based.
  init(outcome: @escaping @Sendable (Int) throws -> String?) {
    self.outcome = outcome
  }

  static func alwaysFailing(_ error: AppleScriptError) -> StubRunner {
    StubRunner { _ in throw error }
  }

  var attempts: Int { lock.withLock { _handlers.count } }

  var arguments: [[AppleScriptValue]] { lock.withLock { _arguments } }

  func run(
    key: String, source: String, handler: String,
    arguments: [AppleScriptValue], target: String
  ) async throws -> String? {
    let attempt = lock.withLock {
      _handlers.append(handler)
      _arguments.append(arguments)
      return _handlers.count
    }
    return try outcome(attempt)
  }
}

@Suite("Send failure handling")
struct SendFailureTests {

  // MARK: - Error mapping

  @Test("An AppleScript error becomes the send error a person can act on")
  func errorMapping() {
    #expect(MessageSendError(.notPermitted(target: "Messages")) == .automationNotPermitted)
    #expect(MessageSendError(.targetNotRunning(target: "Messages")) == .messagesNotRunning)
    #expect(
      MessageSendError(.executionFailed(number: -1728, message: "no chat"))
        == .scriptFailed(number: -1728, message: "no chat"))
    // A compilation failure has no AppleScript error number, so it reports 0 rather than
    // inventing one that would look like a real OSStatus.
    #expect(
      MessageSendError(.compilationFailed(message: "syntax"))
        == .scriptFailed(number: 0, message: "syntax"))
  }

  /// -1743 and -10004 are both "not permitted"; -600 and -609 are both "not running".
  /// Branching on the NUMBER rather than the message is what keeps this working when Apple
  /// rewords the string.
  @Test(
    "The numbers that mean something specific are recognised",
    arguments: [
      (-1743, MessageSendError.automationNotPermitted),
      (-10004, MessageSendError.automationNotPermitted),
      (-600, MessageSendError.messagesNotRunning),
      (-609, MessageSendError.messagesNotRunning),
    ])
  func specificNumbers(_ number: Int, _ expected: MessageSendError) {
    let mapped = AppleScriptError.mapped(number: number, message: "x", target: "Messages")
    #expect(MessageSendError(mapped) == expected)
  }

  @Test("An unrecognised number is passed through rather than flattened")
  func unrecognisedNumberSurvives() {
    let mapped = AppleScriptError.mapped(
      number: -1728, message: "can't get chat", target: "Messages")
    #expect(mapped == .executionFailed(number: -1728, message: "can't get chat"))
  }

  // MARK: - Terminal failures stop the retry

  /// A chat GUID has several spellings (`iMessage;-;`, `SMS;-;`, `any;-;` on macOS 26) and
  /// the sender tries each. Permission and a missing Messages are terminal: retrying cannot
  /// help, and on the permission path each attempt is another system prompt at the user.
  @Test(
    "A terminal failure is thrown on the first attempt, not retried under other spellings",
    arguments: [
      AppleScriptError.notPermitted(target: "Messages"),
      AppleScriptError.targetNotRunning(target: "Messages"),
    ])
  func terminalFailuresDoNotRetry(_ error: AppleScriptError) async throws {
    let runner = StubRunner.alwaysFailing(error)
    let sender = AppleScriptMessageSender(runner: runner)

    await #expect(throws: MessageSendError.self) {
      try await sender.send(chatGUID: "iMessage;-;+12025550143", text: "hello")
    }
    #expect(runner.attempts == 1, "a terminal failure was retried \(runner.attempts) times")
  }

  @Test("A non-terminal failure is retried under the other spellings of the GUID")
  func nonTerminalFailuresRetry() async throws {
    let runner = StubRunner.alwaysFailing(
      .executionFailed(number: -1728, message: "can't get chat"))
    let sender = AppleScriptMessageSender(runner: runner)

    await #expect(throws: MessageSendError.self) {
      try await sender.send(chatGUID: "iMessage;-;+12025550143", text: "hello")
    }
    #expect(runner.attempts > 1, "only \(runner.attempts) attempt(s); the spellings were not tried")
  }

  /// The answer a user gets when nothing worked. "Chat not found" plus what was tried beats
  /// the last AppleScript error, which for a missing chat is an opaque -1728.
  @Test("When no spelling resolves, the caller is told the chat was not found and what was tried")
  func exhaustedSpellingsReportChatNotFound() async throws {
    let runner = StubRunner.alwaysFailing(
      .executionFailed(number: -1728, message: "can't get chat"))
    let sender = AppleScriptMessageSender(runner: runner)

    do {
      try await sender.send(chatGUID: "iMessage;-;+12025550143", text: "hello")
      Issue.record("the send should not have succeeded")
    } catch let error as MessageSendError {
      guard case .chatNotFound(let guid, let attempted) = error else {
        Issue.record("expected chatNotFound, got \(error)")
        return
      }
      #expect(guid == "iMessage;-;+12025550143")
      #expect(!attempted.isEmpty, "the attempted spellings should be reported")
    }
  }

  // MARK: - Success

  @Test("A spelling that works stops the retry and is the one reported")
  func firstWorkingSpellingWins() async throws {
    // Fails once, succeeds on the second spelling.
    let runner = StubRunner { attempt in
      if attempt == 1 { throw AppleScriptError.executionFailed(number: -1728, message: "no") }
      return nil
    }
    let sender = AppleScriptMessageSender(runner: runner)

    let used = try await sender.send(chatGUID: "iMessage;-;+12025550143", text: "hello")
    #expect(runner.attempts == 2)
    #expect(!used.isEmpty)
  }

  /// The address reaches AppleScript in the form Messages stored, not the form it was typed.
  @Test("The normalised address is what is handed to the script")
  func normalisedAddressIsSent() async throws {
    let runner = StubRunner { _ in nil }
    let sender = AppleScriptMessageSender(runner: runner)

    _ = try await sender.send(
      address: "(202) 555-0143", service: .iMessage, text: "hello")

    let first = try #require(runner.arguments.first)
    guard case .string(let address) = try #require(first.first) else {
      Issue.record("first argument was not a string")
      return
    }
    #expect(address == "+12025550143")
  }
}

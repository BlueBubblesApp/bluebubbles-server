//  FilterAndSessionValidationTests
//  Two v2 fields that were accepted without being understood.
//
//  Both are additive routes with no reference to transcribe, so the wording is ours; the rule
//  is the project's own non-negotiable — apply what was sent, or refuse it. A value passed
//  through to IMCore because nothing here had an opinion about it is the third option, and
//  it is the one that produced a conversation filed in a bucket Messages cannot draw and a
//  game reply sent as a new game.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBInterfaces

@Suite("Filter category and app-message session")
struct FilterAndSessionValidationTests {

  // MARK: The filter bucket

  /// MEASURED on macOS 26.5.2 by reading `filterCategory` through the helper for every chat
  /// on the machine: 14 filtered chats answered 0 or 1, 25 unfiltered ones answered 0, and
  /// junk is 2 (`IMCoreBridge.setChatFilter` already treats leaving it specially).
  @Test("The three measured buckets are the three that exist")
  func categoriesAreTheMeasuredOnes() {
    #expect(ChatInterface.ChatFilterCategory.allCases.map(\.rawValue) == [0, 1, 2])
  }

  @Test("Each bucket has a name a refusal can print")
  func everyCategoryIsNamed() {
    for category in ChatInterface.ChatFilterCategory.allCases {
      #expect(!category.label.isEmpty)
    }
  }

  @Test("A bucket beyond the measured set is not a bucket")
  func unknownCategory() {
    #expect(ChatInterface.ChatFilterCategory(rawValue: 3) == nil)
    #expect(ChatInterface.ChatFilterCategory(rawValue: 7) == nil)
    #expect(ChatInterface.ChatFilterCategory(rawValue: -1) == nil)
  }

  // MARK: The app-message session

  @Test("A UUID session is the session the caller named")
  func sessionParsed() throws {
    let identifier = UUID()
    #expect(try MessageInterface.session(for: identifier.uuidString) == identifier)
    // Lowercase too: a client that stringified its own UUID differently is still naming the
    // same session, and `UUID(uuidString:)` accepts either case.
    #expect(
      try MessageInterface.session(for: identifier.uuidString.lowercased()) == identifier)
  }

  /// Absent and empty both mean "start one", and each call mints its OWN: two first
  /// messages are two sessions, which is the difference between two games and one.
  @Test("No session at all mints a fresh one each time")
  func sessionAbsent() throws {
    #expect(try MessageInterface.session(for: nil) != MessageInterface.session(for: nil))
    #expect(try MessageInterface.session(for: "") != MessageInterface.session(for: ""))
    #expect(try MessageInterface.session(for: "") != MessageInterface.session(for: nil))
  }

  /// The shape that lost a move: a malformed id used to mint a fresh session, so a reply to
  /// a game in progress went out as a new invitation and was answered 200.
  @Test("A malformed session id is refused rather than replaced")
  func sessionMalformed() {
    for raw in ["not-a-uuid", "1234", "F72FD2F0-XXXX", UUID().uuidString + "!"] {
      var refused = false
      do {
        _ = try MessageInterface.session(for: raw)
      } catch {
        refused = true
        #expect(String(describing: error).contains("`sessionId` is not a UUID"))
      }
      #expect(refused, "`\(raw)` was accepted as a session id")
    }
  }
}

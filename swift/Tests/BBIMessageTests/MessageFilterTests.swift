//  MessageFilterTests
//  The `where` clause, and the eight statements a client actually sends.
//
//  **Transcribed from the client, not invented.** Each statement below is copied from the
//  BlueBubbles app: `search_query_helper.dart` (five), `incremental_sync_manager.dart` (two)
//  and `api_payload_parser.dart` (one). That is what makes this suite a contract check: if a
//  refactor stops understanding one of these, the feature behind it breaks silently, which is
//  exactly what happened when `where` was parsed by nobody at all.
//
//  The failure that motivated the whole file: the sync's `message.ROWID > :startRowId` was
//  accepted and dropped, so a delta of fifty messages came back as the newest thousand and a
//  `total` counting the entire database. Measured on a 420,679-message chat.db, that is 417
//  pages of 2.3 MB where the answer was one page. A statement this server does not understand
//  is now REFUSED rather than ignored, and that is the property most of these assert.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Message where-clause filters")
struct MessageFilterTests {

  private func parse(
    _ statement: String, _ arguments: [String: FilterArgument] = [:]
  ) throws -> MessageFilter {
    try MessageFilter.parse(statement: statement, arguments: arguments)
  }

  // MARK: - What the client sends

  @Test("incremental sync's row-id window")
  func rowIDWindow() throws {
    #expect(
      try parse("message.ROWID > :startRowId", ["startRowId": .number(420_723)])
        == .rowIDGreaterThan(420_723))
    #expect(
      try parse("message.ROWID <= :endRowId", ["endRowId": .number(420_728)])
        == .rowIDAtMost(420_728))
  }

  @Test("search's five statements")
  func searchStatements() throws {
    #expect(
      try parse("message.text LIKE :term COLLATE NOCASE", ["term": .text("%hello%")])
        == .textLike("%hello%"))
    #expect(try parse("message.associated_message_guid IS NULL") == .notAssociated)
    #expect(
      try parse("chat.guid = :guid", ["guid": .text("iMessage;-;+15550001111")])
        == .chatGUID("iMessage;-;+15550001111"))
    #expect(
      try parse("message.is_from_me = :isFromMe", ["isFromMe": .number(1)]) == .isFromMe(true))
    #expect(
      try parse("message.is_from_me = :isFromMe", ["isFromMe": .number(0)]) == .isFromMe(false))
    #expect(
      try parse("handle.id = :addr", ["addr": .text("+15550001111")])
        == .handleAddress("+15550001111"))
  }

  @Test("notification hydration's guid list")
  func guidList() throws {
    // TypeORM's spread placeholder. The `...` is part of the syntax, not of the name.
    #expect(
      try parse("message.guid IN (:...guids)", ["guids": .list(["A", "B"])])
        == .guidIn(["A", "B"]))
  }

  // MARK: - Shape, not spelling

  @Test("a statement is matched on shape, not on the placeholder's name")
  func placeholderNameIsNotPartOfTheContract() throws {
    // A client naming its bound value `:since` means the same query. Matching the raw text
    // would tie this server to one client's variable names.
    #expect(
      try parse("message.ROWID > :since", ["since": .number(7)]) == .rowIDGreaterThan(7))
  }

  @Test("whitespace around the operator does not matter")
  func spacing() throws {
    #expect(try parse("message.ROWID>:x", ["x": .number(7)]) == .rowIDGreaterThan(7))
    #expect(try parse("  message.ROWID   <=   :x  ", ["x": .number(9)]) == .rowIDAtMost(9))
  }

  @Test("a number sent as a string is still a number")
  func looseNumber() throws {
    // Some clients stringify their arguments. Refusing that would be pedantry about a value
    // we can read, and the reference's SQLite binding would have accepted it too.
    #expect(try parse("message.ROWID > :x", ["x": .text("42")]) == .rowIDGreaterThan(42))
  }

  // MARK: - What is refused

  @Test("an unknown statement is refused, not ignored")
  func unknownStatementThrows() {
    // THE POINT OF THE SUITE. Accepting a filter and not applying it answers a different
    // question with a 200, which is how the sync bug hid: the client asked for a delta and
    // was handed the newest thousand messages with no indication anything had been dropped.
    #expect(throws: MessageFilter.Unsupported.self) {
      try parse("message.date > :x", ["x": .number(1)])
    }
    #expect(throws: MessageFilter.Unsupported.self) {
      try parse("message.ROWID > (SELECT MAX(ROWID) FROM message)")
    }
    // The statement is quoted back, so a client author knows WHICH of their clauses lost.
    do {
      _ = try parse("message.service = :svc", ["svc": .text("SMS")])
      Issue.record("expected a refusal")
    } catch let unsupported as MessageFilter.Unsupported {
      #expect(unsupported.statement == "message.service = :svc")
    } catch {
      Issue.record("wrong error: \(error)")
    }
  }

  @Test("a known statement with a missing or wrong-typed argument is refused")
  func badArguments() {
    #expect(throws: MessageFilter.Unsupported.self) { try parse("message.ROWID > :x") }
    #expect(throws: MessageFilter.Unsupported.self) {
      try parse("message.ROWID > :x", ["x": .text("not a number")])
    }
    #expect(throws: MessageFilter.Unsupported.self) {
      try parse("chat.guid = :guid", ["guid": .number(1)])
    }
    // A spread placeholder bound to a single value is not a list.
    #expect(throws: MessageFilter.Unsupported.self) {
      try parse("message.guid IN (:...guids)", ["guids": .text("A")])
    }
  }

  /// The reason this is an allowlist rather than the reference's SQL passthrough.
  @Test("SQL smuggled into a known statement is refused")
  func noSQLInjectionSurface() {
    // None of these are a filter this server understands, so none of them reach SQLite.
    // With the reference's passthrough each one is a valid statement it would have run.
    for statement in [
      "message.ROWID > 0 OR 1=1 --",
      "message.is_from_me = (SELECT 1 FROM sqlite_master)",
      "message.text LIKE :term); DROP TABLE message; --",
      "1=1",
    ] {
      #expect(throws: MessageFilter.Unsupported.self) {
        try parse(statement, ["term": .text("%x%")])
      }
    }
  }
}

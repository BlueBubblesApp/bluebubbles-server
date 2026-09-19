//  MessageFilterSQLTests
//  That a parsed filter reaches SQLite, and that the count is filtered with the listing.
//
//  `MessageFilterTests` proves a statement is understood. This proves it is APPLIED, against
//  a real SQLite file rather than a mock, which is the half that was missing: `where` was
//  parsed by nobody and reached neither the rows nor their `total`, and a unit test of a
//  parser would have passed throughout.
//
//  **The count matters as much as the rows.** `metadata.total` describes the pages
//  `/message/query` returns, and a client divides it by its page size to decide how many more
//  to ask for. Counting without the filter reported the size of the whole database against
//  pages of a fifty-message delta, which is how the app's incremental sync came to request
//  four hundred pages and time out. Every case here asserts both.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Message filters reach SQL")
struct MessageFilterSQLTests {

  private func withFixture(
    _ body: (ChatDatabaseFixture) async throws -> Void
  ) async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await body(fixture)
  }

  /// Rows and total, under one set of filters. Returned together because the bug was that
  /// they disagreed.
  private func page(
    _ fixture: ChatDatabaseFixture, _ filters: [MessageFilter], requiresChat: Bool = false
  ) async throws -> (guids: [String], total: Int) {
    let query = MessageRepository.MessageQuery(
      limit: 100, requiresChat: requiresChat, filters: filters)
    let rows = try await fixture.repository.messages(query)
    let total = try await fixture.repository.messageCount(query)
    return (rows.map(\.guid), total)
  }

  @Test("no filters is every message")
  func unfiltered() async throws {
    try await withFixture { fixture in
      let result = try await page(fixture, [])
      #expect(result.guids.count == 6)
      #expect(result.total == 6)
    }
  }

  @Test("the row-id window the incremental sync sends")
  func rowIDWindow() async throws {
    try await withFixture { fixture in
      // The fixture seeds six messages in insertion order, so ROWID 4-6 is the last three.
      let above = try await page(fixture, [.rowIDGreaterThan(3)])
      #expect(above.guids.sorted() == ["MSG-0004", "MSG-0005", "MSG-0006"])
      // THE ASSERTION THE BUG WOULD HAVE FAILED: the total counts the filtered set, not
      // the database.
      #expect(above.total == 3)

      let window = try await page(fixture, [.rowIDGreaterThan(3), .rowIDAtMost(5)])
      #expect(window.guids.sorted() == ["MSG-0004", "MSG-0005"])
      #expect(window.total == 2)

      // A window past the end is empty, which is the condition that ENDS the client's
      // paging loop. Never reaching it is what turned a delta into a full re-sync.
      let beyond = try await page(fixture, [.rowIDGreaterThan(9_999)])
      #expect(beyond.guids.isEmpty)
      #expect(beyond.total == 0)
    }
  }

  @Test("is_from_me")
  func fromMe() async throws {
    try await withFixture { fixture in
      let mine = try await page(fixture, [.isFromMe(true)])
      #expect(mine.guids.sorted() == ["MSG-0002", "MSG-0004", "MSG-0005"])
      #expect(mine.total == 3)
      #expect(try await page(fixture, [.isFromMe(false)]).total == 3)
    }
  }

  @Test("text search matches the column, case-insensitively")
  func textLike() async throws {
    try await withFixture { fixture in
      let result = try await page(fixture, [.textLike("%GROUP%")])
      #expect(result.guids.sorted() == ["MSG-0004", "MSG-0005"])
      #expect(result.total == 2)
    }
  }

  @Test("a guid list, and an empty one")
  func guidIn() async throws {
    try await withFixture { fixture in
      let result = try await page(fixture, [.guidIn(["MSG-0001", "MSG-0006"])])
      #expect(result.guids.sorted() == ["MSG-0001", "MSG-0006"])
      #expect(result.total == 2)

      // AN EMPTY LIST MATCHES NOTHING. `IN ()` is not valid SQLite, so the condition has to
      // be written as a constant false; dropping it instead would answer "hydrate these
      // zero messages" with every message in the database.
      let none = try await page(fixture, [.guidIn([])])
      #expect(none.guids.isEmpty)
      #expect(none.total == 0)
    }
  }

  @Test("a chat guid, resolved prefix-tolerantly")
  func chatGUID() async throws {
    try await withFixture { fixture in
      let byExactGUID = try await page(
        fixture, [.chatGUID(ChatDatabaseFixture.chatGUID(ChatDatabaseFixture.aliceAddress))])
      #expect(byExactGUID.guids.sorted() == ["MSG-0001", "MSG-0002", "MSG-0003"])
      #expect(byExactGUID.total == 3)

      // A DIFFERENT SERVICE PREFIX FOR THE SAME CHAT still matches. Chat GUIDs differ
      // between servers on one iCloud account and macOS 26 rewrote every prefix to `any`,
      // so a client holding one from elsewhere must not silently get an empty page. See
      // `ChatGUID`, and rule 3 in the root CLAUDE.md.
      let byOtherPrefix = try await page(
        fixture, [.chatGUID("SMS;-;\(ChatDatabaseFixture.aliceAddress)")])
      #expect(byOtherPrefix.guids.sorted() == ["MSG-0001", "MSG-0002", "MSG-0003"])
      #expect(byOtherPrefix.total == 3)
    }
  }

  @Test("a handle address")
  func handleAddress() async throws {
    try await withFixture { fixture in
      let result = try await page(fixture, [.handleAddress(ChatDatabaseFixture.carolAddress)])
      #expect(result.guids == ["MSG-0006"])
      #expect(result.total == 1)
    }
  }

  @Test("filters compose, and compose with the query's own conditions")
  func composition() async throws {
    try await withFixture { fixture in
      // Two filters are ANDed, as the reference brackets them.
      let both = try await page(fixture, [.rowIDGreaterThan(3), .isFromMe(true)])
      #expect(both.guids.sorted() == ["MSG-0004", "MSG-0005"])
      #expect(both.total == 2)

      // And they narrow `requiresChat`, which is the query's own predicate rather than a
      // filter: the listing and the count have to agree about both at once, which is the
      // whole reason they share one `messagePredicate`.
      let withChats = try await page(fixture, [.isFromMe(true)], requiresChat: true)
      #expect(withChats.total == 3)
    }
  }

  @Test("a message in several chats is counted once")
  func noDuplicateRowsFromTheChatFilter() async throws {
    try await withFixture { fixture in
      // The chat filter is an EXISTS subquery, not a join, so a message belonging to more
      // than one chat cannot appear twice or inflate the total. A join here would need a
      // DISTINCT on every query to stay correct.
      try await fixture.addMessageToSecondChat(guid: "MSG-0001")
      let result = try await page(
        fixture, [.chatGUID(ChatDatabaseFixture.chatGUID("chat900001", service: "iMessage"))])
      #expect(result.guids.filter { $0 == "MSG-0001" }.count == 1)
      #expect(result.total == result.guids.count)
    }
  }
}

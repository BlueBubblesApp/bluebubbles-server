//  ChatOrderingPlanTests
//  A chat's transcript is ordered without sorting the chat.
//
//  `ORDER BY m.date` on a chat-scoped query has no index that also covers the chat, so SQLite
//  plans it as USE TEMP B-TREE FOR ORDER BY: for a 54,777-message conversation on a real
//  database, 54,777 random seeks into a 343MB table and a full sort, to return a hundred rows.
//  Measured at 45ms, against 1.4ms ordering by `chat_message_join.message_date`, which Apple's
//  own `chat_message_join_idx_message_date_id_chat_id` covers.
//
//  Two things make this testable rather than merely claimed. The fixtures now carry Apple's
//  real indexes, so the planner has something to choose between -- without them EXPLAIN QUERY
//  PLAN against a fixture is fiction. And the fixture's `message_date` now mirrors
//  `message.date` instead of being a literal zero in every row, which is what a real Mac
//  writes; with zeroes, every test of this ordering passed while proving nothing.
//
//  The repository does not assume the copy is trustworthy. It asks the database once and
//  falls back to `m.date` if any row's copy is zero or null, because sorting a message to the
//  wrong end of a transcript is a wrong answer rather than a slow one. Both paths are tested.

import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Chat transcript ordering")
struct ChatOrderingPlanTests {

  private func openFixture(_ name: String) throws -> (URL, URL) {
    guard
      let source = Bundle.module.url(
        forResource: "chat-\(name)", withExtension: "db", subdirectory: "ChatDBFixtures")
    else { throw Failure.fixtureMissing(name) }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-order-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("chat.db")
    try FileManager.default.copyItem(at: source, to: copy)
    return (copy, directory)
  }

  private enum Failure: Error { case fixtureMissing(String) }

  /// The guid of the direct chat the fixture seeds, read from the fixture rather than
  /// written down here, because the service prefix is a macOS-version detail.
  private func firstChatGUID(_ path: URL) throws -> String {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      try String.fetchOne(db, sql: "SELECT guid FROM chat WHERE ROWID = 1") ?? ""
    }
  }

  private func plan(_ path: URL, orderBy: String, guid: String) throws -> String {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      // `detail` by name, not the first column: EXPLAIN QUERY PLAN's first column is a row
      // id, and reading that gave two strings of digits that trivially failed to contain
      // "TEMP B-TREE" -- a test that could not fail, which is what the non-vacuity
      // expectation below exists to catch.
      try Row.fetchAll(
        db,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT m.ROWID FROM message m
          JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          JOIN chat c ON c.ROWID = cmj.chat_id
          WHERE c.guid IN (?) ORDER BY \(orderBy) DESC LIMIT 25
          """,
        arguments: [guid]
      ).map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
    }
  }

  /// The claim, stated as the planner states it.
  @Test("Ordering by the join's date removes the sort that ordering by the message's needs")
  func planLosesTheTempBTree() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)

    // Non-vacuity: if the old ordering ever stops needing a temp b-tree, this test is no
    // longer measuring anything and should be deleted rather than left passing.
    #expect(try plan(path, orderBy: "m.date", guid: guid).contains("TEMP B-TREE"))
    #expect(!(try plan(path, orderBy: "cmj.message_date", guid: guid).contains("TEMP B-TREE")))
  }

  /// Apple's indexes must be in the fixture, or the test above compares two plans made by a
  /// planner with nothing to choose from.
  @Test("The fixture carries the index the ordering depends on")
  func fixtureHasTheIndex() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: path.path)
    let names = try queue.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
    }
    #expect(names.contains("chat_message_join_idx_message_date_id_chat_id"))
  }

  /// The fixture's copy of the date has to agree with the message's, or ordering by it tests
  /// data no Mac produces. It was a literal zero in every row until this was written.
  @Test("The fixture's join dates mirror the message dates")
  func fixtureJoinDatesAreReal() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: path.path)
    let (disagreeing, distinct) = try queue.read { db in
      (
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.message_date IS NOT m.date
            """) ?? -1,
        try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT message_date) FROM chat_message_join")
          ?? -1
      )
    }
    #expect(disagreeing == 0)
    #expect(distinct > 1, "all-equal dates would order identically however they are sorted")
  }

  /// What the user sees must not change, whichever column got them there.
  @Test("The transcript comes back in the same order either way")
  func orderingIsUnchanged() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)

    let descending = try await repository.messages(
      MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0))
    let ascending = try await repository.messages(
      MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0, ascending: true))

    #expect(descending.count > 1)
    #expect(descending.map(\.rowID) == ascending.map(\.rowID).reversed())
    // Sorted by what it says it sorts by.
    let dates = descending.compactMap { $0.date?.rawValue }
    #expect(dates == dates.sorted(by: >))
  }

  /// A database whose copy of the date is not usable must fall back rather than mis-sort.
  /// This is the case that cannot be observed on this Mac, where all 417,332 rows agree.
  @Test("A zeroed message_date falls back to the message's own date")
  func zeroedJoinDatesFallBack() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)

    // Exactly what the fixtures used to ship, and what an unverified macOS might.
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(sql: "UPDATE chat_message_join SET message_date = 0")
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)
    #expect(await repository.joinDatesCanOrderAChat() == false)

    let rows = try await repository.messages(
      MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0))
    let dates = rows.compactMap { $0.date?.rawValue }
    #expect(rows.count > 1)
    // Still newest first, which ordering by the zeroed copy could not have managed.
    #expect(dates == dates.sorted(by: >))
  }

  /// The conversation list is the first thing a client draws, and it was 1.24 seconds of SQL.
  /// Most of that was this subquery reaching into `message` for a date the join already has.
  @Test("The chat list sorts on the join's date and gets the same order")
  func chatListOrderIsUnchanged() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)
    #expect(await repository.joinDatesCanOrderAChat())

    let sorted = try await repository.chats(sortByLastMessage: true)

    // The same answer computed the slow way, straight from the message table, as an
    // independent expectation rather than a second call to the code under test.
    let queue = try DatabaseQueue(path: path.path)
    let expected = try await queue.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT c.guid FROM chat c
          LEFT JOIN (
            SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY cmj.chat_id
          ) lm ON lm.chat_id = c.ROWID
          WHERE EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID)
          ORDER BY lm.last_date DESC
          """)
    }
    #expect(sorted.count > 1)
    #expect(sorted.map(\.guid) == expected)
  }

  /// Reading the date out of the join means the message table is not in the plan at all,
  /// which is where the 340ms went: one rowid seek per join row, 417,331 of them.
  @Test("The last-message subquery no longer touches the message table")
  func lastMessageSubqueryAvoidsMessages() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: path.path)

    func plan(_ sql: String) throws -> String {
      try queue.read { db in
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
          .map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
      }
    }
    let viaMessages = try plan(
      """
      SELECT cmj.chat_id, MAX(m.date) FROM chat_message_join cmj
      JOIN message m ON m.ROWID = cmj.message_id GROUP BY cmj.chat_id
      """)
    let viaJoin = try plan(
      """
      SELECT cmj.chat_id, MAX(cmj.message_date) FROM chat_message_join cmj GROUP BY cmj.chat_id
      """)
    // Non-vacuity first: the old form must really be reaching into `message`.
    #expect(viaMessages.contains("m"), "\(viaMessages)")
    #expect(viaMessages.lowercased().contains("search m") || viaMessages.contains("SCAN m"))
    #expect(!viaJoin.lowercased().contains("search m "), "\(viaJoin)")
    #expect(!viaJoin.contains("SCAN m"), "\(viaJoin)")
  }

  /// And the same fallback: a database whose copy is not usable sorts the list the slow,
  /// correct way.
  @Test("A zeroed message_date sorts the chat list from the message table")
  func chatListFallsBack() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(sql: "UPDATE chat_message_join SET message_date = 0")
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)
    #expect(await repository.joinDatesCanOrderAChat() == false)

    let sorted = try await repository.chats(sortByLastMessage: true)
    let expected = try await queue.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT c.guid FROM chat c
          LEFT JOIN (
            SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY cmj.chat_id
          ) lm ON lm.chat_id = c.ROWID
          WHERE EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID)
          ORDER BY lm.last_date DESC
          """)
    }
    #expect(sorted.map(\.guid) == expected)
  }

  // MARK: - Scoping by chat_id rather than by guid
  //
  // Ordering by `cmj.message_date` only removes the sort when SQLite can walk ONE chat's
  // slice of `chat_message_join_idx_message_date_id_chat_id`. `c.guid IN (?, ?, ?)` makes it
  // gather rows for several chats and sort the union -- and the candidate list is ALWAYS
  // three spellings, because `ChatGUID.lookupCandidates` adds `any;`, `iMessage;` and `SMS;`.
  //
  // So the first version of this fix removed the temp b-tree in the test, where a single
  // literal guid was used, and left it in place in production. Resolving the guid to chat
  // ROWIDs first and filtering `cmj.chat_id IN (...)` is what actually removes it: measured
  // on a 54,777-message conversation, 52ms against 1ms for the same hundred rows.

  @Test("A guid candidate list still sorts; a resolved chat_id does not")
  func resolvedChatIDRemovesTheSort() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue(path: path.path)

    func plan(_ sql: String, _ arguments: StatementArguments) throws -> String {
      try queue.read { db in
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
          .map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
      }
    }

    let guid = try firstChatGUID(path)
    let candidates = ChatGUID(guid)?.lookupCandidates() ?? [guid]
    // Non-vacuity: the production path really does pass more than one spelling.
    #expect(candidates.count > 1, "only \(candidates.count) candidate, so this proves nothing")

    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
    let viaGUID = try plan(
      """
      SELECT m.ROWID FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      WHERE c.guid IN (\(placeholders)) ORDER BY cmj.message_date DESC LIMIT 25
      """, StatementArguments(candidates))
    let viaChatID = try plan(
      """
      SELECT m.ROWID FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id IN (?) ORDER BY cmj.message_date DESC LIMIT 25
      """, StatementArguments([1]))

    #expect(viaGUID.contains("TEMP B-TREE"), "\(viaGUID)")
    #expect(!viaChatID.contains("TEMP B-TREE"), "\(viaChatID)")
  }

  /// The two scopings must return the same rows in the same order.
  @Test("Scoping by chat_id gives the same transcript as scoping by guid")
  func bothScopingsAgree() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)

    let resolved = await repository.chatRowIDs(for: guid)
    #expect(resolved?.isEmpty == false, "the guid resolved to nothing, so nothing was compared")

    let scopedByRowID = try await repository.messages(
      MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0))

    // The same query with resolution deliberately withheld, which is the path a database
    // whose guid resolves to nothing still takes.
    var byGUID = MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0)
    byGUID.resolvedChatRowIDs = nil
    let expected = try await repository.messagesWithoutResolution(byGUID)

    #expect(scopedByRowID.count > 1)
    #expect(scopedByRowID.map(\.rowID) == expected.map(\.rowID))
  }

  /// A chat in more than one row -- the same conversation under two spellings, which is what
  /// an older macOS looks like after a service change -- must behave the same either way.
  ///
  /// It does, INCLUDING a pre-existing bug this test pins rather than fixes: both paths
  /// return each message once PER CHAT ROW, so a conversation in two rows yields eight rows
  /// for four messages, while `messageCount` counts `DISTINCT m.ROWID` and answers four. A
  /// client sees `metadata.total` disagree with the page it came with. Not introduced here
  /// -- the guid-joined path multiplies identically -- and not fixed here either, because
  /// de-duplicating changes what clients on older macOS receive today and that is a wire
  /// decision rather than a performance one.
  @Test("A guid naming several chat rows behaves the same through either scoping")
  func multipleChatRowsAreAllIncluded() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)

    // A second chat row for the same conversation, under a legacy spelling, sharing the
    // first one's messages. This is what an older macOS looks like after a migration.
    // The other spelling, taken from the same resolver production uses, rather than by
    // string surgery: the fixture's own prefix is not knowable from here.
    let legacy = try #require(
      ChatGUID(guid)?.lookupCandidates().first { $0 != guid },
      "the guid has no alternative spelling, so there is nothing to duplicate")
    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO chat (guid, style, chat_identifier, service_name) VALUES (?, 45, 'x', 'iMessage')",
        arguments: [legacy])
      let newChat = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO chat_message_join (chat_id, message_id, message_date)
          SELECT ?, message_id, message_date FROM chat_message_join WHERE chat_id = 1
          """, arguments: [newChat])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)

    let resolved = await repository.chatRowIDs(for: guid)
    #expect((resolved?.count ?? 0) >= 2, "the second chat row was not resolved")

    let rows = try await repository.messages(
      MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0))
    var byGUID = MessageRepository.MessageQuery(chatGUID: guid, limit: 50, offset: 0)
    byGUID.resolvedChatRowIDs = nil
    let old = try await repository.messagesWithoutResolution(byGUID)

    #expect(rows.count > 1)
    #expect(rows.map(\.rowID) == old.map(\.rowID), "the two scopings disagree")
    // The pre-existing multiplication, pinned so that fixing it is a deliberate act rather
    // than a surprise: every message appears once per chat row it is joined to.
    #expect(rows.count == 2 * Set(rows.map(\.rowID)).count)
    #expect(
      try await repository.messageCount(.init(chatGUID: guid)) == Set(rows.map(\.rowID)).count,
      "the count is distinct where the page is not, which is the disagreement itself")
  }
}

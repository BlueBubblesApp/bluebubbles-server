//  RowIDWindowPlanTests
//  A small ROWID window is sorted, not found by walking the whole date index.
//
//  The incremental sync asks for `message.ROWID > n`, newest first, a thousand at a time.
//  Ordered by `m.date`, SQLite answers by walking `message_idx_date` from the newest entry and
//  testing each ROWID, and a window too small to fill the page never lets the walk stop: it
//  reads the entire index. On a 427,661-message database that is 1,803 pages, against 25 for
//  seeking the window and sorting it, to return the same 20 rows. The fixtures reproduce the
//  plan on every committed release, which is what lets the plan assertions here fail.
//
//  Three things are held: the decision (`MessageQueryPlan.sortsRowIDWindow`), the plan the
//  chosen statement gets, and that the rows come back in the same order either way. The
//  order is checked against a database whose dates disagree with its ROWIDs, as an iCloud
//  backfill leaves one, because on the committed fixture the two orders coincide and a sort
//  by ROWID would pass.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("ROWID window ordering", .removingChatDBCopies)
struct RowIDWindowPlanTests {

  private typealias Query = MessageRepository.MessageQuery

  private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) { lock.withLock { statements.append(sql) } }
    /// The listings, which are the only statements that select from `message` with an order.
    var listings: [String] {
      lock.withLock {
        statements.filter { $0.contains("FROM message m") && $0.contains("ORDER BY") }
      }
    }
  }

  private static func plan(_ path: URL, _ sql: String, _ arguments: StatementArguments) throws
    -> String
  {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
        .map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
    }
  }

  /// What the incremental sync sends: the window, newest first, a full page, with chats.
  private static func incremental(after rowID: Int64) -> Query {
    Query(limit: 1000, requiresChat: true, filters: [.rowIDGreaterThan(rowID)])
  }

  // MARK: - The decision

  @Test("A window that cannot fill the page is sorted")
  func smallWindowSorts() {
    // 20 new rows on a 427,661-row table: the walk could never collect 1,000 matches.
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 427_641, atMost: nil, maximumRowID: 427_661, offset: 0, limit: 1000))
    // Exactly a page, and an empty window past the end, which is how the client's loop ends.
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 426_661, atMost: nil, maximumRowID: 427_661, offset: 0, limit: 1000))
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 500_000, atMost: nil, maximumRowID: 427_661, offset: 0, limit: 1000))
  }

  @Test("A window the walk can fill early keeps the walk")
  func wideWindowWalks() {
    // 2,000 rows, first page: the walk stops after 1,000 and measured cheaper (307 pages
    // against 561).
    #expect(
      !MessageQueryPlan.sortsRowIDWindow(
        after: 425_661, atMost: nil, maximumRowID: 427_661, offset: 0, limit: 1000))
    // Everything, which is what a client with no saved marker would ask. Sorting the table
    // to return a thousand rows is the regression this must never introduce.
    #expect(
      !MessageQueryPlan.sortsRowIDWindow(
        after: 0, atMost: nil, maximumRowID: 427_661, offset: 0, limit: 1000))
  }

  @Test("The last page of a window is sorted, a deep page of a wide one is not")
  func pagingThroughAWindow() {
    // A 5,000-row window's fifth page: the walk needs 5,000 matches and the window holds no
    // more, so it would read the whole index. 5,000 is under the 1/64 bound for this table.
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 422_661, atMost: nil, maximumRowID: 427_661, offset: 4000, limit: 1000))
    // A 100,000-row window's last page: the sort would compute every column of 100,000 rows
    // where the walk fetches 1,000 after reading the index.
    #expect(
      !MessageQueryPlan.sortsRowIDWindow(
        after: 327_661, atMost: nil, maximumRowID: 427_661, offset: 99_000, limit: 1000))
  }

  @Test("An upper bound narrows the window, and one past the end is the end")
  func upperBound() {
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 100_000, atMost: 100_500, maximumRowID: 427_661, offset: 0, limit: 1000))
    #expect(
      MessageQueryPlan.sortsRowIDWindow(
        after: 427_641, atMost: 9_999_999, maximumRowID: 427_661, offset: 0, limit: 1000))
  }

  @Test("Only an unscoped, undated query with a lower bound has a window")
  func whichQueriesHaveAWindow() {
    let plan = MessageQueryPlan(dateUnit: .nanoseconds)

    let window = plan.rowIDWindow(
      Query(
        filters: [.rowIDGreaterThan(5), .rowIDGreaterThan(9), .rowIDAtMost(40)],
        minRowID: 3, maxRowID: 30))
    // The intersection: the larger exclusive floor, the smaller inclusive ceiling.
    #expect(window?.after == 9)
    #expect(window?.atMost == 30)
    // `minRowId` is inclusive, so the window starts one below it.
    #expect(plan.rowIDWindow(Query(minRowID: 10))?.after == 9)

    #expect(plan.rowIDWindow(Query(filters: [.rowIDAtMost(40)])) == nil)
    #expect(plan.rowIDWindow(Query(chatGUID: "chat000000000000000001", minRowID: 3)) == nil)
    #expect(plan.rowIDWindow(Query(after: Date(), filters: [.rowIDGreaterThan(5)])) == nil)
  }

  // MARK: - The statement and its plan

  @Test(
    "The incremental sync's listing seeks the window instead of scanning the date index",
    arguments: CommittedChatDB.Release.allCases)
  func incrementalListingSeeksTheWindow(release: CommittedChatDB.Release) async throws {
    let path = try CommittedChatDB.copy(release)
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: path.path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)

    let query = Self.incremental(after: 3)
    let rows = try await repository.messages(query)
    #expect(!rows.isEmpty)

    let ran = try #require(log.listings.last)
    #expect(ran.contains("ORDER BY +m.date DESC"))

    // The plan, asked of the same statement shape with the walking order beside it. The
    // walking plan's scan is the non-vacuity check: if the planner ever stops choosing it,
    // this test no longer measures anything and should be deleted.
    let condition =
      "WHERE m.ROWID > ? AND EXISTS "
      + "(SELECT 1 FROM chat_message_join cmj2 WHERE cmj2.message_id = m.ROWID)"
    let walking = try Self.plan(
      path, "SELECT m.ROWID FROM message m \(condition) ORDER BY m.date DESC LIMIT 1000",
      [3])
    let sorting = try Self.plan(
      path, "SELECT m.ROWID FROM message m \(condition) ORDER BY +m.date DESC LIMIT 1000",
      [3])
    #expect(walking.contains("SCAN m USING") && walking.contains("message_idx_date"))
    #expect(sorting.contains("SEARCH m USING INTEGER PRIMARY KEY"))
    #expect(!sorting.contains("message_idx_date"))
  }

  @Test("A window from the start of the table keeps the walking order")
  func wholeTableKeepsTheWalk() async throws {
    let path = try CommittedChatDB.copy(.sequoia)
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: path.path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)

    // Two rows to a page over a seven-row table: the window is wider than the page, so the
    // walk can stop.
    _ = try await repository.messages(
      Query(limit: 2, filters: [.rowIDGreaterThan(0)]))
    let ran = try #require(log.listings.last)
    #expect(ran.contains("ORDER BY m.date DESC"))
    #expect(!ran.contains("+m.date"))
  }

  // MARK: - The answer

  @Test("Rows come back by date, not by ROWID, whichever statement ran")
  func orderIsByDate() async throws {
    let path = try CommittedChatDB.copy(.sequoia)
    // A backfilled row: the highest ROWID carries the oldest date in the window, which is
    // what iCloud leaves behind. Written to the copy before the reader opens.
    let writer = try DatabaseQueue(path: path.path)
    try await writer.write { db in
      let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(date) FROM message") ?? 0
      try db.execute(
        sql: "UPDATE message SET date = ? WHERE ROWID = (SELECT MAX(ROWID) FROM message)",
        arguments: [oldest - 1])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)

    let window = try await repository.messages(Self.incremental(after: 3))
    // The same rows the slow way: every message, ordered by the walking plan, then filtered.
    let everything = try await repository.messages(
      Query(limit: 1000, requiresChat: true))
    let expected = everything.filter { $0.rowID > 3 }.map(\.rowID)

    #expect(window.count > 1)
    #expect(window.map(\.rowID) == expected)
    let dates = window.compactMap { $0.date?.rawValue }
    #expect(dates == dates.sorted(by: >))
    // The backfilled row is LAST, which a ROWID order would have put first.
    #expect(window.last?.rowID == window.map(\.rowID).max())

    let total = try await repository.messageCount(Self.incremental(after: 3))
    #expect(total == window.count)
  }
}

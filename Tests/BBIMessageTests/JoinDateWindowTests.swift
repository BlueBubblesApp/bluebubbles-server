//  JoinDateWindowTests
//  A date window on one conversation is answered from the join's copy of the date.
//
//  A full sync asks every conversation for its messages with `after` and `before`, and the
//  total beside each page counted through the message table: every message row in the chat,
//  34,545 pages for a 55,795-message conversation, to return one message. A narrow window on
//  the listing was the same walk from the other end. `chat_message_join` carries its own
//  copy of the date and Apple indexes it with the chat (`chat_message_join_idx_message_date_id_chat_id`),
//  so the count reads 334 pages and the listing 28.
//
//  Held here: the counts are exact at both inclusive edges, the listing's statement windows
//  the join AND still windows `m.date`, the plan seeks the join's range, and a database
//  whose copy of the date is zeroed falls back to the message table with the same answers.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Date windows on a conversation", .removingChatDBCopies)
struct JoinDateWindowTests {

  private typealias Query = MessageRepository.MessageQuery

  private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) { lock.withLock { statements.append(sql) } }
    var all: [String] { lock.withLock { statements } }
  }

  // The fixture's first chat holds messages 1, 2, 3 and 5, a minute apart from this
  // instant. Message 4 is in the other chat, between 3 and 5.
  private static let second = Date(timeIntervalSinceReferenceDate: 738_936_060)
  private static let third = Date(timeIntervalSinceReferenceDate: 738_936_120)

  private struct Harness {
    let repository: MessageRepository
    let log: StatementLog
    let guid: String
    let path: URL
  }

  /// - Parameter zeroingJoinDates: writes `message_date = 0` into the copy first, which is
  ///   what an untrustworthy copy looks like to `joinDatesCanOrderAChat`.
  private func harness(zeroingJoinDates: Bool = false) async throws -> Harness {
    let path = try CommittedChatDB.copy(.sequoia)
    let writer = try DatabaseQueue(path: path.path)
    let guid = try await writer.write { db in
      if zeroingJoinDates {
        try db.execute(sql: "UPDATE chat_message_join SET message_date = 0")
      }
      return try String.fetchOne(db, sql: "SELECT guid FROM chat WHERE ROWID = 1") ?? ""
    }
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: path.path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    return Harness(
      repository: MessageRepository(database: database, profile: profile), log: log,
      guid: guid, path: path)
  }

  private func plan(_ path: URL, _ sql: String) throws -> String {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql)
        .map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
    }
  }

  // MARK: - Counts

  @Test("A window's count is exact at both inclusive edges", arguments: [false, true])
  func countsAreExact(zeroingJoinDates: Bool) async throws {
    let harness = try await harness(zeroingJoinDates: zeroingJoinDates)
    let repository = harness.repository
    let guid = harness.guid

    // Messages 2 and 3: the window starts on one and ends on the other.
    #expect(
      try await repository.messageCount(
        Query(chatGUID: guid, after: Self.second, before: Self.third))
        == 2)
    // Messages 3 and 5, and NOT 4, which falls inside the window in another chat.
    #expect(try await repository.messageCount(Query(chatGUID: guid, after: Self.third)) == 2)
    // Messages 1 and 2.
    #expect(try await repository.messageCount(Query(chatGUID: guid, before: Self.second)) == 2)

    // Which table answered: the join when its copy is usable, the message table when not.
    let counts = harness.log.all.filter { $0.contains("COUNT(") }
    #expect(!counts.isEmpty)
    if zeroingJoinDates {
      #expect(counts.allSatisfy { !$0.contains("cmj.message_date") })
    } else {
      #expect(counts.allSatisfy { $0.contains("FROM chat_message_join cmj") })
      #expect(counts.allSatisfy { $0.contains("cmj.message_date") })
    }
  }

  // MARK: - Listing

  @Test("A window's page holds the same rows whichever date windowed it", arguments: [false, true])
  func listingRowsAreTheSame(zeroingJoinDates: Bool) async throws {
    let harness = try await harness(zeroingJoinDates: zeroingJoinDates)
    let rows = try await harness.repository.messages(
      Query(chatGUID: harness.guid, after: Self.second, before: Self.third))
    #expect(rows.map(\.rowID) == [3, 2])

    let older = try await harness.repository.messages(
      Query(chatGUID: harness.guid, before: Self.second, ascending: true))
    #expect(older.map(\.rowID) == [1, 2])

    let listings = harness.log.all.filter {
      $0.contains("FROM message m") && $0.contains("ORDER BY")
    }
    let ran = try #require(listings.last)
    // The `m.date` window is ALWAYS there: it is what decides the rows.
    #expect(ran.contains("m.date <= ?"))
    #expect(ran.contains("cmj.message_date <= ?") == !zeroingJoinDates)
  }

  /// The plan the windowed listing gets, with the plan it had beside it.
  @Test("Windowing the join lets the listing seek the chat's date range")
  func listingSeeksTheRange() async throws {
    let harness = try await harness()
    let base = """
      SELECT m.ROWID FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id = 1 AND (m.date >= 0 AND m.date <= 1)
      """
    let before = try plan(harness.path, base + " ORDER BY cmj.message_date DESC LIMIT 25")
    let after = try plan(
      harness.path,
      base + " AND (cmj.message_date >= 0 AND cmj.message_date <= 1)"
        + " ORDER BY cmj.message_date DESC LIMIT 25")

    // Non-vacuity: without the join's window the seek is on the chat alone, and every row of
    // the chat is a candidate.
    #expect(before.contains("(chat_id=?)"), "\(before)")
    #expect(after.contains("(chat_id=? AND message_date>? AND message_date<?)"), "\(after)")
    #expect(!after.contains("TEMP B-TREE"), "\(after)")
  }
}

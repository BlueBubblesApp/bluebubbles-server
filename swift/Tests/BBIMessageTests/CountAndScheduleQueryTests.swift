//  CountAndScheduleQueryTests
//  Two queries whose cost was entirely a question of which index the planner could reach.
//
//  Send Later asked `schedule_type != 0`. Apple ships `message_idx_is_scheduled_message`, a
//  PARTIAL index over `(schedule_type, rowid) WHERE schedule_type = 2`, and only an equality
//  test on the leading column reaches it -- `!=`, `>` and `IN` all fall back to scanning every
//  row. Measured against the real 421,071-message database: 200ms to under a millisecond.
//
//  The total that accompanies every page of a conversation counted `DISTINCT m.ROWID` across
//  the message join, which is a rowid seek per row plus a temp b-tree, to answer a question no
//  column of `message` takes part in: 42ms on a 54,777-message chat, against 2ms counting the
//  join alone. It cost more than the page it accompanied.
//
//  Both are plan changes, so both are asserted as plans -- against fixtures that now carry
//  Apple's real indexes -- as well as by the answers staying the same.

import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Count and schedule queries")
struct CountAndScheduleQueryTests {

  private func openFixture(_ name: String) throws -> (URL, URL) {
    guard
      let source = Bundle.module.url(
        forResource: "chat-\(name)", withExtension: "db", subdirectory: "ChatDBFixtures")
    else { throw Failure.fixtureMissing(name) }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-count-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("chat.db")
    try FileManager.default.copyItem(at: source, to: copy)
    return (copy, directory)
  }

  private enum Failure: Error { case fixtureMissing(String) }

  private func plan(_ path: URL, _ sql: String) throws -> String {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      // `detail` by name: EXPLAIN QUERY PLAN's first column is a row id, and reading that
      // gives a string of digits that trivially contains nothing you look for.
      try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)")
        .map { ($0["detail"] as String?) ?? "" }.joined(separator: "\n")
    }
  }

  private func repository(_ path: URL) async throws -> MessageRepository {
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    return MessageRepository(database: database, profile: profile)
  }

  private func firstChatGUID(_ path: URL) throws -> String {
    let queue = try DatabaseQueue(path: path.path)
    return try queue.read { db in
      try String.fetchOne(db, sql: "SELECT guid FROM chat WHERE ROWID = 1") ?? ""
    }
  }

  // MARK: - Send Later

  /// The value is Apple's, not ours: their partial index is keyed on `schedule_type = 2`,
  /// which is the strongest evidence that 2 is the only type Send Later writes.
  @Test("The Send Later type matches the Private API contract's value")
  func scheduleTypeMatchesTheContract() {
    // `ScheduledSend.type` in BBPrivateAPIContract, which this module deliberately does not
    // depend on -- the chat.db read path has to work with the Private API absent.
    #expect(MessageRepository.sendLaterScheduleType == 2)
  }

  @Test("Equality reaches the partial index that inequality cannot")
  func equalityTakesThePartialIndex() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }

    let equality = try plan(
      path, "SELECT m.ROWID FROM message m WHERE m.schedule_type = 2 LIMIT 500")
    let inequality = try plan(
      path, "SELECT m.ROWID FROM message m WHERE m.schedule_type != 0 LIMIT 500")

    #expect(equality.contains("message_idx_is_scheduled_message"), "\(equality)")
    // Non-vacuity: the form this replaced really could not reach it.
    #expect(!inequality.contains("message_idx_is_scheduled_message"), "\(inequality)")
  }

  /// The answers must not change. The fixture seeds no scheduled message, so this asserts
  /// the pending list is empty rather than erroring -- the shape of the query, on a schema
  /// that has the columns.
  @Test("The pending list still runs and answers on a schema that has the columns")
  func pendingListRuns() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try await repository(path)
    #expect(repository.supportsScheduledMessages)
    #expect(try await repository.pendingScheduledMessages().isEmpty)
  }

  // MARK: - The conversation total

  @Test("Counting a whole conversation does not touch the message table")
  func wholeChatCountAvoidsMessages() throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }

    let viaMessages = try plan(
      path,
      """
      SELECT COUNT(DISTINCT m.ROWID) FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id WHERE c.guid IN ('x')
      """)
    let viaJoin = try plan(
      path,
      """
      SELECT COUNT(DISTINCT cmj.message_id) FROM chat_message_join cmj
      JOIN chat c ON c.ROWID = cmj.chat_id WHERE c.guid IN ('x')
      """)

    // Non-vacuity first: the old form really did reach into `message`.
    #expect(viaMessages.contains("SEARCH m ") || viaMessages.contains("SCAN m"), "\(viaMessages)")
    #expect(!viaJoin.contains("SEARCH m "), "\(viaJoin)")
    #expect(!viaJoin.contains("SCAN m"), "\(viaJoin)")
  }

  /// The whole point: the two shapes must agree. Every query here that is NOT a whole chat
  /// takes the old path, so this also proves the switch picks the right one.
  @Test("Both count shapes give the same answer, for every query shape")
  func countsAgree() async throws {
    let (path, directory) = try openFixture("sequoia")
    defer { try? FileManager.default.removeItem(at: directory) }
    let guid = try firstChatGUID(path)
    let repository = try await repository(path)

    let epoch = Date(timeIntervalSince1970: 0)
    let future = Date(timeIntervalSince1970: 4_000_000_000)

    let queries: [(String, MessageRepository.MessageQuery)] = [
      ("whole chat", .init(chatGUID: guid)),
      ("chat and a window", .init(chatGUID: guid, after: epoch, before: future)),
      ("chat, from me only", .init(chatGUID: guid, onlyFromMe: true)),
      ("chat and a row-id floor", .init(chatGUID: guid, minRowID: 1)),
      ("no chat at all", .init()),
    ]

    for (name, query) in queries {
      let counted = try await repository.messageCount(query)
      // Computed independently, the slow way, straight from the message table.
      let expected = try await repository.messageCount(query, countingTheJoinWherePossible: false)
      #expect(counted == expected, "\(name): \(counted) != \(expected)")
      // Two zeroes agree with each other and prove nothing.
      #expect(counted > 0, "\(name) counted nothing, so the comparison was vacuous")
    }
  }

  /// And the switch itself: only the first of those takes the fast path.
  @Test("Only a whole-conversation query takes the join-only count")
  func onlyAWholeChatTakesTheFastPath() {
    let guid = "any;-;someone@example.com"
    #expect(MessageRepository.MessageQuery(chatGUID: guid).countsAWholeChat)
    #expect(!MessageRepository.MessageQuery().countsAWholeChat)
    #expect(
      !MessageRepository.MessageQuery(chatGUID: guid, after: Date()).countsAWholeChat)
    #expect(
      !MessageRepository.MessageQuery(chatGUID: guid, before: Date()).countsAWholeChat)
    #expect(!MessageRepository.MessageQuery(chatGUID: guid, onlyFromMe: true).countsAWholeChat)
    #expect(!MessageRepository.MessageQuery(chatGUID: guid, minRowID: 1).countsAWholeChat)
    #expect(!MessageRepository.MessageQuery(chatGUID: guid, maxRowID: 1).countsAWholeChat)
  }
}

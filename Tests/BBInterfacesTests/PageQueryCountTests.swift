//  PageQueryCountTests
//  A page of messages costs a fixed number of queries, not a number that grows with the page.
//
//  Relations were fetched per message: a handle lookup, a chats query and an attachments query
//  EACH, so a 1000-row page ran 3,000 statements. Measured at 143ms, 1.6 times the cost of
//  fetching the rows themselves, and all of it serialised through the single database queue,
//  so it head-of-line blocked every other client for the duration.
//
//  No assertion in the suite could see that. The answers were right and the tests were fast,
//  because the fixture has seven messages. So this counts STATEMENTS, and states the property
//  as a comparison rather than a number: projecting one row and projecting the whole page must
//  cost the same, whatever that cost happens to be. A constant would have to be rewritten
//  whenever a relation was added, and the number is not the point -- the shape is.

import BBCore
import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Page query count")
struct PageQueryCountTests {

  /// Counts every statement the database runs, from any thread.
  private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) { lock.withLock { statements.append(sql) } }
    var count: Int { lock.withLock { statements.count } }
    func reset() { lock.withLock { statements.removeAll() } }
    var all: [String] { lock.withLock { statements } }
  }

  /// - Returns: the repository, the statement log, and the writable connection the fixture
  ///   copy needs held open. See `ChatFixtureCopy`.
  private func open() async throws -> (
    MessageRepository, SchemaProfile, StatementLog, DatabaseQueue
  ) {
    let (path, writer) = try ChatFixtureCopy.make()
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return (MessageRepository(database: database, profile: profile), profile, log, writer)
  }

  @Test("Projecting a page costs the same number of queries as projecting one row")
  func queryCountDoesNotGrowWithThePage() async throws {
    let (repository, profile, log, writer) = try await open()
    // Held for the life of the test: releasing it lets SQLite remove the WAL sidecars the
    // read-only connection depends on.
    defer { withExtendedLifetime(writer) {} }

    let interface = MessageInterface(
      repository: repository, serializer: MessageSerializer(profile: profile),
      privateAPI: nil)
    let rows = try await repository.messages(
      MessageRepository.MessageQuery(limit: 100, offset: 0))
    // The fixture has to hold more than one message, or "one row" and "the page" are the
    // same thing and this test cannot fail.
    #expect(rows.count > 1, "the fixture has \(rows.count) messages")

    let query = MessageInterface.Query(
      withChats: true, withAttachments: true, withHandle: true)

    log.reset()
    _ = try await interface.project(Array(rows.prefix(1)), query: query)
    let forOneRow = log.count

    log.reset()
    _ = try await interface.project(rows, query: query)
    let forThePage = log.count

    #expect(forOneRow > 0, "nothing was queried, so nothing was measured")
    #expect(
      forThePage == forOneRow,
      "\(rows.count) rows cost \(forThePage) queries where one row cost \(forOneRow)")
  }

  /// The answers must be identical to the per-message loads they replaced, which still exist
  /// and are still used for single-message paths.
  @Test("Batched relations match what the per-message queries return")
  func batchedRelationsMatch() async throws {
    let (repository, _, _, writer) = try await open()
    defer { withExtendedLifetime(writer) {} }

    let rows = try await repository.messages(
      MessageRepository.MessageQuery(limit: 100, offset: 0))
    #expect(rows.count > 1)

    let chats = try await repository.chats(forMessageGUIDs: rows.map(\.guid))
    let attachments = try await repository.attachments(forMessageGUIDs: rows.map(\.guid))
    let handles = try await repository.handles(rowIDs: rows.compactMap(\.handleID))

    var sawAChat = false
    var sawAnAttachment = false
    var sawAHandle = false
    for row in rows {
      let expectedChats = try await repository.chats(forMessageGUID: row.guid)
      #expect((chats[row.guid] ?? []).map(\.guid) == expectedChats.map(\.guid), "chats")
      sawAChat = sawAChat || !expectedChats.isEmpty

      let expectedAttachments = try await repository.attachments(forMessageGUID: row.guid)
      #expect(
        (attachments[row.guid] ?? []).map(\.guid) == expectedAttachments.map(\.guid),
        "attachments")
      sawAnAttachment = sawAnAttachment || !expectedAttachments.isEmpty

      if let handleID = row.handleID {
        let expected = try await repository.handle(rowID: handleID)
        #expect(handles[handleID]?.id == expected?.id, "handle")
        sawAHandle = sawAHandle || expected != nil
      }
    }
    // Comparing empties against empties would pass whatever the batch did.
    #expect(sawAChat, "no message in the fixture belonged to a chat")
    #expect(sawAnAttachment, "no message in the fixture had an attachment")
    #expect(sawAHandle, "no message in the fixture had a handle")
  }
}

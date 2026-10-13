//  AuditRepositoryTests
//  The one path to the `audit_event` table: what a page holds, in what order, and what the
//  sweep removes.
//
//  Order is the contract the page and the receiver both rely on: newest first for the page,
//  oldest first for the export, and a filter that answers with the rows AND the total from
//  the same read, so the pager never describes a table the sweep has shrunk.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBAudit

@Suite("Audit repository")
struct AuditRepositoryTests {

  private func makeRepository() throws -> AuditRepository {
    AuditRepository(database: try AppDatabase.inMemory(contributors: [AuditSchema.self]))
  }

  private func event(
    _ kind: AuditEventKind, at seconds: TimeInterval, outcome: AuditOutcome = .success,
    summary: String = "x", actor: AuditActor = .operator
  ) -> AuditEvent {
    AuditEvent(
      kind: kind, outcome: outcome, actor: actor, summary: summary,
      occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
  }

  @Test("Inserting assigns row ids and reads back the same record")
  func insertAssignsIDs() async throws {
    let repository = try makeRepository()
    let stored = try await repository.insert([
      event(.settingsChanged, at: 1, summary: "first"),
      event(.serviceStarted, at: 2, summary: "second"),
    ])
    #expect(stored.map(\.id) == [1, 2])
    let found = try await repository.find(id: 2)
    #expect(found?.summary == "second")
    #expect(found?.uuid == stored[1].uuid)
    #expect(try await repository.count() == 2)
  }

  @Test("Metadata survives storage with its types")
  func metadataRoundTrips() async throws {
    let repository = try makeRepository()
    let original = AuditEvent(
      kind: .apiRequest, summary: "x",
      metadata: ["status": .int(200), "authenticated": .bool(true), "handler": .string("h")])
    _ = try await repository.insert([original])
    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.events.first?.metadata == original.metadata)
  }

  @Test("A page is newest first and carries the total of what matches")
  func pageIsNewestFirst() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert(
      (1...5).map { event(.apiRequest, at: Double($0), summary: "\($0)") })

    let first = try await repository.page(limit: 2, offset: 0)
    #expect(first.total == 5)
    #expect(first.events.map(\.summary) == ["5", "4"])

    let last = try await repository.page(limit: 2, offset: 4)
    #expect(last.events.map(\.summary) == ["1"])
  }

  @Test("Two records at the same instant are ordered by row id, newest first")
  func tiesBreakOnRowID() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([
      event(.apiRequest, at: 1, summary: "a"), event(.apiRequest, at: 1, summary: "b"),
    ])
    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.events.map(\.summary) == ["b", "a"])
  }

  @Test("Filters narrow the rows and the total together")
  func filtersApply() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([
      event(.credentialRejected, at: 1, outcome: .denied, actor: .client(address: "203.0.113.9")),
      event(.settingsChanged, at: 2),
      event(.serviceFailed, at: 3, outcome: .failure),
    ])

    var byCategory = AuditQuery()
    byCategory.categories = [.authentication]
    let auth = try await repository.page(byCategory, limit: 10, offset: 0)
    #expect(auth.total == 1)
    #expect(auth.events.map(\.kind) == [.credentialRejected])

    var byOutcome = AuditQuery()
    byOutcome.outcomes = [.denied, .failure]
    let notOK = try await repository.page(byOutcome, limit: 10, offset: 0)
    #expect(notOK.total == 2)

    var byActor = AuditQuery()
    byActor.actorKinds = ["client"]
    #expect(try await repository.page(byActor, limit: 10, offset: 0).total == 1)
  }

  @Test("Search matches the summary, the actor and the subject, and escapes wildcards")
  func searchMatches() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([
      AuditEvent(
        kind: .clientBlocked, actor: .system(component: "access-control"),
        subject: .client("203.0.113.9"), summary: "203.0.113.9 was blocked."),
      AuditEvent(kind: .settingsChanged, summary: "The setting 100% was changed."),
      AuditEvent(kind: .settingsChanged, summary: "The setting 1000 was changed."),
    ])

    var query = AuditQuery()
    query.search = "113.9"
    #expect(try await repository.page(query, limit: 10, offset: 0).total == 1)

    query.search = "ACCESS-CONTROL"
    #expect(try await repository.page(query, limit: 10, offset: 0).total == 1, "case-insensitive")

    // A per cent sign is a character, not a wildcard: without the escape it would match the
    // third row too.
    query.search = "100%"
    #expect(try await repository.page(query, limit: 10, offset: 0).total == 1)

    query.search = "nothing-like-this"
    let none = try await repository.page(query, limit: 10, offset: 0)
    #expect(none.total == 0)
    #expect(none.events.isEmpty)
  }

  @Test("The export walk is oldest first, in pages, and covers every row exactly once")
  func forEachPageWalksOldestFirst() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert(
      (1...7).map { event(.apiRequest, at: Double($0), summary: "\($0)") })

    var seen: [String] = []
    var pages = 0
    try await repository.forEachPage(pageSize: 3) { page in
      pages += 1
      seen += page.map(\.summary)
    }
    #expect(seen == ["1", "2", "3", "4", "5", "6", "7"])
    #expect(pages == 3)
  }

  @Test("A filtered walk sees only what matches")
  func forEachPageFilters() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([
      event(.serviceStarted, at: 1), event(.apiRequest, at: 2), event(.serviceStopped, at: 3),
    ])
    var query = AuditQuery()
    query.categories = [.service]
    var kinds: [AuditEventKind] = []
    try await repository.forEachPage(matching: query, pageSize: 10) { kinds += $0.map(\.kind) }
    #expect(kinds == [.serviceStarted, .serviceStopped])
  }

  @Test("The sweep removes what is older than the cutoff and says how many")
  func deleteOlderThan() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert((1...4).map { event(.apiRequest, at: Double($0)) })
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000 + 2.5)
    let removed = try await repository.deleteOlderThan(cutoff)
    #expect(removed == 2)
    #expect(try await repository.count() == 2)
    #expect(try await repository.deleteOlderThan(cutoff) == 0)
  }

  /// One `DELETE` over a large backlog holds `app.db`'s only writer for as long as it runs;
  /// the sweep works in batches so every other writer gets a turn between them.
  @Test("The sweep removes a backlog in batches, oldest first, and counts all of it")
  func deleteInBatches() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert((1...10).map { event(.apiRequest, at: Double($0)) })
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000 + 7.5)
    #expect(try await repository.deleteOlderThan(cutoff, batchSize: 3) == 7)
    let left = try await repository.page(limit: 10, offset: 0).events.map(\.occurredAt)
    #expect(left.map { $0.timeIntervalSince1970 - 1_700_000_000 } == [10, 9, 8])
  }

  /// Stopping the audit log cancels the sweep; it stops between batches rather than holding
  /// the stop for a backlog, and reports only what it removed.
  @Test("A cancelled sweep stops and reports what it removed")
  func cancelledSweepStops() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert((1...4).map { event(.apiRequest, at: Double($0)) })
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000 + 10)
    let sweep = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await repository.deleteOlderThan(cutoff, batchSize: 1)
    }
    #expect(try await sweep.value == 0)
    #expect(try await repository.count() == 4)
  }

  /// The case the test above cannot reach: cancelled WHILE batches are running.
  ///
  /// The database refuses a write from a cancelled task, so a cancellation landing during a
  /// batch threw out of the loop, and the rows already removed went unreported: deleted,
  /// with no `audit.retention_applied` saying so. Cancelled here once the sweep has
  /// demonstrably started.
  @Test("A sweep cancelled part-way reports the rows it had already removed")
  func sweepCancelledPartWay() async throws {
    let repository = try makeRepository()
    let rows = 2_000
    _ = try await repository.insert((1...rows).map { event(.apiRequest, at: Double($0)) })
    let cutoff = Date(timeIntervalSince1970: 1_700_000_000 + Double(rows) + 1)
    let sweep = Task { try await repository.deleteOlderThan(cutoff, batchSize: 1) }
    // A tight interval: the cancellation has to land while batches are still running.
    try await waitUntil("the sweep to start", interval: .milliseconds(1)) {
      try await repository.count() < rows
    }
    sweep.cancel()

    let removed = try await sweep.value
    let left = try await repository.count()
    #expect(removed == rows - left, "reported \(removed), removed \(rows - left)")
    #expect(left > 0, "the sweep finished before the cancellation landed; this run proved nothing")
  }

  /// The page filtered by category reads the last hundred entries of an index ordered by time
  /// within the category, rather than sorting every row of the category: 906 ms became 20 ms
  /// at a million rows. Asserted as the PLAN, because an index SQLite does not choose is only
  /// a cost, and a later index or a changed query could quietly take its place.
  @Test("A category-filtered page reads the category-by-time index, with no sort")
  func categoryPageUsesTheIndex() async throws {
    let database = try AppDatabase.inMemory(contributors: [AuditSchema.self])
    var query = AuditQuery()
    query.categories = [.authentication]
    let clause = query.whereClause()
    let (plan, indexes) = try await database.read { db in
      let plan = try Row.fetchAll(
        db, sql: "EXPLAIN QUERY PLAN " + AuditRepository.pageSQL(where: clause.sql),
        arguments: clause.arguments + StatementArguments([100, 0])
      ).map { $0["detail"] as String }
      let indexes = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'audit_event'")
      return (plan, indexes)
    }
    #expect(
      plan.contains { $0.contains("index_audit_event_on_category_occurred_at_id") }, "\(plan)")
    #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "the page sorts: \(plan)")
    // Subsumed by the new index, which SQLite chose over it; kept, it was 12 bytes a row.
    #expect(!indexes.contains("audit_event_on_category"))
  }

  /// An actor this build cannot name is nobody, not the person at the Mac: a newer server's
  /// actor kind must not turn into an accusation on a downgrade.
  @Test("An unattributed record round-trips, and an unknown actor kind reads as unattributed")
  func unattributedRoundTrips() async throws {
    let database = try AppDatabase.inMemory(contributors: [AuditSchema.self])
    let repository = AuditRepository(database: database)
    _ = try await repository.insert([
      event(.settingsChanged, at: 1, actor: .unattributed),
      event(.settingsChanged, at: 2, actor: .operator),
    ])
    try await database.write { db in
      try db.execute(sql: "UPDATE audit_event SET actor_kind = 'future-kind' WHERE id = 2")
    }
    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.events.map(\.actor) == [.unattributed, .unattributed])
    #expect(page.events.first { $0.id == 1 }?.source == .unknown)
  }

  // MARK: - A row this version cannot read

  /// A repository whose second of `count` rows was written by a newer server: a kind this
  /// build does not know.
  private func repositoryWithAFutureRow(count: Int = 5) async throws -> AuditRepository {
    let database = try AppDatabase.inMemory(contributors: [AuditSchema.self])
    let repository = AuditRepository(database: database)
    _ = try await repository.insert((1...count).map { event(.apiRequest, at: Double($0)) })
    try await database.write { db in
      try db.execute(sql: "UPDATE audit_event SET kind = 'future.kind' WHERE id = 2")
    }
    return repository
  }

  /// One row a downgraded server cannot read must not hide every row around it, and must not
  /// vanish silently either: the page says how many it could not show.
  @Test("A page skips a row this version cannot read and counts it")
  func pageCountsUnreadable() async throws {
    let repository = try await repositoryWithAFutureRow()
    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.events.count == 4)
    #expect(page.unreadable == 1)
    #expect(page.total == 5)
  }

  /// An outcome or an identifier this build cannot read is not given one. Read as `.success`
  /// and as a fresh UUID, a forensic record showed a refusal as a success under an id that
  /// matched nothing else.
  @Test(
    "An unreadable outcome or uuid makes the row unreadable, not a guess",
    arguments: [
      "UPDATE audit_event SET outcome = 'future-outcome' WHERE id = 2",
      "UPDATE audit_event SET uuid = 'not-a-uuid' WHERE id = 2",
    ])
  func unreadableFactsAreNotInvented(_ damage: String) async throws {
    let database = try AppDatabase.inMemory(contributors: [AuditSchema.self])
    let repository = AuditRepository(database: database)
    _ = try await repository.insert((1...3).map { event(.apiRequest, at: Double($0)) })
    try await database.write { db in try db.execute(sql: damage) }

    let page = try await repository.page(limit: 10, offset: 0)
    #expect(page.events.map(\.id) == [3, 1])
    #expect(page.unreadable == 1)
  }

  /// The keyset cursor follows the rows, so an unreadable row at a page boundary is passed
  /// over rather than ending the walk or being read again.
  @Test("A walk skips a row this version cannot read, counts it and carries on")
  func walkCountsUnreadable() async throws {
    let repository = try await repositoryWithAFutureRow()
    var seen: [Int64] = []
    let unreadable = try await repository.forEachPage(pageSize: 2) { page in
      seen += page.compactMap(\.id)
    }
    #expect(seen == [1, 3, 4, 5])
    #expect(unreadable == 1)
  }

  @Test("An export leaves an unreadable row out and says so")
  func exportCountsUnreadable() async throws {
    let repository = try await repositoryWithAFutureRow()
    let url = FileManager.default.temporaryDirectory
      .appending(path: "audit-export-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: url) }
    let export = try await AuditCSVExporter(repository: repository).export(to: url)
    #expect(export.written == 4)
    #expect(export.unreadable == 1)
  }

  @Test("The follow stream opens with the current version and moves on every insert")
  func changesStream() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([event(.apiRequest, at: 1)])

    var iterator = repository.changes().makeAsyncIterator()
    let first = try await iterator.next()
    #expect(first == AuditTableVersion(oldestID: 1, newestID: 1))

    _ = try await repository.insert([event(.apiRequest, at: 2)])
    let second = try await iterator.next()
    #expect(second == AuditTableVersion(oldestID: 1, newestID: 2))

    // The sweep moves the other end.
    _ = try await repository.deleteOlderThan(Date(timeIntervalSince1970: 1_700_000_000 + 1.5))
    let third = try await iterator.next()
    #expect(third == AuditTableVersion(oldestID: 2, newestID: 2))
  }

  @Test("An empty query is not filtered; any narrowing is")
  func isFiltered() {
    var query = AuditQuery()
    #expect(!query.isFiltered)
    query.search = "   "
    #expect(!query.isFiltered, "whitespace is not a search")
    query.search = "x"
    #expect(query.isFiltered)
    query = AuditQuery()
    query.since = Date()
    #expect(query.isFiltered)
  }

  /// A record is read back as it was stored, not as if it were being written now. Read
  /// inside a request (an export over the API), a record stored with no request id or route
  /// took the reader's, joining it to a request it had nothing to do with.
  @Test("A record read inside a request keeps its stored actor, request and route")
  func readingDoesNotInheritTheReader() async throws {
    let repository = try makeRepository()
    let written = await AuditContext.with(AuditContext(actor: .operator, source: .app)) {
      AuditEvent(kind: .settingsChanged, summary: "stored by the operator")
    }
    #expect(written.requestID == nil)
    _ = try await repository.insert([written])

    let reader = AuditContext(
      actor: .client(address: "203.0.113.9"), source: .http, requestID: "req-export",
      route: "/api/v2/audit/export")
    let readBack = try await AuditContext.with(reader) {
      var events: [AuditEvent] = []
      try await repository.forEachPage { events += $0 }
      let found = try await repository.find(id: 1)
      return events + (found.map { [$0] } ?? [])
    }
    try #require(readBack.count == 2)
    for event in readBack {
      #expect(event.actor == .operator)
      #expect(event.source == .app)
      #expect(event.requestID == nil)
      #expect(event.route == nil)
    }
  }
}

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
import Foundation
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

  @Test("The follow stream opens with the current version and moves on every insert")
  func changesStream() async throws {
    let repository = try makeRepository()
    _ = try await repository.insert([event(.apiRequest, at: 1)])

    var iterator = repository.changes().makeAsyncIterator()
    let first = try await iterator.next()
    #expect(first == AuditTableVersion(newestID: 1, count: 1))

    _ = try await repository.insert([event(.apiRequest, at: 2)])
    let second = try await iterator.next()
    #expect(second == AuditTableVersion(newestID: 2, count: 2))
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
}

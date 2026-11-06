//  AlertCenterReentrancyTests
//  The centre is an actor, and it suspends on every store write.
//
//  Two shapes went wrong across that suspension. Marking alerts read held an index into
//  `alerts` over an `await`, so a dismiss during the write left it pointing at the wrong
//  alert or past the end of the array. And a raise reserved its dedupe key before inserting
//  but put the row in the list only after, so a second raise of the same key found the key,
//  found no row, and inserted a duplicate: the flapping-proxy case coalescing exists for.

import BBCore
import Foundation
import Testing

@testable import BBDiagnostics

/// A store whose writes wait until the test lets them go.
private actor GatedStore: AlertStoring {
  private var holdsInserts = false
  private var holdsUpdates = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private(set) var inserted: [UUID] = []
  private(set) var updated: [UUID] = []

  var held: Int { waiting.count }

  func hold(inserts: Bool = false, updates: Bool = false) {
    holdsInserts = inserts
    holdsUpdates = updates
  }

  func release() {
    holdsInserts = false
    holdsUpdates = false
    let released = waiting
    waiting = []
    for continuation in released { continuation.resume() }
  }

  private func wait() async {
    await withCheckedContinuation { waiting.append($0) }
  }

  func restore(since cutoff: Date, limit: Int) async throws -> [UserAlert] { [] }
  func insert(_ alert: UserAlert) async throws -> Int {
    if holdsInserts { await wait() }
    inserted.append(alert.id)
    return inserted.count
  }
  func update(_ alert: UserAlert) async throws {
    if holdsUpdates { await wait() }
    updated.append(alert.id)
  }
  func delete(_ id: UUID) async throws {}
  func deleteAll() async throws {}
  func prune(before cutoff: Date, keeping capacity: Int) async throws {}
}

@Suite("Alert centre across a store write")
struct AlertCenterReentrancyTests {

  private func alert(_ title: String, dedupeKey: String? = nil) -> UserAlert {
    UserAlert(severity: .warning, title: title, body: "b", source: "test", dedupeKey: dedupeKey)
  }

  private func until(_ condition: () async -> Bool) async throws {
    let met = try await poll(.every(.milliseconds(5)), within: .seconds(5)) { _ in
      await condition() ? true : nil
    }
    #expect(met == true, "timed out waiting for the store")
  }

  @Test("A raise of the same key during the first one's insert coalesces onto it")
  func concurrentRaisesCoalesce() async throws {
    let store = GatedStore()
    let centre = AlertCenter()
    await centre.attach(store: store)
    await store.hold(inserts: true)

    let first = Task { await centre.raise(alert("flapping", dedupeKey: "proxy.flap")) }
    try await until { await store.held == 1 }
    let second = Task { await centre.raise(alert("flapping", dedupeKey: "proxy.flap")) }
    // The second either coalesces at once or, as it did, joins the first in the store.
    try await until {
      let coalesced = await centre.all().first?.occurrenceCount == 2
      let inserting = await store.held == 2
      return coalesced || inserting
    }

    await store.release()
    await first.value
    await second.value

    let alerts = await centre.all()
    #expect(alerts.count == 1, "the same condition twice is one row")
    #expect(alerts.first?.occurrenceCount == 2)
    #expect(await store.inserted.count == 1)
    // The recurrence that landed mid-insert reaches the store once the row exists.
    #expect(await store.updated.contains(try #require(alerts.first).id))
  }

  @Test("A dismiss during a mark-all-read neither misses an alert nor runs off the end")
  func dismissDuringMarkRead() async throws {
    let store = GatedStore()
    let centre = AlertCenter()
    await centre.attach(store: store)
    for title in ["a", "b", "c"] { await centre.raise(alert(title)) }
    let doomed = try #require(await centre.all().first)

    await store.hold(updates: true)
    let marking = Task { await centre.markAllRead() }
    try await until { await store.held == 1 }
    await centre.dismiss(doomed.id)
    await store.release()
    await marking.value

    let remaining = await centre.all()
    #expect(remaining.count == 2)
    #expect(remaining.allSatisfy { $0.readAt != nil }, "an alert was left unread")
    #expect(await centre.unread().isEmpty)
  }
}

//  AccessControlPersistenceTests
//  Blocks and allowlists have to outlive the process.
//
//  Unpersisted, nothing fails visibly: the feature simply resets every launch, and the CLI
//  recovery path builds a fresh in-memory service, clears nothing, and prints success. So
//  the storage round trip is asserted rather than assumed.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import Testing

@testable import BBAuth

@Suite("Access control persistence")
struct AccessControlPersistenceTests {

  private func service(
    _ database: AppDatabase,
    clock: any BBClock = ManualClock(),
    policy: AccessControlPolicy = AccessControlPolicy(perClientThreshold: 2)
  ) -> AccessControlService {
    AccessControlService(
      policy: policy,
      clock: clock,
      persistence: AccessControlStore(database: database)
    )
  }

  /// What a restart would load. The persist path is fire-and-forget, so the tests wait for
  /// this to show the write rather than assuming a particular scheduling order.
  private func persisted(
    _ database: AppDatabase
  ) async throws -> (blocked: [BlockedClient], allowlist: [AllowedClient]) {
    try await AccessControlStore(database: database).loadAccessControl()
  }

  @Test("A block survives a restart")
  func blocksArePersisted() async throws {
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let clock = ManualClock()

    let first = service(database, clock: clock)
    for _ in 0..<2 {
      _ = await first.recordFailure(
        .address("198.51.100.10"), path: "/x", reason: "bad password"
      )
    }
    try await waitUntil("the block to be persisted") {
      try await persisted(database).blocked.count == 1
    }

    // A second service over the same database is what a restart looks like.
    let second = service(database, clock: clock)
    await second.loadPersistedState()

    guard case .blocked = await second.evaluate(.address("198.51.100.10")) else {
      Issue.record("The block did not survive the restart")
      return
    }
  }

  /// The id is what an unblock acts on, so it has to name the same entry after a reload. A
  /// fresh random id per load made an unblock with an id read before a restart match
  /// nothing, and the route answered success for an unblock that never happened.
  @Test("An entry keeps its id across a restart, and an unblock by that id lands")
  func idsAreStableAcrossRestart() async throws {
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let clock = ManualClock()

    let first = service(database, clock: clock)
    await first.blockPermanently(address: "198.51.100.10", reason: "admin")
    _ = await first.allow(cidr: "203.0.113.0/24", note: "office")
    let blockedID = try #require(await first.blockedClients().first?.id)
    let allowedID = try #require(await first.allowedClients().first?.id)
    await first.flushPersistedState()

    let second = service(database, clock: clock)
    await second.loadPersistedState()
    #expect(await second.blockedClients().map(\.id) == [blockedID])
    #expect(await second.allowedClients().map(\.id) == [allowedID])

    #expect(await second.unblock(id: blockedID))
    #expect(await second.blockedClients().isEmpty)
    #expect(await second.disallow(id: allowedID))
    #expect(await second.allowedClients().isEmpty)
  }

  @Test("An unblock or disallow naming no entry says so")
  func unknownIDIsReported() async throws {
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let service = service(database)
    await service.blockPermanently(address: "198.51.100.10", reason: "admin")
    #expect(await service.unblock(id: UUID()) == false)
    #expect(await service.disallow(id: UUID()) == false)
    #expect(await service.blockedClients().count == 1)
  }

  /// The range is the entry's identity and is unique in `allowed_client`, so allowing it
  /// twice replaces rather than duplicates, and the table's next save still succeeds.
  @Test("Allowing a range twice keeps one entry, and it persists")
  func allowingTwiceReplaces() async throws {
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let service = service(database)
    _ = await service.allow(cidr: "203.0.113.0/24", note: "first")
    _ = await service.allow(cidr: "203.0.113.0/24", note: "second")
    await service.flushPersistedState()
    #expect(await service.allowedClients().map(\.note) == ["second"])
    #expect(try await persisted(database).allowlist.map(\.note) == ["second"])
  }

  @Test("Escalation history survives too")
  func offenceCountIsPersisted() async throws {
    // Without it a repeat offender restarts at the base lockout after every restart,
    // which is precisely what escalation exists to prevent, and an attacker gets to
    // choose when the server restarts far more often than anyone would like.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let store = AccessControlStore(database: database)
    try await store.saveBlocked([
      BlockedClient(
        address: "198.51.100.10", reason: "bad", failureCount: 5,
        firstSeen: Date(), lastSeen: Date(), blockedAt: Date(),
        expiresAt: Date().addingTimeInterval(900), offenceCount: 4
      )
    ])

    let loaded = try await store.loadAccessControl()
    #expect(loaded.blocked.first?.offenceCount == 4)
  }

  @Test("An administrator's allowlist survives a restart")
  func allowlistIsPersisted() async throws {
    // The half that is worse than useless when it does not persist: it appears to work,
    // then silently stops the next time the server launches.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])

    let first = service(database)
    _ = await first.allow(cidr: "203.0.113.0/24", note: "office")
    try await waitUntil("the allowlist entry to be persisted") {
      try await persisted(database).allowlist.count == 1
    }

    let second = service(database)
    await second.loadPersistedState()
    #expect(await second.allowedClients().first?.cidr == "203.0.113.0/24")

    // And it is in force, not merely listed.
    for _ in 0..<10 {
      _ = await second.recordFailure(.address("203.0.113.5"), path: "/x", reason: "bad")
    }
    #expect(await second.evaluate(.address("203.0.113.5")) == .allow)
  }

  @Test("A permanent block stays permanent across a restart")
  func permanentBlocksStayPermanent() async throws {
    // `expires_at` is null for these, so loading has to read `is_permanent` rather than
    // inferring from the timestamp; otherwise a permanent block reads as an expired one.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])

    let first = service(database)
    await first.blockPermanently(address: "198.51.100.10", reason: "abuse")
    try await waitUntil("the permanent block to be persisted") {
      try await persisted(database).blocked.first?.isPermanent == true
    }

    let second = service(database)
    await second.loadPersistedState()
    #expect(await second.blockedClients().first?.isPermanent == true)
  }

  @Test("The command-line recovery actually empties the table")
  func clearBlocklistWorksWithoutAServer() async throws {
    // The lockout escape hatch, and the stated reason the Security admin routes can stay
    // off by default. It has to work when whatever locked the operator out is still
    // broken, so it goes at the table and builds no server.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let first = service(database)
    for _ in 0..<2 {
      _ = await first.recordFailure(.address("198.51.100.10"), path: "/x", reason: "bad")
    }
    try await waitUntil("the block to be persisted") {
      try await persisted(database).blocked.count == 1
    }

    let cleared = try await AccessControlStore.clearBlocklist(database: database)
    #expect(cleared == 1)

    let after = service(database)
    await after.loadPersistedState()
    #expect(await after.evaluate(.address("198.51.100.10")) == .allow)
  }

  @Test("A service with no persistence still works")
  func persistenceIsOptional() async {
    // Every test double and the parity harness construct one without a database. It has
    // to stay a plain in-memory service rather than requiring storage to function.
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 1), clock: ManualClock()
    )
    _ = await service.recordFailure(.address("198.51.100.10"), path: "/x", reason: "bad")
    #expect(await service.blockedClients().count == 1)
  }
}

// MARK: - The failure ring

/// The recent-failure ring is the half an administrator looks at while an attack is still
/// building, and it is the half a restart used to erase.
///
/// `auth_failure` was declared by the very first access-control migration and then never
/// written to or read from by anything, while three separate places -- `docs/AUTH.md`, this
/// module's schema header, and the migration's own comment -- described it as a persisted
/// bounded ring. `SchemaContributionTests` asserted the table's COLUMNS, so it passed
/// throughout: the shape was right and nothing used it.
///
/// These tests are deliberately about behaviour rather than schema, for that reason.
@Suite("Auth failure history persistence")
struct AuthFailureHistoryPersistenceTests {

  private func service(
    _ database: AppDatabase,
    clock: any BBClock = ManualClock(),
    policy: AccessControlPolicy = AccessControlPolicy(perClientThreshold: 50)
  ) -> AccessControlService {
    AccessControlService(
      policy: policy, clock: clock, persistence: AccessControlStore(database: database)
    )
  }

  @Test("A failure that never reached the block threshold survives a restart")
  func failuresArePersisted() async throws {
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])

    let first = service(database)
    _ = await first.recordFailure(
      .address("198.51.100.20"), path: "/api/v1/ping", reason: "bad password")
    // Spends the debounce rather than waiting it out.
    await first.flushPersistedState()

    // Nothing was blocked: the threshold is 50 and one failure arrived. This is precisely
    // the state that used to leave no trace at all.
    #expect(await first.blockedClients().isEmpty)

    let second = service(database)
    await second.loadPersistedState()
    let restored = await second.failures()
    #expect(restored.count == 1)
    #expect(restored.first?.address == "198.51.100.20")
    #expect(restored.first?.reason == "bad password")
    #expect(restored.first?.path == "/api/v1/ping")
  }

  @Test("A failure with no attributable address round-trips as nil")
  func unresolvedFailuresRoundTrip() async throws {
    // The column was created `NOT NULL` while `AuthFailureRecord.address` has always been
    // optional, so this row could not have been stored at all. It is also the row most
    // worth keeping: an unattributable failure is the global-throttling case.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])

    let first = service(database)
    _ = await first.recordFailure(.unresolved, path: "/api/v1/ping", reason: "no credential")
    await first.flushPersistedState()

    let second = service(database)
    await second.loadPersistedState()
    let restored = await second.failures()
    #expect(restored.count == 1)
    #expect(restored.first?.address == nil)
  }

  @Test("Restored failures are evidence, and never block anybody on their own")
  func restoredFailuresDoNotEnforce() async throws {
    // The dangerous direction. `failureTimes` is the sliding window the block decision
    // reads; seeding it from stored rows would mean a restart could block an address on
    // failures from days ago, at the exact moment an administrator restarts to investigate.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let policy = AccessControlPolicy(perClientThreshold: 3)

    let first = service(database, policy: policy)
    for _ in 0..<2 {
      _ = await first.recordFailure(
        .address("198.51.100.30"), path: "/x", reason: "bad password")
    }
    await first.flushPersistedState()
    #expect(await first.blockedClients().isEmpty, "two of three is not yet a block")

    let second = service(database, policy: policy)
    await second.loadPersistedState()

    // The two failures came back as history...
    #expect(await second.failures().count == 2)
    // ...and the address is not blocked, nor one failure away from it.
    #expect(await second.blockedClients().isEmpty)
    let decision = await second.recordFailure(
      .address("198.51.100.30"), path: "/x", reason: "bad password")
    #expect(
      decision == .allow,
      "a restored failure must not count toward the live window; this would be the third")
    #expect(await second.blockedClients().isEmpty)
  }

  @Test("The stored ring is bounded by the policy, not by how long the attack runs")
  func storedRingIsBounded() async throws {
    // An attacker chooses the arrival rate, so the row count must be bounded by policy and
    // nothing else. Written through the service so the trim that bounds it is the real one.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let policy = AccessControlPolicy(perClientThreshold: 10_000, failureHistoryLimit: 8)

    let first = service(database, policy: policy)
    for index in 0..<40 {
      _ = await first.recordFailure(
        .address("198.51.100.40"), path: "/x", reason: "attempt \(index)")
    }
    await first.flushPersistedState()

    let stored = try await AccessControlStore(database: database).loadFailures(limit: 1000)
    #expect(stored.count == 8, "forty failures, a limit of eight")
    #expect(stored.last?.reason == "attempt 39", "the ring keeps the NEWEST, not the first")
  }

  @Test("The stored ring uses the column name the timestamp rename leaves behind")
  func timestampColumnIsTheNormalisedOne() async throws {
    // `auth.relaxAuthFailureAddress` recreates this table, and the timestamp rename renames its
    // timestamp column. Whether the rename ran before or after depends on whether the install
    // is fresh, so the migration preserves whichever name it finds and both paths converge
    // here. This pins the name the store's SQL is written against.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let columns = try await database.read { db in
      try db.columns(in: "auth_failure").map(\.name)
    }
    #expect(columns.contains("occurred_at"))
    #expect(!columns.contains("at"))
    // And the reason the table was recreated at all: an unattributable failure must fit.
    let address = try await database.read { db in
      try db.columns(in: "auth_failure").first { $0.name == "address" }?.isNotNull
    }
    #expect(address == false, "address must be nullable; see AuthFailureRecord.address")
  }

  @Test("A burst costs one write, not one per failure")
  func burstsAreDebounced() async throws {
    // The debounce is the thing that stops an attacker turning each guess into a
    // DELETE-plus-INSERT rewrite of the whole table. Counted through a store that records
    // its writes rather than by timing.
    let database = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let counting = CountingFailureStore(inner: AccessControlStore(database: database))
    let service = AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 10_000),
      clock: ManualClock(),
      persistence: counting
    )

    for index in 0..<25 {
      _ = await service.recordFailure(
        .address("198.51.100.50"), path: "/x", reason: "attempt \(index)")
    }
    await service.flushPersistedState()

    let writes = await counting.failureWriteCount
    #expect(writes == 1, "twenty-five failures inside one debounce window, \(writes) writes")
    #expect(try await AccessControlStore(database: database).loadFailures(limit: 100).count == 25)
  }
}

/// Counts failure writes, passing everything through to a real store.
private actor CountingFailureStore: AccessControlPersistence {
  private let inner: AccessControlStore
  private(set) var failureWriteCount = 0

  init(inner: AccessControlStore) { self.inner = inner }

  func loadAccessControl() async throws -> (
    blocked: [BlockedClient], allowlist: [AllowedClient]
  ) { try await inner.loadAccessControl() }

  func loadFailures(limit: Int) async throws -> [AuthFailureRecord] {
    try await inner.loadFailures(limit: limit)
  }

  func saveBlocked(_ blocked: [BlockedClient]) async throws {
    try await inner.saveBlocked(blocked)
  }

  func saveAllowlist(_ allowlist: [AllowedClient]) async throws {
    try await inner.saveAllowlist(allowlist)
  }

  func saveFailures(_ failures: [AuthFailureRecord]) async throws {
    failureWriteCount += 1
    try await inner.saveFailures(failures)
  }
}

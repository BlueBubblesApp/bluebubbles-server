//  AccessControlPersistenceTests
//  Blocks and allowlists have to outlive the process.
//
//  The tables were created by the Phase 3 migration and never read or written. Nothing
//  failed — the feature simply reset every launch, and the CLI recovery path built a fresh
//  in-memory service, cleared nothing, and printed success.

import BBCore
import BBPersistence
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

  /// The persist path is fire-and-forget, so the assertion waits for it rather than
  /// assuming a particular scheduling order.
  private func eventually(
    _ condition: @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<200 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  @Test("A block survives a restart")
  func blocksArePersisted() async throws {
    let database = try AppDatabase.inMemory()
    let clock = ManualClock()

    let first = service(database, clock: clock)
    for _ in 0..<2 {
      _ = await first.recordFailure(
        .address("198.51.100.10"), path: "/x", reason: "bad password"
      )
    }
    #expect(
      await eventually {
        (try? await AccessControlStore(database: database)
          .loadAccessControl().blocked.count) == 1
      })

    // A second service over the same database is what a restart looks like.
    let second = service(database, clock: clock)
    await second.loadPersistedState()

    guard case .blocked = await second.evaluate(.address("198.51.100.10")) else {
      Issue.record("The block did not survive the restart")
      return
    }
  }

  @Test("Escalation history survives too")
  func offenceCountIsPersisted() async throws {
    // Without it a repeat offender restarts at the base lockout after every restart,
    // which is precisely what escalation exists to prevent — and an attacker gets to
    // choose when the server restarts far more often than anyone would like.
    let database = try AppDatabase.inMemory()
    let store = AccessControlStore(database: database)
    try await store.saveBlocked([
      BlockedClient(
        id: UUID(), address: "198.51.100.10", reason: "bad", failureCount: 5,
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
    let database = try AppDatabase.inMemory()

    let first = service(database)
    _ = await first.allow(cidr: "203.0.113.0/24", note: "office")
    #expect(
      await eventually {
        (try? await AccessControlStore(database: database)
          .loadAccessControl().allowlist.count) == 1
      })

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
    // inferring from the timestamp — otherwise a permanent block reads as an expired one.
    let database = try AppDatabase.inMemory()

    let first = service(database)
    await first.blockPermanently(address: "198.51.100.10", reason: "abuse")
    #expect(
      await eventually {
        (try? await AccessControlStore(database: database)
          .loadAccessControl().blocked.first?.isPermanent) == true
      })

    let second = service(database)
    await second.loadPersistedState()
    #expect(await second.blockedClients().first?.isPermanent == true)
  }

  @Test("The command-line recovery actually empties the table")
  func clearBlocklistWorksWithoutAServer() async throws {
    // The lockout escape hatch, and the stated reason the Security admin routes can stay
    // off by default. It has to work when whatever locked the operator out is still
    // broken, so it goes at the table and builds no server.
    let database = try AppDatabase.inMemory()
    let first = service(database)
    for _ in 0..<2 {
      _ = await first.recordFailure(.address("198.51.100.10"), path: "/x", reason: "bad")
    }
    #expect(
      await eventually {
        (try? await AccessControlStore(database: database)
          .loadAccessControl().blocked.count) == 1
      })

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

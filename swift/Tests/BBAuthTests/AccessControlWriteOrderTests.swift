//  AccessControlWriteOrderTests
//  The durable access-control state ends up matching the live one.
//
//  Each change used to snapshot the state and start its own detached task, with nothing
//  sequencing them. Two rapid changes — a block and the unblock that follows it — therefore
//  raced, and the OLDER snapshot could land last. To a user that reads as "I unblocked that
//  address, and after a restart it was blocked again": security state reverting on its own.
//
//  A slow store is what makes the race observable at all. With a fast one the first write
//  finishes before the second starts and the bug hides; holding each write open until the
//  test lets it go puts both in flight at once, which is the shape a real SQLite write under
//  contention has and a test otherwise never sees.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAuth

@Suite("Access control write ordering")
struct AccessControlWriteOrderTests {

  /// A store that records every write in order, and can hold the FIRST one open.
  ///
  /// A plain delay is not enough to see this bug: two writes that both sleep tend to finish
  /// in the order they started, so the race hides and the test passes against the broken
  /// implementation — which it did, until this double was rewritten. Holding the first write
  /// open until the test releases it, while later writes return at once, forces the losing
  /// interleaving every time: the second write lands first, and whatever the first one was
  /// carrying is what ends up durable.
  private actor RecordingStore: AccessControlPersistence {
    /// Each blocked-table write, as the addresses it would have made durable, in the order
    /// the writes actually completed.
    private(set) var blockedWrites: [[String]] = []
    private(set) var allowlistWrites: [[String]] = []

    /// Whether the next write should be held. Armed by the test, spent by the first write.
    private var holdNextWrite: Bool
    private var held: CheckedContinuation<Void, Never>?
    /// True once a write is sitting in the gate, so the test can wait for that rather than
    /// guess at timing.
    private(set) var isHolding = false

    init(holdFirstWrite: Bool = false) { holdNextWrite = holdFirstWrite }

    private func gate() async {
      guard holdNextWrite else { return }
      holdNextWrite = false
      isHolding = true
      await withCheckedContinuation { continuation in held = continuation }
      isHolding = false
    }

    func release() {
      held?.resume()
      held = nil
    }

    /// Waits for a write to reach the gate. Bounded, so a test that never gets there fails
    /// rather than hanging the suite.
    func waitUntilHolding() async -> Bool {
      for _ in 0..<400 {
        if isHolding { return true }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return false
    }

    func loadAccessControl() async throws -> (
      blocked: [BlockedClient], allowlist: [AllowedClient]
    ) { ([], []) }

    func saveBlocked(_ blocked: [BlockedClient]) async throws {
      let addresses = blocked.map(\.address).sorted()
      await gate()
      blockedWrites.append(addresses)
    }

    func saveAllowlist(_ allowlist: [AllowedClient]) async throws {
      let cidrs = allowlist.map(\.cidr).sorted()
      await gate()
      allowlistWrites.append(cidrs)
    }

    /// What the blocklist would look like after a restart.
    var durableBlocked: [String] { blockedWrites.last ?? [] }
    var durableAllowlist: [String] { allowlistWrites.last ?? [] }
  }

  private func service(_ store: RecordingStore) -> AccessControlService {
    AccessControlService(
      policy: AccessControlPolicy(perClientThreshold: 1),
      clock: ManualClock(),
      persistence: store
    )
  }

  /// The bug, in the order it happens: block, then unblock, with the first write held open
  /// so the second is the one that lands first. The state that ends up durable must be the
  /// state as it finally is — not blocked.
  @Test("A block and the unblock that follows it end with the unblock durable")
  func unblockIsNotOverwrittenByTheBlock() async {
    let store = RecordingStore(holdFirstWrite: true)
    let service = service(store)

    await service.blockPermanently(address: "198.51.100.7", reason: "test")
    #expect(await store.waitUntilHolding(), "no write reached the gate")

    // The change that must win, made while the first write is still in flight. This is the
    // real sequence: a client is blocked, somebody unblocks it seconds later, and the
    // machine is busy enough that the first write has not finished.
    await service.unblock(address: "198.51.100.7")
    await store.release()
    await service.flushPersistedState()

    let durable = await store.durableBlocked
    #expect(
      durable == [],
      "the durable blocklist is \(durable); an older write landed last and re-blocked it")
    #expect(await service.blockedClients().isEmpty, "the live state should agree")
  }

  /// The same property under a burst rather than a pair: ten blocks and nine unblocks, with
  /// the first write held so everything else piles up behind it. Whatever order the writes
  /// go out in, the one that lands last has to be the state as it finally is.
  @Test("A burst of changes ends with the final state durable")
  func burstEndsCorrect() async {
    let store = RecordingStore(holdFirstWrite: true)
    let service = service(store)

    for index in 0..<10 {
      await service.blockPermanently(address: "198.51.100.\(index)", reason: "test")
    }
    #expect(await store.waitUntilHolding(), "no write reached the gate")
    for index in 0..<9 {
      await service.unblock(address: "198.51.100.\(index)")
    }
    await store.release()
    await service.flushPersistedState()

    #expect(await store.durableBlocked == ["198.51.100.9"])
    #expect(await service.blockedClients().map(\.address) == ["198.51.100.9"])
  }

  /// Coalescing, which falls out of writing the live state rather than a queued snapshot:
  /// ten changes in a burst are not ten whole-table rewrites. Asserted as a ceiling rather
  /// than an exact count, because how many passes the drain makes depends on scheduling.
  @Test("A burst does not become one table rewrite per change")
  func writesAreCoalesced() async {
    let store = RecordingStore()
    let service = service(store)

    for index in 0..<20 {
      await service.blockPermanently(address: "198.51.100.\(index)", reason: "test")
    }
    await service.flushPersistedState()

    let writes = await store.blockedWrites.count
    #expect(writes < 20, "20 changes produced \(writes) whole-table rewrites")
    #expect(writes >= 1)
  }

  /// The two tables are written independently, and a change to one must not lose a change to
  /// the other: the flags are separate for that reason.
  @Test("Blocklist and allowlist changes do not overwrite each other")
  func bothTablesSurvive() async {
    let store = RecordingStore()
    let service = service(store)

    await service.blockPermanently(address: "198.51.100.8", reason: "test")
    _ = await service.allow(cidr: "203.0.113.0/24", note: "test")
    await service.flushPersistedState()

    #expect(await store.durableBlocked == ["198.51.100.8"])
    #expect(await store.durableAllowlist == ["203.0.113.0/24"])
  }

  /// `flushPersistedState` is what every assertion above rests on, so it has to actually
  /// wait: a flush that returned early would make each of them pass by accident.
  @Test("The flush waits for the write it was told about")
  func flushWaits() async {
    let store = RecordingStore(holdFirstWrite: true)
    let service = service(store)

    await service.blockPermanently(address: "198.51.100.9", reason: "test")
    #expect(await store.waitUntilHolding(), "no write reached the gate")
    #expect(await store.blockedWrites.isEmpty, "the held write cannot have recorded yet")

    // Released only now: if the flush returned before this the assertion below would be
    // reading a write that had not happened.
    await store.release()
    await service.flushPersistedState()
    #expect(await store.blockedWrites.isEmpty == false)
  }

  /// A service with no store does not spin up a writer, and flushing one is not a hang.
  @Test("With nothing to persist there is no writer")
  func noPersistenceNoWriter() async {
    let service = AccessControlService(clock: ManualClock())
    await service.blockPermanently(address: "198.51.100.10", reason: "test")
    await service.flushPersistedState()
    #expect(await service.blockedClients().count == 1)
  }
}

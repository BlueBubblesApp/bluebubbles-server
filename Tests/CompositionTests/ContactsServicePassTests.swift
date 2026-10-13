//  ContactsServicePassTests
//  The contacts service runs one pass over the address book at a time, coalesces what
//  arrives meanwhile, and takes back the ingestor it published when it stops.
//
//  The start-up pass and the change watcher used to be two tasks, each building and
//  publishing its own ingestor, so a change landing during the start-up pass started a second
//  full pass beside the first. And the published ingestor was never withdrawn, so a stopped
//  service went on being refreshed through.
//
//  A test process cannot drive the real `CNContactStore`, so the pass is the seam: what is
//  asserted is how the service schedules passes, against `CNContactStoreDidChange` posted
//  here, which only this process's observers receive.

import BBContacts
import BBInterfaces
import BBPersistence
import Contacts
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

private actor PublicationLog {
  private(set) var published: [ObjectIdentifier] = []
  private(set) var withdrawals = 0
  private(set) var current: ContactsIngestor?

  func publish(_ ingestor: ContactsIngestor) {
    published.append(ObjectIdentifier(ingestor))
    current = ingestor
  }

  func withdraw() {
    withdrawals += 1
    current = nil
  }
}

private struct FakeHost: ContactIndexProviding, LoggerProviding, ContactsIngestorPublishing {
  let contacts: ContactIndex
  let logger = Logger(label: "bluebubbles.test.contacts-service")
  let log: PublicationLog

  func publish(contactsIngestor: ContactsIngestor) async { await log.publish(contactsIngestor) }
  func withdrawContactsIngestor() async { await log.withdraw() }
}

/// Records how many passes ran and how many at once, and holds the first open until told.
private actor PassLog {
  private(set) var started = 0
  private(set) var running = 0
  private(set) var mostAtOnce = 0
  private(set) var ingestors: Set<ObjectIdentifier> = []
  private var gate: CheckedContinuation<Void, Never>?
  private var released = false

  func begin(_ ingestor: ContactsIngestor) async {
    started += 1
    running += 1
    mostAtOnce = max(mostAtOnce, running)
    ingestors.insert(ObjectIdentifier(ingestor))
    if started == 1, !released { await withCheckedContinuation { gate = $0 } }
  }

  func end() { running -= 1 }

  func release() {
    released = true
    gate?.resume()
    gate = nil
  }

  var isHeld: Bool { gate != nil }
}

@Suite("Contacts service passes", .serialized)
struct ContactsServicePassTests {

  private func makeService(log: PublicationLog, passes: PassLog) throws -> ContactsService {
    let database = try AppDatabase.inMemory(contributors: [ContactsSchema.self])
    let host = FakeHost(contacts: ContactIndex(database: database), log: log)
    return ContactsService(
      host: host, debounce: .milliseconds(20),
      reindex: { ingestor in
        await passes.begin(ingestor)
        await passes.end()
        return ContactsIngestResult(indexed: 0, skipped: 0, duration: .zero)
      })
  }

  private func postChange() {
    NotificationCenter.default.post(name: .CNContactStoreDidChange, object: nil)
  }

  /// Waits for a condition without a fixed sleep deciding the outcome. The time limit on
  /// the test is what turns "never" into a failure.
  private func eventually(_ condition: @Sendable () async -> Bool) async throws {
    while await !condition() { try await Task.sleep(for: .milliseconds(5)) }
  }

  @Test(
    "Changes during a pass wait for it, and become one pass after it",
    .timeLimit(.minutes(1)))
  func passesAreSerialAndCoalesced() async throws {
    let log = PublicationLog()
    let passes = PassLog()
    let service = try makeService(log: log, passes: passes)

    try await service.start()
    try await eventually { await passes.isHeld }

    // Three changes, each given long enough to settle on its own, all while the start-up
    // pass is still reading.
    for _ in 0..<3 {
      postChange()
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(await passes.started == 1, "a change started a pass beside the one in progress")

    await passes.release()
    try await eventually { await passes.started >= 2 }
    // Long enough for a third pass to have started if the changes had queued separately.
    try await Task.sleep(for: .milliseconds(300))

    #expect(await passes.mostAtOnce == 1, "two passes ran at once")
    #expect(
      await passes.started == 2,
      "changes that settled during one pass were not coalesced into one pass after it")
    #expect(await passes.ingestors.count == 1, "passes used more than one ingestor")

    await service.stop()
  }

  @Test("The ingestor is published on start and taken back on stop", .timeLimit(.minutes(1)))
  func ingestorIsWithdrawnOnStop() async throws {
    let log = PublicationLog()
    let passes = PassLog()
    await passes.release()
    let service = try makeService(log: log, passes: passes)

    try await service.start()
    #expect(await log.current != nil)
    try await eventually { await passes.started == 1 }
    #expect(await passes.ingestors == Set(await log.published), "the pass used another ingestor")

    await service.stop()
    #expect(await log.current == nil, "a stopped service left its ingestor published")
    #expect(await log.withdrawals == 1)
  }
}

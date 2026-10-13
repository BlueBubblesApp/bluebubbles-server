//  AuditRecorderTests
//  Disarmed, the recorder drops; armed, it stores and forwards.
//
//  The property every emitter in the server relies on without knowing it: handing an event to
//  the recorder costs nothing and loses nothing once the audit log is on, and is a no-op when
//  it is off. Whether a batch reaches an exporter in storage order is the other thing a
//  receiver's copy depends on.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import Logging
import Testing

import struct os.OSAllocatedUnfairLock

@testable import BBAudit

@Suite("Audit recorder")
struct AuditRecorderTests {

  /// An exporter that keeps what it was handed.
  private actor CapturingExporter: AuditExporter {
    nonisolated let id = "capturing"
    private(set) var batches: [[AuditEvent]] = []
    private(set) var stopped = false
    func export(_ events: [AuditEvent]) async { batches.append(events) }
    func stop() async { stopped = true }
  }

  private func makeRepository() throws -> AuditRepository {
    AuditRepository(database: try AppDatabase.inMemory(contributors: [AuditSchema.self]))
  }

  /// Keeps every line logged at warning or above.
  private struct LoudLines: LogHandler {
    let lines: OSAllocatedUnfairLock<[String]>
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
      guard event.level >= .warning else { return }
      lines.withLock { $0.append("\(event.level): \(event.message)") }
    }
  }

  /// Stopping with a record pending used to log "Could not store audit records" at error
  /// level, on every stop: `drain` cancelled the scheduled flush, which then wrote from a
  /// cancelled task, and the database refuses those. The record still landed, through the
  /// drain's own write, so only the log said anything was wrong, and it said so falsely.
  @Test("Stopping writes what is pending and logs no error")
  func stopIsQuiet() async throws {
    let repository = try makeRepository()
    let lines = OSAllocatedUnfairLock(initialState: [String]())
    let recorder = AuditRecorder(logger: Logger(label: "test") { _ in LoudLines(lines: lines) })
    await recorder.arm(store: repository)
    await recorder.recordNow(AuditEvent(kind: .settingsChanged, summary: "pending"))
    await recorder.disarm()

    #expect(try await repository.count() == 1)
    #expect(lines.withLock { $0 } == [])
  }

  /// `record` hands each event to the actor in a task of its own, so a stop that came right
  /// after could disarm first and drop them on arrival. A one-shot command records and stops
  /// at once, and lost everything it recorded that way.
  @Test("Records handed in just before a stop are stored, not dropped")
  func recordedJustBeforeStopIsKept() async throws {
    let repository = try makeRepository()
    let recorder = AuditRecorder()
    await recorder.arm(store: repository)
    for index in 0..<50 {
      recorder.record(AuditEvent(kind: .settingsChanged, summary: "\(index)"))
    }
    await recorder.disarm()
    #expect(try await repository.count() == 50)
  }

  @Test("Disarmed, events are dropped and nothing is stored")
  func disarmedDrops() async throws {
    let repository = try makeRepository()
    let recorder = AuditRecorder()
    #expect(recorder.isRecording == false)
    recorder.record(AuditEvent(kind: .settingsChanged, summary: "x"))
    await recorder.drain()
    #expect(try await repository.count() == 0)
  }

  @Test("Armed, events reach the store and every exporter in storage order")
  func armedStoresAndForwards() async throws {
    let repository = try makeRepository()
    let exporter = CapturingExporter()
    let recorder = AuditRecorder()
    await recorder.arm(store: repository, exporters: [exporter])
    #expect(recorder.isRecording)

    await recorder.recordNow(AuditEvent(kind: .serviceStarted, summary: "a"))
    await recorder.recordNow(AuditEvent(kind: .serviceStopped, summary: "b"))
    await recorder.drain()

    #expect(try await repository.count() == 2)
    let batches = await exporter.batches
    #expect(batches.count == 1)
    #expect(batches.first?.map(\.summary) == ["a", "b"])
    // Forwarded WITH the row ids the store assigned, so a receiver's copy matches the table.
    #expect(batches.first?.map(\.id) == [1, 2])
  }

  @Test("Disarming flushes what is pending, stops the exporters and drops what follows")
  func disarmFlushesAndStops() async throws {
    let repository = try makeRepository()
    let exporter = CapturingExporter()
    let recorder = AuditRecorder()
    await recorder.arm(store: repository, exporters: [exporter])
    await recorder.recordNow(AuditEvent(kind: .recordingStopped, summary: "last"))

    await recorder.disarm()

    #expect(try await repository.count() == 1)
    #expect(await exporter.stopped)
    #expect(recorder.isRecording == false)

    recorder.record(AuditEvent(kind: .settingsChanged, summary: "after"))
    await recorder.drain()
    #expect(try await repository.count() == 1)
  }

  @Test("Read-request recording is off by default and is cleared by disarming")
  func readRequestPolicy() async throws {
    let recorder = AuditRecorder()
    #expect(recorder.recordsReadRequests == false)
    recorder.setRecordsReadRequests(true)
    #expect(recorder.recordsReadRequests)
    await recorder.arm(store: try makeRepository())
    await recorder.disarm()
    #expect(recorder.recordsReadRequests == false)
  }

  @Test("The fire-and-forget path lands after a drain")
  func fireAndForgetLands() async throws {
    let repository = try makeRepository()
    let recorder = AuditRecorder()
    await recorder.arm(store: repository)
    for index in 0..<20 {
      recorder.record(AuditEvent(kind: .apiRequest, summary: "\(index)"))
    }
    // `record` hands off to a task; `drain` waits for the flush, not for that task, so drain
    // until the hand-off has landed rather than guessing how long it takes.
    try await waitUntil("all twenty records stored") {
      await recorder.drain()
      return try await repository.count() == 20
    }
    #expect(try await repository.count() == 20)
  }

  /// The exporters receive arrival order, so arrival order has to be recording order. A task
  /// per `record` let one caller's events reach the buffer in whatever order the tasks ran.
  @Test("Fire-and-forget records reach the store and the exporters in the order recorded")
  func fireAndForgetKeepsOrder() async throws {
    let repository = try makeRepository()
    let exporter = CapturingExporter()
    let recorder = AuditRecorder()
    await recorder.arm(store: repository, exporters: [exporter])
    let count = 500
    for index in 0..<count {
      recorder.record(AuditEvent(kind: .apiRequest, summary: "\(index)"))
    }
    await recorder.drain()

    let exported = await exporter.batches.flatMap { $0 }.map(\.summary)
    #expect(exported == (0..<count).map { "\($0)" })
  }

  // MARK: - A store that refuses

  /// A store whose every insert fails, the way a full disk or a locked database does, until
  /// `heal` lifts it.
  private struct FailingStore {
    let database: AppDatabase
    let repository: AuditRepository

    init() throws {
      database = try AppDatabase.inMemory(contributors: [AuditSchema.self])
      repository = AuditRepository(database: database)
    }

    func refuseInserts() async throws {
      try await database.write { db in
        try db.execute(
          sql: """
            CREATE TRIGGER refuse BEFORE INSERT ON audit_event
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
      }
    }

    func heal() async throws {
      try await database.write { db in try db.execute(sql: "DROP TRIGGER refuse") }
    }
  }

  /// A refused batch is held, not lost, and lands once the store accepts again.
  @Test("Records refused by the store are held and stored once it recovers")
  func refusedRecordsAreHeld() async throws {
    let store = try FailingStore()
    let recorder = AuditRecorder()
    await recorder.arm(store: store.repository)
    try await store.refuseInserts()

    for index in 0..<3 {
      await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "\(index)"))
    }
    await recorder.drain()
    #expect(try await store.repository.count() == 0)

    try await store.heal()
    await recorder.drain()
    #expect(try await store.repository.count() == 3)
  }

  /// Past the cap the oldest are dropped, and the notice says exactly how many, ONCE, however
  /// many failed flushes the outage spanned.
  @Test("The drop count is exact and reported in one record across several failed flushes")
  func dropCountIsExact() async throws {
    let store = try FailingStore()
    let recorder = AuditRecorder()
    await recorder.arm(store: store.repository)
    try await store.refuseInserts()

    for index in 0..<AuditRecorder.maximumPending {
      await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "\(index)"))
    }
    await recorder.drain()
    for index in 0..<10 {
      await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "late \(index)"))
    }
    await recorder.drain()
    for index in 0..<5 {
      await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "later \(index)"))
    }
    await recorder.drain()

    try await store.heal()
    await recorder.drain()

    var query = AuditQuery()
    query.kinds = [.eventsDropped]
    let notices = try await store.repository.page(query, limit: 10, offset: 0).events
    #expect(notices.count == 1)
    #expect(notices.first?.metadata["dropped_count"] == .int(15))
    #expect(notices.first?.requestID == nil)
    #expect(try await store.repository.count() == AuditRecorder.maximumPending + 1)
  }

  /// After a refusal the next attempt waits the backoff, not the 100 ms a healthy flush waits,
  /// and a record arriving meanwhile joins that attempt rather than hastening it.
  @Test("After a refusal the recorder backs off instead of retrying every flush interval")
  func refusalBacksOff() async throws {
    let store = try FailingStore()
    let clock = TestClock()
    let recorder = AuditRecorder(clock: clock)
    await recorder.arm(store: store.repository)
    try await store.refuseInserts()
    await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "first"))
    await recorder.drain()

    // The refused batch is back in front, under a flush that waits the backoff.
    try await clock.waitForSleepers(1)
    let backoff = try #require(clock.waits.last)
    #expect(backoff >= .seconds(1), "the retry waits \(backoff), not the backoff")

    try await store.heal()
    await recorder.recordNow(AuditEvent(kind: .apiRequest, summary: "second"))
    clock.advance(by: .milliseconds(400))
    #expect(try await store.repository.count() == 0, "a retry inside the first second")

    clock.advance(by: backoff)
    try await waitUntil("both records written after the backoff") {
      try await store.repository.count() == 2
    }
    #expect(try await store.repository.count() == 2)
  }
}

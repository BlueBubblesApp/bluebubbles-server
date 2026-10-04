//  AuditRecorderTests
//  Disarmed, the recorder drops; armed, it stores and forwards.
//
//  The property every emitter in the server relies on without knowing it: handing an event to
//  the recorder costs nothing and loses nothing once the audit log is on, and is a no-op when
//  it is off. Whether a batch reaches an exporter in storage order is the other thing a
//  receiver's copy depends on.

import BBCore
import BBPersistence
import Foundation
import Testing

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

  @Test("Disarmed, events are dropped and nothing is stored")
  func disarmedDrops() async throws {
    let repository = try makeRepository()
    let recorder = AuditRecorder()
    #expect(await recorder.isArmed == false)
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
    #expect(await recorder.isArmed)

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
    #expect(await recorder.isArmed == false)

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
    // `record` hands off to a task; `drain` waits for the flush, not for those tasks, so give
    // them the one yield they need before asking.
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    await recorder.drain()
    #expect(try await repository.count() == 20)
  }
}

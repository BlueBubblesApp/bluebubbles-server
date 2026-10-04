//  AuditRecorder
//  Where every audit event is handed in, whether or not anything is listening.
//
//  The recorder exists for the whole life of the server and the audit log SERVICE arms it:
//  the HTTP dispatcher, the authentication stage, the settings store and the access controller
//  all hold the recorder from the moment they are built, and none of them knows or cares
//  whether the audit log is switched on. Disarmed, `record` drops the event and costs one
//  lock; armed, it buffers and writes. That is what lets "turn the audit log on" be a switch
//  rather than a restart of every service that emits.
//
//  `record` is NONISOLATED and never waits. It is called from the request path and from
//  inside actors that must not block on a database write, so it hands the event to the actor
//  and returns. The cost of that is ordering: two events recorded a microsecond apart may
//  reach the buffer in either order, so every consumer sorts by `occurred_at` and then by row
//  id, never by arrival. Within one flush the batch is written in one transaction and handed
//  to every exporter in the same order, so a receiver sees what the database holds.
//
//  The buffer is bounded. A recorder whose store has stalled must not grow without limit
//  while requests keep arriving; past the cap the oldest pending records are dropped, the
//  count is kept, and the next successful flush records an `audit.events_dropped` event
//  saying how many, because a gap an auditor cannot see is worse than one they can.
//
//  See `docs/AUDIT_LOG.md`.

import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

/// Somewhere an event can be handed in. The recorder is the production implementation; a
/// test substitutes a capturing one.
public protocol AuditRecording: Sendable {
  /// Returns at once. Whether anything is recorded is the recorder's business.
  func record(_ event: AuditEvent)
}

/// Somewhere stored events are also sent: a syslog receiver.
public protocol AuditExporter: Sendable {
  /// A short stable name, for a log line.
  var id: String { get }
  /// Called with each flushed batch, in storage order. Must not throw: an exporter that
  /// cannot deliver keeps its own queue and reports through its own channel.
  func export(_ events: [AuditEvent]) async
  /// Releases whatever the exporter holds. Called once, when the audit log stops.
  func stop() async
}

public actor AuditRecorder: AuditRecording {

  /// How many events may wait for a flush before the oldest are dropped.
  public static let maximumPending = 5_000
  /// How long a flush waits after the first event so a burst becomes one transaction.
  public static let flushDelay: Duration = .milliseconds(100)

  private var store: AuditRepository?
  private var exporters: [any AuditExporter] = []
  /// Whether read-only API requests are kept. A lock rather than actor state because the
  /// request path reads it synchronously on every response's way out, before deciding
  /// whether to build a record at all; see `recordsReadRequests`.
  private let readRequestPolicy = OSAllocatedUnfairLock(initialState: false)
  private var pending: [AuditEvent] = []
  private var flush: Task<Void, Never>?
  /// Events dropped since the last successful flush reported them.
  private var dropped = 0
  private let logger: Logger

  public init(logger: Logger = Logger(label: "bluebubbles.audit")) {
    self.logger = logger
  }

  // MARK: - Arming

  /// Whether events are being kept. False until the audit log service starts.
  public var isArmed: Bool { store != nil }

  /// Starts keeping events, in `store`, and forwarding each flushed batch to `exporters`.
  public func arm(store: AuditRepository, exporters: [any AuditExporter] = []) {
    self.store = store
    self.exporters = exporters
  }

  /// Whether `api.request` records are kept for read-only requests as well as state-changing
  /// ones. Off until the audit log service reads its `record_reads` field, and off again
  /// when it disarms. Nonisolated: the HTTP dispatcher asks on every finished request.
  public nonisolated var recordsReadRequests: Bool {
    readRequestPolicy.withLock { $0 }
  }

  public nonisolated func setRecordsReadRequests(_ enabled: Bool) {
    readRequestPolicy.withLock { $0 = enabled }
  }

  /// Flushes what is pending, stops the exporters and goes back to dropping events.
  public func disarm() async {
    await drain()
    let stopping = exporters
    exporters = []
    store = nil
    pending = []
    dropped = 0
    setRecordsReadRequests(false)
    for exporter in stopping { await exporter.stop() }
  }

  // MARK: - Recording

  public nonisolated func record(_ event: AuditEvent) {
    Task { await self.enqueue(event) }
  }

  /// `record`, but the caller waits until the event is in the buffer. For the one place
  /// ordering against `disarm()` matters: the record that says recording stopped has to be
  /// queued before the drain that writes it.
  public func recordNow(_ event: AuditEvent) {
    enqueue(event)
  }

  private func enqueue(_ event: AuditEvent) {
    guard store != nil else { return }
    pending.append(event)
    if pending.count > Self.maximumPending {
      pending.removeFirst(pending.count - Self.maximumPending)
      dropped += 1
    }
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard flush == nil else { return }
    flush = Task { [weak self] in
      // Cancellation is the only error `Task.sleep` throws, and a cancelled flush still
      // writes what it has: `disarm` cancels and then drains.
      try? await Task.sleep(for: Self.flushDelay)
      await self?.flushNow()
    }
  }

  /// Writes everything pending and waits for it. For shutdown and for tests.
  public func drain() async {
    flush?.cancel()
    await flush?.value
    flush = nil
    await flushNow()
  }

  private func flushNow() async {
    // Cleared FIRST, not in a `defer`: a record that arrives while the insert below is in
    // flight has to be able to schedule the next flush, and the failure path below has to be
    // able to schedule the retry. Either would see this task still registered and do nothing.
    flush = nil
    guard let store, !pending.isEmpty else { return }

    var batch = pending
    pending = []
    if dropped > 0 {
      batch.append(
        AuditEvent(
          kind: .eventsDropped,
          outcome: .failure,
          actor: .system(component: "audit"),
          summary: "\(dropped) audit records were dropped before they could be stored.",
          metadata: ["dropped_count": .int(dropped), "where": .string("recorder_buffer")]
        ))
      dropped = 0
    }

    let stored: [AuditEvent]
    do {
      stored = try await store.insert(batch)
    } catch {
      // Put back at the front so order is kept, and counted against the cap on the next
      // append rather than here: the records are not lost yet, only late.
      pending = batch + pending
      logger.error(
        "Could not store audit records; they are held for the next flush",
        metadata: [
          "count": .stringConvertible(batch.count),
          "error": .string(String(describing: error)),
        ])
      scheduleFlush()
      return
    }

    for exporter in exporters {
      await exporter.export(stored)
    }
  }
}

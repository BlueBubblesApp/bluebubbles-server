//  AuditRecorder
//  Where every audit event is handed in, whether or not anything is listening.
//
//  The recorder exists for the whole life of the server and the audit log SERVICE arms it:
//  the HTTP dispatcher, the authentication stage, the settings store and the access controller
//  all hold the recorder from the moment they are built, and none of them knows or cares
//  whether the audit log is switched on. Disarmed, `record` drops the event and costs one
//  lock: the armed flag is read under it before any task is made, and `isRecording` lets an
//  emitter skip building the event at all. Off is the default for every install, so off has
//  to cost nothing on the request path. Armed, it buffers and writes. That is what lets
//  "turn the audit log on" be a switch rather than a restart of every service that emits.
//
//  `record` is NONISOLATED and never waits. It is called from the request path and from
//  inside actors that must not block on a database write, so it hands the event to the actor
//  and returns. It hands it through ONE ordered inbox, an `AsyncStream` drained by one task,
//  so events reach the buffer in the order they were recorded: a task per event let two
//  records from one caller arrive in either order, and the exporters, which receive arrival
//  order, saw a different sequence from the one that happened. Writes are ordered the same
//  way: one flush at a time, so a later batch can never be stored or exported before an
//  earlier one. Consumers of the database still sort by `occurred_at` and then by row id.
//
//  The buffer is bounded, and a ring (`CircularBuffer`): while the store is down and the
//  buffer full, every new record pushes the oldest out, and an array would shift every held
//  record to do it. A recorder whose store has stalled must not grow without limit
//  while requests keep arriving; past the cap the oldest pending records are dropped, the
//  count is kept, and the next successful flush records an `audit.events_dropped` event
//  saying how many, because a gap an auditor cannot see is worse than one they can.
//
//  So is the rate at which a refused client can add rows: repeats of one client's refusal
//  within a minute are counted rather than stored, by `AuditRepeatLimiter`, and reported as
//  one `audit.repeats_suppressed` record when the minute is up. A timer writes that record
//  when the window closes rather than waiting for the next event, so a client that stops
//  still has its count reported.
//
//  The recorder's own records (`events_dropped`, `repeats_suppressed`) are built with the
//  task-local context cleared: they are written from a task inherited from whichever request
//  happened to schedule the flush, and must not join to it.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import Foundation
import Logging
import NIOCore

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

/// Whether the store is taking records, as reported to whoever armed the recorder.
public enum AuditStoreState: Sendable, Equatable {
  case storing
  /// The store refused a batch. `reason` is a sentence for a person, not an error dump.
  case refusing(reason: String)
}

public actor AuditRecorder: AuditRecording {

  /// How many events may wait for a flush before the oldest are dropped.
  public static let maximumPending = 5_000
  /// How many times `drain` yields for records still on their way in before it writes anyway.
  static let maximumInFlightWaits = 10_000
  /// How long a flush waits after the first event so a burst becomes one transaction.
  public static let flushDelay: Duration = .milliseconds(100)
  /// How long to wait before trying a store that refused a batch again: a second, doubling,
  /// capped at a minute. Retrying at `flushDelay` would re-encode and re-send up to
  /// `maximumPending` rows ten times a second for as long as the store is down.
  static let storeRetryPolicy = RetryPolicy(
    maxAttempts: Int.max, initialDelay: .seconds(1), maxDelay: .seconds(60), multiplier: 2)

  private var store: AuditRepository?
  private var exporters: [any AuditExporter] = []
  /// Whether read-only API requests are kept. A lock rather than actor state because the
  /// request path reads it synchronously on every response's way out, before deciding
  /// whether to build a record at all; see `recordsReadRequests`.
  private let readRequestPolicy = OSAllocatedUnfairLock(initialState: false)
  /// Mirrors `store != nil` for the nonisolated `record`, which must not hop to the actor to
  /// find out that there is nothing to do.
  private let armedFlag = OSAllocatedUnfairLock(initialState: false)
  /// Records `record` has handed off that have not reached the actor yet. `drain` waits for
  /// them: without that, whatever was recorded just before a stop arrived after the disarm
  /// and was dropped, which for a one-shot command was everything it recorded.
  private let inFlight = OSAllocatedUnfairLock(initialState: 0)
  private var pending = CircularBuffer<AuditEvent>()
  /// The one ordered way in for `record`. See the file header.
  private nonisolated let inbox: AsyncStream<AuditEvent>.Continuation
  /// The flush, scheduled or writing. There is at most one, and it stays registered until its
  /// write has finished, so records arriving meanwhile join the next flush rather than
  /// starting a second write beside it.
  private var flush: Task<Void, Never>?
  /// Which scheduled flush is current. A flush that `disarm` cancelled wakes, finds itself
  /// superseded and does nothing, rather than clearing the handle of a flush scheduled since.
  private var flushGeneration = 0
  /// Events dropped since the last successful flush reported them.
  private var dropped = 0
  /// Flushes that have failed in a row. Zero while the store is accepting.
  private var consecutiveFailures = 0
  private var repeats = AuditRepeatLimiter()
  /// Writes the next `repeats_suppressed` record when its window closes.
  private var summaryTimer: Task<Void, Never>?
  /// Told when the store starts refusing and when it accepts again, and at no other time.
  private var onStoreState: (@Sendable (AuditStoreState) async -> Void)?
  private let logger: Logger
  /// What a scheduled flush waits on: `flushDelay`, or the backoff after a refusal. Injected
  /// so a test of the backoff advances time rather than waiting it out; the default is the
  /// wall clock. The repeat summary's timer is wall-clock `Date` time and does not read this.
  private let clock: any Clock<Duration>

  public init(
    logger: Logger = Logger(label: "bluebubbles.audit"),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.logger = logger
    self.clock = clock
    let (arrivals, inbox) = AsyncStream.makeStream(of: AuditEvent.self)
    self.inbox = inbox
    // One reader for the life of the recorder, so arrival order is recording order. It ends
    // when `deinit` finishes the inbox.
    Task { [weak self] in
      for await event in arrivals {
        await self?.receive(event)
      }
    }
  }

  deinit { inbox.finish() }

  // MARK: - Arming

  /// Whether events are being kept. False until the audit log service starts. Nonisolated
  /// and one lock, so an emitter on the request path can ask before building a record.
  public nonisolated var isRecording: Bool { armedFlag.withLock { $0 } }

  /// Starts keeping events, in `store`, and forwarding each flushed batch to `exporters`.
  ///
  /// `onStoreState` is how a refusing store reaches a person. The log line alone said it once,
  /// at a level a support log keeps, while the service went on reporting itself healthy and
  /// records past the cap were being lost: an audit log that cannot write is exactly the
  /// failure its operator has to hear about.
  public func arm(
    store: AuditRepository, exporters: [any AuditExporter] = [],
    onStoreState: (@Sendable (AuditStoreState) async -> Void)? = nil
  ) {
    self.store = store
    self.exporters = exporters
    self.onStoreState = onStoreState
    armedFlag.withLock { $0 = true }
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

  /// Writes the summary of every open repeat window now, whatever its age. For the audit log
  /// stopping, which calls it before its own last record so that record stays last.
  public func closeRepeatWindows() {
    summaryTimer?.cancel()
    summaryTimer = nil
    guard store != nil else { return }
    for summary in repeats.closeAll() { append(summary) }
  }

  /// Flushes what is pending, stops the exporters and goes back to dropping events.
  public func disarm() async {
    closeRepeatWindows()
    await drain()
    // A retry a refusing store scheduled. Cancelled and superseded here, not left to fire
    // into a recorder that holds no store.
    flush?.cancel()
    flush = nil
    flushGeneration += 1
    let stopping = exporters
    exporters = []
    store = nil
    armedFlag.withLock { $0 = false }
    pending = []
    dropped = 0
    consecutiveFailures = 0
    onStoreState = nil
    setRecordsReadRequests(false)
    for exporter in stopping { await exporter.stop() }
  }

  // MARK: - Recording

  public nonisolated func record(_ event: AuditEvent) {
    guard isRecording else { return }
    inFlight.withLock { $0 += 1 }
    inbox.yield(event)
  }

  private func receive(_ event: AuditEvent) {
    enqueue(event)
    inFlight.withLock { $0 -= 1 }
  }

  /// `record`, but the caller waits until the event is in the buffer. For the one place
  /// ordering against `disarm()` matters: the record that says recording stopped has to be
  /// queued before the drain that writes it.
  public func recordNow(_ event: AuditEvent) {
    enqueue(event)
  }

  private func enqueue(_ event: AuditEvent) {
    guard store != nil else { return }
    let decision = repeats.admit(event)
    for summary in decision.summaries { append(summary) }
    if decision.keep {
      append(event)
    } else {
      scheduleSummary()
    }
  }

  private func append(_ event: AuditEvent) {
    pending.append(event)
    trimToCapacity()
    scheduleFlush()
  }

  /// Drops the oldest pending records past the cap, counting each one.
  private func trimToCapacity() {
    let excess = pending.count - Self.maximumPending
    guard excess > 0 else { return }
    pending.removeFirst(excess)
    dropped += excess
  }

  /// Arms the timer that writes a window's summary once it closes, when one is not armed.
  private func scheduleSummary() {
    guard summaryTimer == nil, let due = repeats.nextSummaryDue else { return }
    summaryTimer = Task { [weak self] in
      // Cancellation is the only error `Task.sleep` throws; a cancelled timer writes nothing,
      // because `disarm` closes every window itself.
      try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0)))
      guard !Task.isCancelled else { return }
      await self?.closeDueWindows()
    }
  }

  private func closeDueWindows() {
    summaryTimer = nil
    guard store != nil else { return }
    for summary in repeats.close(before: Date()) { append(summary) }
    scheduleSummary()
  }

  /// Schedules the next flush, unless one is scheduled or writing. While the store is failing
  /// it waits the backoff instead of `flushDelay`, and records arriving meanwhile join that
  /// flush rather than hastening it.
  private func scheduleFlush() {
    guard flush == nil else { return }
    let delay =
      consecutiveFailures == 0
      ? Self.flushDelay
      : Self.storeRetryPolicy.delay(forAttempt: consecutiveFailures + 1)
    flushGeneration += 1
    let generation = flushGeneration
    let clock = self.clock
    flush = Task { [weak self] in
      // Cancellation is the only error a clock's sleep throws, and a cancelled flush still
      // writes what it has: `drain` cancels to cut the wait short, then awaits the write.
      try? await clock.sleep(for: delay)
      await self?.runFlush(generation)
    }
  }

  /// The body of a scheduled flush: write, then hand over to the next one.
  ///
  /// `flush` is cleared only once the write has finished, which is what keeps writes in
  /// order: cleared before it, a record arriving during the insert scheduled a second flush
  /// that could store and export its batch before this one did, or after this one had put a
  /// refused batch back in front.
  private func runFlush(_ generation: Int) async {
    guard generation == flushGeneration else { return }
    await flushNow()
    flush = nil
    // Records that arrived during the write, or a refused batch put back: the next flush,
    // which waits the backoff after a refusal.
    if store != nil, !pending.isEmpty { scheduleFlush() }
  }

  /// The record saying how many were lost. No task-local context: see the file header.
  private static func dropNotice(count: Int) -> AuditEvent {
    AuditContext.$current.withValue(nil) {
      AuditEvent(
        kind: .eventsDropped,
        outcome: .failure,
        actor: .system(component: "audit"),
        summary: "\(count) audit records were dropped before they could be stored.",
        metadata: ["dropped_count": .int(count), "where": .string("recorder_buffer")]
      )
    }
  }

  /// Writes everything pending and waits for it: one attempt. For shutdown and for tests.
  ///
  /// A scheduled flush IS that attempt, cut short rather than waited out. When it succeeds,
  /// what arrived during its write is written too. When the store refuses, the retry it
  /// scheduled stands and nothing is tried again here: a second attempt would count as a
  /// second failure and lengthen the backoff for a single refusal.
  public func drain() async {
    // Records handed in before this call and still on their way here. Yielding the actor is
    // what lets them in; bounded, because a server under load keeps recording while it stops
    // and the stop must not wait for the traffic to end.
    var waited = 0
    while inFlight.withLock({ $0 }) > 0, waited < Self.maximumInFlightWaits {
      await Task.yield()
      waited += 1
    }
    // Every write goes through a scheduled flush, so there is never a second one beside it.
    scheduleFlush()
    if let scheduled = flush {
      scheduled.cancel()
      await scheduled.value
    }
    if consecutiveFailures == 0, let arrivedMeanwhile = flush {
      arrivedMeanwhile.cancel()
      await arrivedMeanwhile.value
    }
  }

  /// Writes what is pending, once. Only ever called from `runFlush`.
  private func flushNow() async {
    guard let store, !pending.isEmpty else { return }

    let records = Array(pending)
    pending = []
    // The drop notice is built for THIS attempt and never queued: if the insert fails, the
    // count goes back into `dropped` and the next attempt builds one notice with the whole
    // count. Queued with the records it describes, the cap could drop it, and a second
    // failure would add a second notice beside it.
    let droppedNow = dropped
    dropped = 0
    var batch = records
    if droppedNow > 0 { batch.append(Self.dropNotice(count: droppedNow)) }

    let stored: [AuditEvent]
    do {
      // In a task of its own, so the write does not inherit the caller's cancellation. The
      // database refuses a write from a cancelled task, and `drain` cancels the scheduled
      // flush before writing: that flush's insert was refused on every stop and logged as a
      // failure to store, while the drain stored the same records a moment later.
      stored = try await Task { try await store.insert(batch) }.value
    } catch {
      // Put back in front so order is kept. The records are not lost yet, only late; past
      // the cap the oldest are, and are counted.
      var held = CircularBuffer(records)
      held.append(contentsOf: pending)
      pending = held
      dropped += droppedNow
      trimToCapacity()
      consecutiveFailures += 1
      let metadata: Logger.Metadata = [
        "count": .stringConvertible(pending.count),
        "failures": .stringConvertible(consecutiveFailures),
        "error": .string(String(describing: error)),
      ]
      // Once per outage at the level a support log keeps; the retries after it are detail.
      // The retry is scheduled by `runFlush`, once this write has finished.
      if consecutiveFailures == 1 {
        logger.error("Could not store audit records; they are held and retried", metadata: metadata)
        await onStoreState?(.refusing(reason: DiagnosticText.sentence(for: error)))
      } else {
        logger.debug("Audit records still could not be stored", metadata: metadata)
      }
      return
    }
    if consecutiveFailures > 0 {
      logger.info(
        "Audit records are being stored again",
        metadata: [
          "failures": .stringConvertible(consecutiveFailures),
          "dropped": .stringConvertible(droppedNow),
        ])
      consecutiveFailures = 0
      await onStoreState?(.storing)
    }

    for exporter in exporters {
      await exporter.export(stored)
    }
  }
}

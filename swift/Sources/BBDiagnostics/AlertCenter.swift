//  AlertCenter
//  The only path to a user-visible notification.
//
//  There is deliberately no route from `logger.error(...)` to here. A logger that also
//  created alert rows and bumped the dock badge turned every internal error into a
//  notification carrying a bare string. Raising is an explicit act.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import Foundation
import Logging

public actor AlertCenter: AlertRaising {

  /// Rows are capped; an unbounded alert table grows without limit on a busy server.
  public static let defaultCapacity = 500
  public static let defaultRetention: Duration = .seconds(60 * 60 * 24 * 30)

  private var alerts: [UserAlert] = []
  private var indexByDedupeKey: [String: UUID] = [:]
  /// Monotonic, never reused, starting at 1 — the reference's `alert.id` is an autoincrement
  /// primary key and clients read it as a number. Not derived from `alerts.count`, which
  /// would reuse a number as soon as the cap trimmed a row and let a client's stale id
  /// address a different alert.
  private var nextSequence = 1
  private let capacity: Int
  private let retention: Duration
  /// Injected so retention is testable. Reading `Date()` directly means the only way to
  /// prove a 30-day cutoff works is to wait 30 days, so it was never proven at all —
  /// exactly the gap `BBClock` was introduced to close.
  private let clock: any BBClock
  private let logger = Logger(label: "bluebubbles.alerts")

  /// Observers — the UI drawer, the badge, optional native banners.
  private var continuations: [UUID: AsyncStream<UserAlert>.Continuation] = [:]

  /// Durable storage, when there is any.
  ///
  /// Optional because the centre has to stay constructible without a database — every test
  /// that raises an alert, and the brief window during start-up before storage is open.
  /// Nil means the previous behaviour exactly: alerts live for the life of the process.
  private var store: (any AlertStoring)?

  public init(
    capacity: Int = AlertCenter.defaultCapacity,
    retention: Duration = AlertCenter.defaultRetention,
    clock: any BBClock = SystemClock()
  ) {
    self.capacity = capacity
    self.retention = retention
    self.clock = clock
  }

  // MARK: - Persistence

  /// Attaches a store and reads back what it holds.
  ///
  /// Restored alerts keep their identity, their occurrence count and their read state, so a
  /// problem that has happened forty-seven times still says so after a restart — which is
  /// the whole reason `occurrence_count` is a column.
  ///
  /// A TRANSIENT alert comes back already read. It describes a live condition the server
  /// re-derives at start-up anyway, so leaving it unread would put a stale alarm in front of
  /// someone for a problem that may have cleared while the server was down. It stays in the
  /// list because its history is still worth having.
  public func attach(store: any AlertStoring) async {
    self.store = store
    do {
      let cutoff = clock.now.addingTimeInterval(-retention.seconds)
      let restored = try await store.restore(since: cutoff, limit: capacity)
      let now = clock.now
      alerts = restored.map { alert in
        var alert = alert
        if !alert.isDurable { alert.readAt = alert.readAt ?? now }
        return alert
      }
      indexByDedupeKey = [:]
      for alert in alerts {
        if let key = alert.dedupeKey { indexByDedupeKey[key] = alert.id }
      }
      // Past every restored row, so a client's stale sequence never addresses a different
      // alert after a restart.
      nextSequence = (alerts.map(\.sequence).max() ?? 0) + 1
      logger.debug(
        "Restored alerts",
        metadata: ["count": .stringConvertible(alerts.count)])
    } catch {
      // Non-fatal by design. A store that will not read costs history, not notifications.
      logger.warning(
        "Could not restore stored alerts",
        metadata: ["error": .string(String(describing: error))])
    }
  }

  // MARK: - Raising

  public func raise(_ alert: UserAlert) async {
    // Coalesce rather than append. A flapping proxy produces one row reading
    // "occurred 47 times", not 47 rows.
    if let key = alert.dedupeKey,
      let existingID = indexByDedupeKey[key],
      let index = alerts.firstIndex(where: { $0.id == existingID })
    {
      alerts[index].occurrenceCount += 1
      // Stamped from the CENTRE's clock, not the caller's `createdAt`. `lastOccurredAt` is
      // what retention and trimming compare against, so taking it from `Date()` while the
      // cutoff came from `clock.now` meant the injected clock only controlled one side of
      // the comparison — and the thirty-day window it exists to make testable could not
      // actually be exercised.
      alerts[index].lastOccurredAt = clock.now
      // A recurrence is new information, so it becomes unread again.
      alerts[index].readAt = nil
      await persistUpdate(alerts[index])
      broadcast(alerts[index])
      return
    }

    var stored = alert
    stored.occurrenceCount = 1
    stored.lastOccurredAt = clock.now

    // The row's autoincrement id IS the sequence when there is a store — the same thing the
    // reference's `alert.id` is — so numbering keeps climbing across restarts. Falling back
    // to the in-memory counter keeps a store-less centre working unchanged.
    if let store {
      do {
        stored.sequence = try await store.insert(stored)
        nextSequence = max(nextSequence, stored.sequence + 1)
      } catch {
        logger.warning(
          "Could not store an alert",
          metadata: ["error": .string(String(describing: error))])
        stored.sequence = nextSequence
        nextSequence += 1
      }
    } else {
      stored.sequence = nextSequence
      nextSequence += 1
    }

    alerts.insert(stored, at: 0)
    if let key = stored.dedupeKey { indexByDedupeKey[key] = stored.id }

    await trim()
    broadcast(stored)

    // Alerts are also logged, so the log remains a complete record. The reverse is not
    // true, which is the entire point of the split.
    logger.notice(
      "\(stored.title)",
      metadata: [
        "source": .string(stored.source),
        "severity": .string(stored.severity.rawValue),
        "code": .string(stored.diagnostics?.code ?? "-"),
      ]
    )
  }

  public func raise(_ error: any BBError, actions: [AlertAction] = []) async {
    guard error.isUserFacing else {
      // Not user-facing: log it and stop. This is the branch that keeps internal
      // errors out of the notification drawer.
      logger.error(
        "\(error.title)",
        metadata: [
          "domain": .string(error.domain),
          "code": .string(error.code),
        ]
      )
      return
    }

    await raise(
      UserAlert(
        severity: error.severity,
        title: error.title,
        body: error.body,
        source: error.domain,
        diagnostics: Diagnostics(
          code: error.code,
          domain: error.domain,
          underlyingDescription: String(describing: error),
          stackTrace: Thread.callStackSymbols,
          context: error.context
        ),
        actions: actions,
        // Default dedupe by code, so a repeated failure coalesces without every
        // call site having to think about it.
        dedupeKey: error.code
      )
    )
  }

  // MARK: - Reading

  public func all(limit: Int = 100) -> [UserAlert] {
    Array(alerts.prefix(limit))
  }

  public func unread() -> [UserAlert] {
    alerts.filter { $0.readAt == nil }
  }

  /// The dock badge counts warnings and above only — an info alert should not decorate the
  /// icon.
  public func badgeCount() -> Int {
    alerts.filter { $0.readAt == nil && $0.severity >= .warning }.count
  }

  /// Marks by the CLIENT-facing identifier.
  ///
  /// Separate from the UUID overload rather than replacing it: the app holds `UserAlert`
  /// values and marks by `id`, while an HTTP client only ever saw the sequence number.
  public func markRead(sequences: [Int]) async {
    let wanted = Set(sequences)
    guard !wanted.isEmpty else { return }
    let now = clock.now
    for index in alerts.indices where wanted.contains(alerts[index].sequence) {
      if alerts[index].readAt == nil {
        alerts[index].readAt = now
        await persistUpdate(alerts[index])
      }
    }
  }

  public func markRead(_ ids: [UUID]) async {
    let idSet = Set(ids)
    let now = clock.now
    for index in alerts.indices where idSet.contains(alerts[index].id) {
      if alerts[index].readAt == nil {
        alerts[index].readAt = now
        await persistUpdate(alerts[index])
      }
    }
  }

  public func markAllRead() async {
    await markRead(alerts.map(\.id))
  }

  /// Puts an alert back to unread.
  ///
  /// The undo for a misclick, and the way someone parks a problem they have seen but not
  /// dealt with. Worth having because read is the only "I have handled this" record the
  /// drawer keeps: without a way back, one stray click erases that record permanently and
  /// the alert is indistinguishable from forty others that really were dealt with.
  ///
  /// Clears `readAt` outright rather than stamping anything new — an alert that is unread
  /// again is in exactly the state it was raised in, and a second "unread since" timestamp
  /// would be a field nothing reads.
  public func markUnread(_ ids: [UUID]) async {
    let idSet = Set(ids)
    for index in alerts.indices where idSet.contains(alerts[index].id) {
      if alerts[index].readAt != nil {
        alerts[index].readAt = nil
        await persistUpdate(alerts[index])
      }
    }
  }

  /// Dismissing REMOVES the alert.
  ///
  /// It does not tombstone it: `dismissedAt` was being stamped on a row that was deleted
  /// on the next line, so the field could never be observed and every `dismissedAt == nil`
  /// filter elsewhere was trivially true. One model, not two — a dismissed alert is gone,
  /// and its dedupe key is released so the same condition recurring raises a fresh one
  /// rather than silently coalescing into a row nobody can see.
  public func dismiss(_ id: UUID) async {
    guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }
    if let key = alerts[index].dedupeKey { indexByDedupeKey[key] = nil }
    alerts.remove(at: index)
    // Removed from the store as well, or it would come back on the next restart — which is
    // exactly what dismissing it said not to do.
    do { try await store?.delete(id) } catch { logStoreFailure(error) }
  }

  public func clear() async {
    alerts.removeAll()
    indexByDedupeKey.removeAll()
    do { try await store?.deleteAll() } catch { logStoreFailure(error) }
  }

  private func persistUpdate(_ alert: UserAlert) async {
    do { try await store?.update(alert) } catch { logStoreFailure(error) }
  }

  private func logStoreFailure(_ error: any Error) {
    logger.warning(
      "An alert change could not be stored",
      metadata: ["error": .string(String(describing: error))])
  }

  // MARK: - Observation

  public func stream() -> AsyncStream<UserAlert> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }

  private func broadcast(_ alert: UserAlert) {
    for continuation in continuations.values {
      continuation.yield(alert)
    }
  }

  // MARK: - Retention

  /// Kept in step with the store: the same window and the same cap, applied to both, so the
  /// rows that come back after a restart are the rows that were in memory before it.
  private func trim() async {
    let cutoff = clock.now.addingTimeInterval(-retention.seconds)
    do { try await store?.prune(before: cutoff, keeping: capacity) } catch {
      logStoreFailure(error)
    }
    alerts.removeAll { $0.lastOccurredAt < cutoff }
    if alerts.count > capacity {
      let dropped = alerts[capacity...]
      for alert in dropped {
        if let key = alert.dedupeKey { indexByDedupeKey[key] = nil }
      }
      alerts.removeSubrange(capacity...)
    }
  }
}

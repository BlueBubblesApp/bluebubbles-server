//  MetricsStore
//  What the server did, a minute at a time, for thirty days; and when it and its helpers were
//  up.
//
//  Two tables, both written only by `ServerMetrics` and read only by Home:
//
//  - `metric_minute` holds one row per metric per finished minute. The metric is a closed
//    `MetricKey`, never a free-form string: a free-form name is a table any caller can grow
//    without bound, and a typo in one is a series that silently stays empty.
//  - `availability_span` holds when the server, and each Private API helper, was up. A span
//    left open by a crash is closed at the next start, at the last minute that was flushed,
//    because that is the last moment anything can vouch for.
//
//  Retention is enforced by the writer on every flush (`prune(before:)`), so the file cannot
//  outgrow thirty days however long the server runs. At one row per metric per minute that is
//  about 43,000 rows a metric, which SQLite reads in a range scan on the primary key.
//
//  No message content, no address and no request path lands here: counts only, which is what
//  makes it safe to keep.

import BBPersistence
import Foundation
import GRDB

public enum MetricsSchema: SchemaContributor {

  public static let schemaNamespace = "metrics"

  public static func registerSchemaBeforeTimestampRename(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("metrics.createTables") { db in
      try db.create(table: "metric_minute") { table in
        table.column("metric", .text).notNull()
        table.column("minute_at", .datetime).notNull()
        table.column("value", .double).notNull()
        table.primaryKey(["metric", "minute_at"])
      }
      try db.create(
        index: "metric_minute_on_minute_at", on: "metric_minute", columns: ["minute_at"])

      try db.create(table: "availability_span") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("subject", .text).notNull()
        table.column("started_at", .datetime).notNull()
        table.column("ended_at", .datetime)
      }
      try db.create(
        index: "availability_span_on_started_at", on: "availability_span",
        columns: ["started_at"])
    }
  }
}

/// A series the server records every minute. The raw value is the stored identifier: renaming
/// a case strands its history, so a rename is a new case and a migration.
public enum MetricKey: String, Sendable, CaseIterable, Codable {
  /// HTTP requests answered in the minute.
  case requests = "requests"
  /// Of those, the ones that failed.
  case requestErrors = "request_errors"
  /// Mean time to answer, in milliseconds, over the minute's requests.
  case averageLatencyMilliseconds = "average_latency_ms"
  /// The most socket clients connected at once during the minute.
  case socketClients = "socket_clients"
  /// Events the server emitted in the minute, of every kind.
  case events = "events"
  /// `new-message` events in the minute.
  case newMessages = "new_messages"
  case pushDelivered = "push_delivered"
  case pushFailed = "push_failed"
  /// Resident memory at the end of the minute, in megabytes.
  case memoryMegabytes = "memory_mb"
  /// Share of one core the process used over the minute, 0 to 100 per core.
  case cpuPercent = "cpu_percent"
}

/// What an availability span is about.
public enum AvailabilitySubject: String, Sendable, CaseIterable, Codable {
  case server = "server"
  case messagesHelper = "messages_helper"
  case faceTimeHelper = "facetime_helper"
}

public struct MetricPoint: Sendable, Equatable, Identifiable {
  public let minute: Date
  public let value: Double
  public var id: Date { minute }

  public init(minute: Date, value: Double) {
    self.minute = minute
    self.value = value
  }
}

public struct AvailabilitySpan: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let subject: AvailabilitySubject
  public let start: Date
  /// Nil while it is still open.
  public let end: Date?

  public init(id: Int64, subject: AvailabilitySubject, start: Date, end: Date?) {
    self.id = id
    self.subject = subject
    self.start = start
    self.end = end
  }
}

public struct MetricsStore: Sendable {

  /// How long anything is kept.
  public static let retention: TimeInterval = 30 * 24 * 60 * 60

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Minutes

  /// Writes one finished minute. A second write for the same minute replaces the first,
  /// which is what a flush retried after a crash between write and acknowledgement wants.
  public func record(minute: Date, values: [MetricKey: Double]) async throws {
    guard !values.isEmpty else { return }
    try await database.write { db in
      for (metric, value) in values {
        try db.execute(
          sql: """
            INSERT INTO metric_minute (metric, minute_at, value) VALUES (?, ?, ?)
            ON CONFLICT(metric, minute_at) DO UPDATE SET value = excluded.value
            """,
          arguments: [metric.rawValue, minute, value])
      }
    }
  }

  /// A series from `start` onwards, oldest first. Minutes with no row are absent, not zero:
  /// a minute the server was not running is a gap, and a chart should draw it as one.
  public func series(_ metric: MetricKey, since start: Date) async throws -> [MetricPoint] {
    try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT minute_at, value FROM metric_minute
          WHERE metric = ? AND minute_at >= ?
          ORDER BY minute_at
          """,
        arguments: [metric.rawValue, start]
      ).map { MetricPoint(minute: $0["minute_at"], value: $0["value"]) }
    }
  }

  /// The newest minute anything was written for, or nil on a fresh install.
  public func lastRecordedMinute() async throws -> Date? {
    try await database.read { db in
      try Date.fetchOne(db, sql: "SELECT MAX(minute_at) FROM metric_minute")
    }
  }

  // MARK: - Availability

  /// Opens a span and returns its id.
  public func open(_ subject: AvailabilitySubject, at start: Date) async throws -> Int64 {
    try await database.write { db in
      try db.execute(
        sql: "INSERT INTO availability_span (subject, started_at) VALUES (?, ?)",
        arguments: [subject.rawValue, start])
      return db.lastInsertedRowID
    }
  }

  public func close(span id: Int64, at end: Date) async throws {
    try await database.write { db in
      try db.execute(
        sql: "UPDATE availability_span SET ended_at = ? WHERE id = ? AND ended_at IS NULL",
        arguments: [end, id])
    }
  }

  /// Closes every span a previous process left open, at `end` or at its own start if that
  /// is later: a span cannot end before it began, however stale the last flush was.
  @discardableResult
  public func closeAbandoned(at end: Date) async throws -> Int {
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE availability_span SET ended_at = MAX(started_at, ?)
          WHERE ended_at IS NULL
          """,
        arguments: [end])
      return db.changesCount
    }
  }

  /// Every span that overlaps `[start, now]`, oldest first.
  public func spans(since start: Date) async throws -> [AvailabilitySpan] {
    try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, subject, started_at, ended_at FROM availability_span
          WHERE ended_at IS NULL OR ended_at >= ?
          ORDER BY started_at
          """,
        arguments: [start]
      ).compactMap { row in
        guard let subject = AvailabilitySubject(rawValue: row["subject"]) else { return nil }
        return AvailabilitySpan(
          id: row["id"], subject: subject, start: row["started_at"], end: row["ended_at"])
      }
    }
  }

  // MARK: - Retention

  /// Deletes everything that ended before `cutoff`. An open span is never deleted.
  public func prune(before cutoff: Date) async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM metric_minute WHERE minute_at < ?", arguments: [cutoff])
      try db.execute(
        sql: "DELETE FROM availability_span WHERE ended_at IS NOT NULL AND ended_at < ?",
        arguments: [cutoff])
    }
  }
}

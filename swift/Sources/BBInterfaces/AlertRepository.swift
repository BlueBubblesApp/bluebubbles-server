//  AlertRepository
//  The only path to the `alert` table.
//
//  The table had been in `AppDatabase.migrate()` since `createAlerts` and nothing had ever
//  read or written a row. Its columns are not a guess at what an alert might be — they map
//  one-to-one onto `UserAlert`, down to `occurrence_count`, `read_at` and `dismissed_at`,
//  which only mean anything if rows outlive the process. The persistent half was designed
//  and never built, so alerts lived and died with the process while `AlertCenter` applied a
//  thirty-day retention window to them.
//
//  `is_durable` is the one column the original schema did not have, added by its own
//  migration. See `UserAlert.isDurable` for what it decides.

import BBCore
import BBDiagnostics
import BBPersistence
import BBSerialization
import Foundation
import GRDB

public struct AlertRepository: AlertStoring {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Reading

  public func restore(since cutoff: Date, limit: Int) async throws -> [UserAlert] {
    try await database.read { db in
      // Mapped inside the closure: `Row` borrows the statement's storage and is not
      // Sendable, so carrying rows out and reading them afterwards is a use-after-free.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, uuid, severity, title, body, source, diagnostics, dedupe_key,
                 occurrence_count, created_at, last_occurred_at, read_at, is_durable
          FROM alert
          WHERE dismissed_at IS NULL AND last_occurred_at >= ?
          ORDER BY last_occurred_at DESC
          LIMIT ?
          """,
        arguments: [cutoff, limit]
      )
      return rows.compactMap(Self.alert(from:))
    }
  }

  // MARK: - Writing

  public func insert(_ alert: UserAlert) async throws -> Int {
    let diagnostics = Self.encode(alert.diagnostics)
    return try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO alert
            (uuid, severity, title, body, source, diagnostics, dedupe_key,
             occurrence_count, created_at, last_occurred_at, read_at, dismissed_at,
             is_durable)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
          """,
        arguments: [
          alert.id.uuidString, alert.severity.rawValue, alert.title, alert.body,
          alert.source, diagnostics, alert.dedupeKey, alert.occurrenceCount,
          alert.createdAt, alert.lastOccurredAt, alert.readAt, alert.isDurable,
        ]
      )
      return Int(db.lastInsertedRowID)
    }
  }

  /// The fields that change after an alert exists: a recurrence bumping the count and
  /// clearing the read stamp, or the user reading it. Identity, text and severity never
  /// change, so they are not rewritten.
  public func update(_ alert: UserAlert) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE alert
          SET occurrence_count = ?, last_occurred_at = ?, read_at = ?
          WHERE uuid = ?
          """,
        arguments: [
          alert.occurrenceCount, alert.lastOccurredAt, alert.readAt, alert.id.uuidString,
        ]
      )
    }
  }

  public func delete(_ id: UUID) async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM alert WHERE uuid = ?", arguments: [id.uuidString])
    }
  }

  public func deleteAll() async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM alert")
    }
  }

  /// The same two rules `AlertCenter.trim` applies in memory, so the rows that come back
  /// after a restart are the rows that were there before it.
  public func prune(before cutoff: Date, keeping capacity: Int) async throws {
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM alert WHERE last_occurred_at < ?", arguments: [cutoff])
      // Newest `capacity` rows survive; anything older than that is dropped.
      try db.execute(
        sql: """
          DELETE FROM alert WHERE id NOT IN (
            SELECT id FROM alert ORDER BY last_occurred_at DESC LIMIT ?
          )
          """,
        arguments: [capacity]
      )
    }
  }

  // MARK: - Mapping

  private static func alert(from row: Row) -> UserAlert? {
    let rawUUID: String = row["uuid"]
    guard let id = UUID(uuidString: rawUUID) else { return nil }
    let rawSeverity: String = row["severity"]
    guard let severity = Severity(rawValue: rawSeverity) else { return nil }

    return UserAlert.restored(
      id: id,
      sequence: row["id"],
      severity: severity,
      title: row["title"],
      body: row["body"],
      source: row["source"],
      createdAt: row["created_at"],
      lastOccurredAt: row["last_occurred_at"],
      occurrenceCount: row["occurrence_count"],
      readAt: row["read_at"],
      dedupeKey: row["dedupe_key"],
      isDurable: row["is_durable"] ?? true,
      diagnostics: decode(row["diagnostics"])
    )
  }

  private static func encode(_ diagnostics: Diagnostics?) -> Data? {
    guard let diagnostics else { return nil }
    var object = JSONObjectBuilder()
    object.setOrNull("code", diagnostics.code.map(JSONValue.string))
    object.setOrNull("domain", diagnostics.domain.map(JSONValue.string))
    object.setOrNull(
      "underlying", diagnostics.underlyingDescription.map(JSONValue.string))
    // The stack trace and the log excerpt are deliberately dropped. Both are large, both
    // are only useful while the process that produced them is running, and storing them
    // would make the alert table the biggest thing in the database.
    object.set(
      "context",
      .object(diagnostics.context.mapValues { .string($0.redactedDescription) }))
    return try? object.build().serialize()
  }

  /// `JSONValue` exposes `stringValue` and `arrayValue` but no object accessor, so the
  /// case is matched directly.
  private static func context(from value: JSONValue?) -> [String: DiagnosticValue] {
    guard case .object(let fields)? = value else { return [:] }
    return fields.compactMapValues { $0.stringValue.map(DiagnosticValue.string) }
  }

  private static func decode(_ data: Data?) -> Diagnostics? {
    guard let data, let value = try? JSONValue.parse(data) else { return nil }
    return Diagnostics(
      code: value["code"]?.stringValue,
      domain: value["domain"]?.stringValue,
      underlyingDescription: value["underlying"]?.stringValue,
      context: Self.context(from: value["context"])
    )
  }
}

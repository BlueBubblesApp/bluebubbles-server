//  AuditRepository
//  The only path to the `audit_event` table.
//
//  Reads are PAGED and newest first, because the table is the one in `app.db` that is meant
//  to grow: a year of a busy server is hundreds of thousands of rows, and a page that read
//  them all to show fifty would be the contacts bug again. A page carries its total from the
//  same read, so the pager cannot describe a table the sweep has already shrunk.
//
//  The CSV export walks the table OLDEST first by row id in fixed-size pages, holding one page
//  at a time, so exporting a year costs the memory of one page.
//
//  The follow stream yields a version (the oldest and newest row ids) rather than the rows:
//  the page reads its own rows through `ScreenModel`, where a failed read is reported, and a
//  stream that carried rows would be a second read path with nowhere to put a failure.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import BBPersistence
import Foundation
import GRDB

/// What a list asks for.
public struct AuditQuery: Sendable, Hashable {
  public var categories: Set<AuditCategory> = []
  public var kinds: Set<AuditEventKind> = []
  public var outcomes: Set<AuditOutcome> = []
  /// `client`, `operator` or `system`; see `AuditActor.kind`.
  public var actorKinds: Set<String> = []
  /// Matched case-insensitively against the summary, the actor id, the subject id and the
  /// route. Empty matches everything.
  public var search: String = ""
  public var since: Date?
  public var until: Date?

  public init() {}

  /// Whether anything narrows the result.
  public var isFiltered: Bool {
    !categories.isEmpty || !kinds.isEmpty || !outcomes.isEmpty || !actorKinds.isEmpty
      || !search.trimmingCharacters(in: .whitespaces).isEmpty || since != nil || until != nil
  }

  /// The `WHERE` clause and its arguments, or an always-true clause for an empty query.
  func whereClause() -> (sql: String, arguments: StatementArguments) {
    var conditions: [String] = []
    var values: [(any DatabaseValueConvertible)?] = []

    func include(_ column: String, _ options: [String]) {
      guard !options.isEmpty else { return }
      let sorted = options.sorted()
      conditions.append(
        "\(column) IN (\(SQLPlaceholders.list(sorted.count)))")
      values.append(contentsOf: sorted.map { $0 as (any DatabaseValueConvertible)? })
    }

    include("category", categories.map(\.rawValue))
    include("kind", kinds.map(\.rawValue))
    include("outcome", outcomes.map(\.rawValue))
    include("actor_kind", Array(actorKinds))

    let needle = search.trimmingCharacters(in: .whitespaces)
    if !needle.isEmpty {
      // `LIKE` is case-insensitive for ASCII in SQLite, which is what every identifier here
      // is. The wildcards in the needle are escaped so a search for `%` finds a per cent sign.
      let escaped =
        needle
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
      let pattern = "%\(escaped)%"
      conditions.append(
        "(summary LIKE ? ESCAPE '\\' OR actor_id LIKE ? ESCAPE '\\' "
          + "OR subject_id LIKE ? ESCAPE '\\' OR route LIKE ? ESCAPE '\\')")
      values.append(contentsOf: [pattern, pattern, pattern, pattern])
    }
    if let since {
      conditions.append("occurred_at >= ?")
      values.append(since)
    }
    if let until {
      conditions.append("occurred_at <= ?")
      values.append(until)
    }

    let sql = conditions.isEmpty ? "1 = 1" : conditions.joined(separator: " AND ")
    return (sql, StatementArguments(values))
  }
}

/// One page of the table and how many rows match in all.
public struct AuditPage: Sendable {
  public let events: [AuditEvent]
  public let total: Int
  /// Rows on this page that this build cannot read (see `AuditEventRow.event()`), which are
  /// in `total` and not in `events`. Counted rather than thrown so one row written by a newer
  /// server does not hide every row around it, and reported so the page can say so.
  public let unreadable: Int

  public init(events: [AuditEvent], total: Int, unreadable: Int = 0) {
    self.events = events
    self.total = total
    self.unreadable = unreadable
  }
}

/// Rows read and rows that could not be: what a decoded read hands back.
private func decode(_ rows: [AuditEventRow]) -> (events: [AuditEvent], unreadable: Int) {
  var events: [AuditEvent] = []
  events.reserveCapacity(rows.count)
  var unreadable = 0
  for row in rows {
    if let event = try? row.event() { events.append(event) } else { unreadable += 1 }
  }
  return (events, unreadable)
}

/// Where the table has got to, for a follower deciding whether to re-read.
///
/// The two ends of the row ids rather than a count: each is one step down the primary key,
/// where `COUNT(*)` reads the whole table, and the version is read after EVERY commit to it
/// for as long as the app runs. The ends are enough to see every change: an insert moves
/// `newestID`, and the only thing that deletes is the retention sweep, which removes the
/// oldest rows and then writes its own `audit.retention_applied`.
public struct AuditTableVersion: Sendable, Hashable {
  public let oldestID: Int64
  public let newestID: Int64
}

public struct AuditRepository: Sendable {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Writing

  /// Stores a batch in one transaction and returns it with row ids assigned.
  public func insert(_ events: [AuditEvent]) async throws -> [AuditEvent] {
    guard !events.isEmpty else { return [] }
    let rows = try events.map(AuditEventRow.init)
    return try await database.write { db in
      var stored: [AuditEvent] = []
      stored.reserveCapacity(rows.count)
      for var row in rows {
        try row.insert(db)
        row.id = db.lastInsertedRowID
        stored.append(try row.event())
      }
      return stored
    }
  }

  // MARK: - Reading

  /// A page's rows, newest first. One spelling, so the test that asserts which index SQLite
  /// chooses for it asks about the query that actually runs.
  static func pageSQL(where clause: String) -> String {
    """
    SELECT * FROM audit_event WHERE \(clause)
    ORDER BY occurred_at DESC, id DESC LIMIT ? OFFSET ?
    """
  }

  /// Newest first.
  public func page(_ query: AuditQuery = AuditQuery(), limit: Int, offset: Int) async throws
    -> AuditPage
  {
    let clause = query.whereClause()
    return try await database.read { db in
      let total =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM audit_event WHERE \(clause.sql)",
          arguments: clause.arguments) ?? 0
      let rows = try AuditEventRow.fetchAll(
        db,
        sql: Self.pageSQL(where: clause.sql),
        arguments: clause.arguments + StatementArguments([limit, offset])
      )
      let decoded = decode(rows)
      return AuditPage(events: decoded.events, total: total, unreadable: decoded.unreadable)
    }
  }

  public func find(id: Int64) async throws -> AuditEvent? {
    try await database.read { db in
      try AuditEventRow.fetchOne(db, key: id).map { try $0.event() }
    }
  }

  public func count() async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_event") ?? 0
    }
  }

  /// Walks every matching row oldest first, a page at a time, in the order they were stored.
  ///
  /// Keyset-paged on the row id rather than `OFFSET`, so a table that grows while the export
  /// runs neither repeats a row nor skips one. A row this build cannot read is skipped and
  /// counted, for the reason `AuditPage.unreadable` gives.
  ///
  /// - Returns: How many rows were skipped as unreadable.
  @discardableResult
  public func forEachPage(
    matching query: AuditQuery = AuditQuery(),
    pageSize: Int = 500,
    _ body: ([AuditEvent]) throws -> Void
  ) async throws -> Int {
    let clause = query.whereClause()
    var after: Int64 = 0
    var unreadable = 0
    while true {
      let cursor = after
      let rows = try await database.read { db in
        try AuditEventRow.fetchAll(
          db,
          sql: "SELECT * FROM audit_event WHERE id > ? AND \(clause.sql) ORDER BY id ASC LIMIT ?",
          arguments: StatementArguments([cursor]) + clause.arguments
            + StatementArguments([pageSize])
        )
      }
      // The cursor follows the ROWS, readable or not, so an unreadable row is passed over
      // rather than read again for ever.
      guard let last = rows.last?.id else { return unreadable }
      let decoded = decode(rows)
      unreadable += decoded.unreadable
      if !decoded.events.isEmpty { try body(decoded.events) }
      guard rows.count == pageSize else { return unreadable }
      after = last
    }
  }

  /// The table's version, now and after every commit to it, whichever path wrote.
  ///
  /// The first element is the current version. Throws only if the database fails, which a
  /// follower reports the way a failed page read is reported. Keeps only the NEWEST version a
  /// slow follower has not taken yet: a version is "something changed", and three of them
  /// queued say no more than one.
  public func changes() -> AsyncThrowingStream<AuditTableVersion, any Error> {
    let observation = database.observe { db in
      // Two subqueries, not `MIN(id), MAX(id)` in one select: SQLite answers a lone MIN or
      // MAX from the end of the index and scans for the pair.
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT COALESCE((SELECT MIN(id) FROM audit_event), 0) AS oldest,
                 COALESCE((SELECT MAX(id) FROM audit_event), 0) AS newest
          """)
      return AuditTableVersion(oldestID: row?["oldest"] ?? 0, newestID: row?["newest"] ?? 0)
    }
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let forwarding = Task {
        do {
          for try await version in observation { continuation.yield(version) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in forwarding.cancel() }
    }
  }

  // MARK: - Retention

  /// How many rows one retention transaction removes.
  public static let retentionBatchSize = 5_000

  /// Removes every record older than `cutoff` and returns how many went.
  ///
  /// In batches, oldest first, each its own transaction. `app.db` has one writer, and a single
  /// `DELETE` over a large backlog holds it for as long as the delete takes: measured, 650,000
  /// rows held it for 1.9 seconds, during which every settings write, webhook change and block
  /// waited. A batch is a few milliseconds, and the writer is free between batches. Stops
  /// between batches when the task is cancelled and returns what it had removed by then, so
  /// stopping the audit log does not wait for a backlog, the rows that did go are still
  /// accounted for, and what is left goes on the next sweep.
  public func deleteOlderThan(
    _ cutoff: Date, batchSize: Int = AuditRepository.retentionBatchSize
  ) async throws -> Int {
    var total = 0
    while !Task.isCancelled {
      let deleted: Int
      do {
        deleted = try await database.write { db in
          try db.execute(
            sql: """
              DELETE FROM audit_event WHERE id IN (
                SELECT id FROM audit_event WHERE occurred_at < ? ORDER BY occurred_at, id LIMIT ?)
              """,
            arguments: [cutoff, batchSize])
          return db.changesCount
        }
      } catch {
        // Cancelled while a batch was being written: the database refuses or interrupts it,
        // and that batch rolls back whole. So this is the stopping point, not a failure, and
        // `total` is still exactly what went. Thrown instead, it lost the count of every
        // batch before it, and the rows were removed with nothing recording that they were.
        guard Task.isCancelled else { throw error }
        return total
      }
      total += deleted
      guard deleted == batchSize else { return total }
      // Lets a writer queued behind this batch go before the next one.
      await Task.yield()
    }
    return total
  }
}

// MARK: - The row

/// `audit_event` as GRDB sees it. Internal: callers get `AuditEvent`.
struct AuditEventRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "audit_event"

  var id: Int64?
  var uuid: String
  var occurredAt: Date
  var category: String
  var kind: String
  var outcome: String
  var severity: String
  var actorKind: String
  var actorID: String?
  var source: String
  var requestID: String?
  var route: String?
  var subjectKind: String?
  var subjectID: String?
  var summary: String
  var metadata: String
  var schemaVersion: Int

  enum CodingKeys: String, CodingKey {
    case id, uuid, category, kind, outcome, severity, source, route, summary, metadata
    case occurredAt = "occurred_at"
    case actorKind = "actor_kind"
    case actorID = "actor_id"
    case requestID = "request_id"
    case subjectKind = "subject_kind"
    case subjectID = "subject_id"
    case schemaVersion = "schema_version"
  }

  init(_ event: AuditEvent) throws {
    id = event.id
    uuid = event.uuid.uuidString.lowercased()
    occurredAt = event.occurredAt
    category = event.category.rawValue
    kind = event.kind.rawValue
    outcome = event.outcome.rawValue
    severity = event.severity.rawValue
    actorKind = event.actor.kind
    actorID = event.actor.identifier
    source = event.source.rawValue
    requestID = event.requestID
    route = event.route
    subjectKind = event.subject?.kind
    subjectID = event.subject?.id
    summary = event.summary
    metadata = String(
      decoding: try AuditJSON.encode(JSONValue.object(event.metadata)), as: UTF8.self)
    schemaVersion = AuditEvent.schemaVersion
  }

  /// A stored row as an event, or a thrown error for a row this build cannot read.
  ///
  /// A kind this build does not know is a row written by a newer one. The readers above skip
  /// it and COUNT it (`AuditPage.unreadable`, the return of `forEachPage`), which is the
  /// balance between two failures: throwing would let one such row hide every row around it, and
  /// skipping silently would make a downgraded server's audit log look complete while it was
  /// not.
  func event() throws -> AuditEvent {
    guard let kind = AuditEventKind(rawValue: kind) else {
      throw AuditStorageError.unknownKind(self.kind, id: id ?? 0)
    }
    let actor: AuditActor
    switch actorKind {
    case "client": actor = .client(address: actorID)
    case "system": actor = .system(component: actorID ?? "server")
    case "operator": actor = .operator
    // Including a kind a newer server wrote: an actor this build cannot name is not the
    // person at the Mac.
    default: actor = .unattributed
    }
    let subject: AuditSubject? =
      if let subjectKind, let subjectID { AuditSubject(kind: subjectKind, id: subjectID) } else {
        nil
      }
    let decoded = try AuditJSON.decode(JSONValue.self, from: Data(metadata.utf8))
    guard case .object(let fields) = decoded else {
      throw AuditStorageError.malformedMetadata(id: id ?? 0)
    }
    // A fact this build cannot read is not given a value. An unknown outcome read as
    // `.success` and a bad identifier as a fresh UUID: in a forensic record, a refusal shown
    // as a success and an id that matches nothing anywhere else. Such a row is unreadable,
    // and the readers count it as one.
    guard let outcome = AuditOutcome(rawValue: outcome) else {
      throw AuditStorageError.unreadableField("outcome", id: id ?? 0)
    }
    guard let uuid = UUID(uuidString: uuid) else {
      throw AuditStorageError.unreadableField("uuid", id: id ?? 0)
    }
    // The stored-record initialiser: a nil request id or route stays nil, whatever request
    // is reading it.
    return AuditEvent(
      stored: kind,
      outcome: outcome,
      severity: AuditSeverity(rawValue: severity) ?? kind.defaultSeverity(for: .success),
      actor: actor,
      source: AuditSource(rawValue: source) ?? AuditSource.implied(by: actor),
      requestID: requestID,
      route: route,
      subject: subject,
      summary: summary,
      metadata: fields,
      occurredAt: occurredAt,
      uuid: uuid,
      id: id
    )
  }
}

public enum AuditStorageError: BBError, Equatable, CustomStringConvertible {
  case unknownKind(String, id: Int64)
  case malformedMetadata(id: Int64)
  /// A column whose value this build has no reading for.
  case unreadableField(String, id: Int64)

  public var code: String {
    switch self {
    case .unknownKind: "audit.unknown_kind"
    case .malformedMetadata: "audit.malformed_metadata"
    case .unreadableField: "audit.unreadable_field"
    }
  }
  public var domain: String { "Audit" }
  public var title: String { "The audit log holds a record this build cannot read" }
  public var body: String { description }

  public var description: String {
    switch self {
    case .unknownKind(let kind, let id):
      "Audit record \(id) is of kind '\(kind)', which this version of the server does not know. "
        + "It was written by a newer version."
    case .malformedMetadata(let id):
      "Audit record \(id) carries metadata that is not a JSON object."
    case .unreadableField(let field, let id):
      "Audit record \(id) has a value in \(field) that this version of the server cannot read."
    }
  }
}

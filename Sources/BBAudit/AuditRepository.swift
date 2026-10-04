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
//  The follow stream yields a version (the newest row id and the count) rather than the rows:
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
        "\(column) IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))")
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

  public init(events: [AuditEvent], total: Int) {
    self.events = events
    self.total = total
  }
}

/// Where the table has got to, for a follower deciding whether to re-read.
public struct AuditTableVersion: Sendable, Hashable {
  public let newestID: Int64
  public let count: Int
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
        sql: """
          SELECT * FROM audit_event WHERE \(clause.sql)
          ORDER BY occurred_at DESC, id DESC LIMIT ? OFFSET ?
          """,
        arguments: clause.arguments + StatementArguments([limit, offset])
      )
      return AuditPage(events: try rows.map { try $0.event() }, total: total)
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
  /// runs neither repeats a row nor skips one.
  public func forEachPage(
    matching query: AuditQuery = AuditQuery(),
    pageSize: Int = 500,
    _ body: ([AuditEvent]) throws -> Void
  ) async throws {
    let clause = query.whereClause()
    var after: Int64 = 0
    while true {
      let page = try await database.read { db in
        try AuditEventRow.fetchAll(
          db,
          sql: "SELECT * FROM audit_event WHERE id > ? AND \(clause.sql) ORDER BY id ASC LIMIT ?",
          arguments: StatementArguments([after]) + clause.arguments
            + StatementArguments([pageSize])
        ).map { try $0.event() }
      }
      guard !page.isEmpty else { return }
      try body(page)
      guard let last = page.last?.id, page.count == pageSize else { return }
      after = last
    }
  }

  /// The table's version, now and after every commit to it, whichever path wrote.
  ///
  /// The first element is the current version. Throws only if the database fails, which a
  /// follower reports the way a failed page read is reported.
  public func changes() -> AsyncThrowingStream<AuditTableVersion, any Error> {
    let observation = database.observe { db in
      let row = try Row.fetchOne(
        db, sql: "SELECT COALESCE(MAX(id), 0) AS newest, COUNT(*) AS total FROM audit_event")
      return AuditTableVersion(newestID: row?["newest"] ?? 0, count: row?["total"] ?? 0)
    }
    return AsyncThrowingStream { continuation in
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

  /// Removes every record older than `cutoff` and returns how many went.
  public func deleteOlderThan(_ cutoff: Date) async throws -> Int {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM audit_event WHERE occurred_at < ?", arguments: [cutoff])
      return db.changesCount
    }
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
      decoding: try AuditJSON.encode(AuditValue.object(event.metadata)), as: UTF8.self)
    schemaVersion = AuditEvent.schemaVersion
  }

  /// A stored row as an event, or a thrown error for a row this build cannot read.
  ///
  /// A kind this build does not know is a row written by a newer one and is reported rather
  /// than dropped: silently skipping it would make a downgraded server's audit log look
  /// complete while it was not.
  func event() throws -> AuditEvent {
    guard let kind = AuditEventKind(rawValue: kind) else {
      throw AuditStorageError.unknownKind(self.kind, id: id ?? 0)
    }
    let actor: AuditActor
    switch actorKind {
    case "client": actor = .client(address: actorID)
    case "system": actor = .system(component: actorID ?? "server")
    default: actor = .operator
    }
    let subject: AuditSubject? =
      if let subjectKind, let subjectID { AuditSubject(kind: subjectKind, id: subjectID) } else {
        nil
      }
    let decoded = try AuditJSON.decode(AuditValue.self, from: Data(metadata.utf8))
    guard case .object(let fields) = decoded else {
      throw AuditStorageError.malformedMetadata(id: id ?? 0)
    }
    return AuditEvent(
      kind: kind,
      outcome: AuditOutcome(rawValue: outcome) ?? .success,
      severity: AuditSeverity(rawValue: severity) ?? kind.defaultSeverity(for: .success),
      actor: actor,
      source: AuditSource(rawValue: source) ?? AuditSource.implied(by: actor),
      requestID: requestID,
      route: route,
      subject: subject,
      summary: summary,
      metadata: fields,
      occurredAt: occurredAt,
      uuid: UUID(uuidString: uuid) ?? UUID(),
      id: id
    )
  }
}

public enum AuditStorageError: BBError, Equatable, CustomStringConvertible {
  case unknownKind(String, id: Int64)
  case malformedMetadata(id: Int64)

  public var code: String {
    switch self {
    case .unknownKind: "audit.unknown_kind"
    case .malformedMetadata: "audit.malformed_metadata"
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
    }
  }
}

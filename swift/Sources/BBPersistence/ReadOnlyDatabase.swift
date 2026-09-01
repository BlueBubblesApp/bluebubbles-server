//  ReadOnlyDatabase
//  A database handle that CANNOT be written to, by construction.
//
//  chat.db belongs to Messages.app. Corrupting a user's message history is unrecoverable,
//  and Messages is an actively-writing second process the whole time we are reading.
//
//  The guarantee here is structural rather than a flag, because a flag is exactly what
//  failed before: the Electron server opened users' message databases READ-WRITE until July
//  2026, when `readonly: true` was added as a one-line fix (c07eab0). This type exposes no
//  write API at all — no write, no execute, no migrator — so a write does not compile.
//
//  See `.claude/docs/database.md`.

import BBCore
import Foundation
import GRDB
import Logging

public struct ReadOnlyDatabase: Sendable {

  /// Deliberately private. Handing out the DatabaseQueue would hand out `write`.
  private let queue: DatabaseQueue
  private let logger = Logger(label: "bluebubbles.db.readonly")

  public let path: String

  /// Opens read-only.
  ///
  /// `immutable` is deliberately NOT set. It promises SQLite the file cannot change, which
  /// is false while Messages is running, and produces stale reads or corruption. We need
  /// live WAL content, which means accepting the cost of a normal read-only open.
  public init(path: String) throws {
    var configuration = Configuration()
    configuration.readonly = true
    // One connection, not a pool: lower memory on the old hardware this targets, and a
    // reader needs no concurrency against a database it never writes.
    configuration.maximumReaderCount = 1

    self.path = path
    self.queue = try DatabaseQueue(path: path, configuration: configuration)
  }

  /// The only way in. Note there is no `write` counterpart, and no way to obtain the
  /// underlying queue.
  public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    try await queue.read(block)
  }

  /// Streams rows instead of materialising them.
  ///
  /// Preferred for anything unbounded: `fetchAll` on a large message query is one of the
  /// ways the current server's memory grows with the size of the user's history.
  public func readCursor<T: Sendable>(
    sql: String,
    arguments: StatementArguments = StatementArguments(),
    transform: @Sendable @escaping (Row) throws -> T,
    consume: @Sendable ([T]) throws -> Void,
    batchSize: Int = 200
  ) async throws {
    try await queue.read { db in
      let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
      var batch: [T] = []
      batch.reserveCapacity(batchSize)
      while let row = try cursor.next() {
        batch.append(try transform(row))
        if batch.count >= batchSize {
          try consume(batch)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty { try consume(batch) }
    }
  }

  // MARK: - Introspection

  /// Columns present on a table, for the schema profile.
  ///
  /// Necessary because Apple's schema changes per release in both directions — Sonoma adds
  /// six message columns, Sequoia adds six more AND removes a table Sonoma had.
  public func columns(of table: String) async throws -> Set<String> {
    try await read { db in
      let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
      return Set(rows.compactMap { $0["name"] as String? })
    }
  }

  public func tables() async throws -> Set<String> {
    try await read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
      )
      return Set(rows.compactMap { $0["name"] as String? })
    }
  }

  /// Indexes that actually exist, which we cannot add to.
  ///
  /// Query plans have to work against whatever Messages.app ships, tuned for its access
  /// patterns rather than ours. The schema dumps in macos/database/samples contain only
  /// CREATE TABLE statements, so this can only be answered at runtime.
  public func indexes(on table: String) async throws -> [String] {
    try await read { db in
      let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
      return rows.compactMap { $0["name"] as String? }
    }
  }

  /// Returns the query plan. Used by the CI check that fails any query full-scanning
  /// `message`.
  public func explainQueryPlan(
    sql: String,
    arguments: StatementArguments = StatementArguments()
  ) async throws -> [String] {
    try await read { db in
      let rows = try Row.fetchAll(
        db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments
      )
      return rows.compactMap { $0["detail"] as String? }
    }
  }
}

public enum ReadOnlyDatabaseError: BBError {
  case notFound(path: String)
  /// Opening succeeded but reading did not — almost always missing Full Disk Access,
  /// which is worth naming explicitly since the generic SQLite error is unhelpful.
  case permissionDenied(path: String)
  case tableMissing(String)
}

extension ReadOnlyDatabaseError {
  public var code: String {
    switch self {
    case .notFound: "database.not_found"
    case .permissionDenied: "database.permission_denied"
    case .tableMissing: "database.table_missing"
    }
  }

  public var domain: String { "Storage" }

  /// A message database this server cannot read is the difference between a working server
  /// and an empty one, and the remedy — Full Disk Access — is not guessable.
  public var isUserFacing: Bool {
    if case .permissionDenied = self { return true }
    return false
  }

  public var title: String {
    switch self {
    case .permissionDenied: "This server cannot read the message database"
    default: "A database could not be opened"
    }
  }

  public var body: String {
    switch self {
    case .notFound(let path): "There is no database at \(path)."
    case .permissionDenied(let path):
      "\(path) exists but could not be read. Granting this server Full Disk Access in "
        + "System Settings is what fixes it."
    case .tableMissing(let table):
      "The database has no \(table) table, so this version of macOS may not be supported yet."
    }
  }
}

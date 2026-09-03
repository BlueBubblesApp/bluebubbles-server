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

  /// Deliberately private. Handing out the reader would hand out its `write`.
  ///
  /// Two CONCRETE cases rather than `any DatabaseReader`, and that is not a style choice.
  /// Through the existential, `read` resolves against the protocol's requirement instead of
  /// `DatabaseQueue`'s own overload set — the same trap `AppDatabase` documents, where a
  /// closure returning non-`Sendable` statement storage picks a different overload than the
  /// author intended. Here it did more than block: the whole test bundle died with SIGBUS,
  /// reproducibly, and only in a full run. Switching on a concrete case keeps every call the
  /// same one it has always been.
  private enum Reader {
    case single(DatabaseQueue)
    case pooled(DatabasePool)
  }

  private let reader: Reader
  private let logger = Logger(label: "bluebubbles.db.readonly")

  public let path: String

  /// Opens read-only.
  ///
  /// `immutable` is deliberately NOT set. It promises SQLite the file cannot change, which
  /// is false while Messages is running, and produces stale reads or corruption. We need
  /// live WAL content, which means accepting the cost of a normal read-only open.
  ///
  /// - Parameter maximumReaders: How many reads may be in flight at once. **One by default,
  ///   which is a single `DatabaseQueue` and the behaviour this has always had.** Anything
  ///   greater opens a `DatabasePool` instead.
  ///
  ///   Measured, not assumed — `Tests/BBIMessageTests/ReadConcurrencyBenchmark.swift`, on a
  ///   40,000-message database in a release build: one connection holds ~26 page queries a
  ///   second and does NOT move between one concurrent reader and sixteen, because every
  ///   read serialises through it. Four readers reach ~95/second, and cost about 2 MB.
  ///
  ///   A read-only pool does NOT require WAL — it opens and gives real concurrency against a
  ///   rollback-journal file too. What both shapes DO require is that a WAL database have its
  ///   `-shm` file, which exists only while a writer holds it; without one, neither can open.
  ///   For chat.db that means "while Messages.app is running", which is when this server
  ///   reads it.
  public init(path: String, maximumReaders: Int = 1) throws {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.maximumReaderCount = max(1, maximumReaders)
    // WAIT for a lock rather than failing on it. GRDB's default is `.immediateError`, so a
    // read that lands while the writer holds the database throws "database is locked" —
    // and the writer here is Messages.app, which we do not control and cannot ask to
    // pause. chat.db is normally in WAL mode, where readers do not block, but a checkpoint
    // still takes a brief exclusive lock; two seconds is far longer than one needs and far
    // shorter than any request timeout.
    configuration.busyMode = .timeout(2)

    self.path = path

    // A pool that cannot open FALLS BACK to one connection rather than failing.
    //
    // Defence rather than a fix for a known case: no trigger has been reproduced. A pool was
    // expected to refuse a rollback-journal database and does not, and the one failure that
    // WAS found — a WAL database with no `-shm` — takes the single connection down with it,
    // so the fallback does not help there. It is kept because the cost is one `try?` and the
    // thing it protects is the user's entire message history: raising a performance setting
    // must not be able to remove the read path. If a trigger is ever found, it belongs in the
    // benchmark as a test.
    if maximumReaders > 1, let pool = try? DatabasePool(path: path, configuration: configuration) {
      self.reader = .pooled(pool)
      self.readerCount = maximumReaders
    } else {
      var single = configuration
      single.maximumReaderCount = 1
      self.reader = .single(try DatabaseQueue(path: path, configuration: single))
      self.readerCount = 1
    }
  }

  /// How many readers this actually opened with, which is not always what was asked for —
  /// see `init`. Callers log it rather than the request, so a silent fallback is visible.
  public let readerCount: Int

  /// The only way in. Note there is no `write` counterpart, and no way to obtain the
  /// underlying reader.
  public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    switch reader {
    case .single(let queue): try await queue.read(block)
    case .pooled(let pool): try await pool.read(block)
    }
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
    try await read { db in
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

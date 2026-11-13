//  MappedRow
//  The one way to read a cell out of a database another process writes.
//
//  SQLite does not enforce a column's declared type, and GRDB's typed `Row` subscript
//  (`row["x"] as T?`) decodes with `try!`. So an INTEGER in a text column, or a BLOB that is
//  not UTF-8, terminates the process the first time anything reads the row. One such cell in
//  chat.db did exactly that. The stores this server reads and does not own (chat.db, the
//  sticker store, the call log) are written by Apple's processes, so the cell is theirs to
//  contain and ours to survive.
//
//  Here rather than in BBIMessage because those stores are read from two modules: the call
//  log belongs to BBSystem, which cannot depend on BBIMessage. BBPersistence is the lowest
//  module both reach, and it already owns the read-only handle the rows come through.
//
//  `RowSource` names the store a row came from, so a warning or an error says which file
//  held the bad cell. Each owning module declares its own (`RowSource.chatDatabase` in
//  BBIMessage, `RowSource.callHistory` in BBSystem) and passes it to every map.
//
//  Read through `mapRows(in:)` or `Row.mapped(in:)`, never `row["x"]`;
//  `RowSubscriptPolicyTests` scans the readers of every foreign store for the raw subscript.

import BBCore
import Foundation
import GRDB
import Logging

/// Which database a row was read from, for the warning or the error a bad cell produces.
public struct RowSource: Sendable, Hashable {
  /// The file's own name, as a person would find it on disk: `chat.db`.
  public let file: String
  /// What the store is, in a sentence: "the message database".
  public let summary: String
  /// The column that identifies a row, logged beside a bad cell so the row can be found.
  /// Nil when no query against this store selects one under a stable name.
  public let keyColumn: String?

  public init(file: String, summary: String, keyColumn: String?) {
    self.file = file
    self.summary = summary
    self.keyColumn = keyColumn
  }
}

/// Column positions, resolved once per result set.
///
/// `Row`'s string subscript is a linear scan of the column list, and `hasColumn` is a second
/// one. A message is about seventy columns and every one of them was read through both, so
/// mapping a single row cost thousands of string comparisons: measured at 87ms per thousand
/// rows against 1.8ms positional, which made this — not the SQL, not the decoding — the
/// dominant cost of serving a page of messages.
///
/// The real database has more columns than the fixtures do, and the scan is O(columns) per
/// call, so the measured number understates it.
public struct ColumnIndex: Sendable {
  @usableFromInline let positions: [String: Int]

  /// Built from any row of a result set: every row of one statement has the same columns.
  public init(_ row: Row) {
    var positions = [String: Int](minimumCapacity: row.count)
    // First occurrence wins, which is what `Row`'s own leftmost-match lookup does when a
    // join puts the same column name in twice.
    for (offset, name) in row.columnNames.enumerated() where positions[name] == nil {
      positions[name] = offset
    }
    self.positions = positions
  }

  @inlinable
  public func position(_ column: String) -> Int? { positions[column] }
}

/// A row together with its column positions and the store it came from.
///
/// Reads by index when the name is in the index and falls back to the string path when it is
/// not — `Row` matches column names case-insensitively and this does not — so a statement
/// that spells a column differently still maps correctly, only at the old speed. That
/// fallback is what makes the index behaviour-preserving by construction rather than by
/// audit of every SELECT.
///
/// A CELL THAT DOES NOT HOLD ITS COLUMN'S TYPE NEVER TRAPS. Every read takes the cell as a
/// `DatabaseValue`, which any cell is, and converts it itself. What a cell that will not
/// convert does depends on whether the row can exist without it:
///
///   - **`required`** (a ROWID, a GUID, a handle's address) THROWS
///     `RowReadError.unreadableCell`. There is no row without its identity, and the
///     request that read it fails as a database error naming the column, not the value.
///   - **`optional`** and the flags read as NULL, and the first such cell per column of each
///     store is logged as a warning. Throwing for these would fail every request whose page
///     holds the row, and chat.db's change detector, whose tick throws and retries, would
///     never get past it: one stray cell would stop every new message from being announced.
///     NULL is also the closest the wire can come to the cell: a client already handles null
///     in every one of these fields, and a value of the wrong type is not something it can be
///     sent.
public struct MappedRow {
  public let row: Row
  public let columns: ColumnIndex
  public let source: RowSource

  public init(row: Row, columns: ColumnIndex, source: RowSource) {
    self.row = row
    self.columns = columns
    self.source = source
  }

  /// The cell as SQLite holds it, or nil when the column is not in this result.
  ///
  /// The typed subscript decodes with `try!`, and here it cannot fail: every storage class
  /// IS a `DatabaseValue`, so the conversion that traps elsewhere has nothing to refuse.
  @inlinable
  func cell(_ column: String) -> DatabaseValue? {
    if let index = columns.position(column) { return row[index] as DatabaseValue }
    guard row.hasColumn(column) else { return nil }
    return row[column] as DatabaseValue
  }

  /// A column the schema always has. Throws when it is absent or its cell does not convert,
  /// because a message with no ROWID is a broken row rather than a missing feature.
  @inlinable
  public func required<T: DatabaseValueConvertible>(_ column: String) throws -> T {
    guard let value = cell(column) else {
      throw RowReadError.unreadableCell(
        column: column, expected: "\(T.self)", found: "no such column", in: source)
    }
    guard let decoded = T.fromDatabaseValue(value) else {
      throw RowReadError.unreadableCell(
        column: column, expected: "\(T.self)", found: CellReport.storageClass(of: value),
        in: source)
    }
    return decoded
  }

  /// Safe column access: a column absent from this schema, a NULL, and a cell that does not
  /// convert all read as nil. The last is reported; see the type's header.
  @inlinable
  public func optional<T: DatabaseValueConvertible>(_ column: String) -> T? {
    guard let value = cell(column), !value.isNull else { return nil }
    if let decoded = T.fromDatabaseValue(value) { return decoded }
    CellReport.unreadable(column: column, expected: "\(T.self)", value: value, in: self)
    return nil
  }

  /// A flag: 1 is true, and anything else (absent, NULL, 0, unreadable) is false.
  @inlinable
  public func bool(_ column: String) -> Bool {
    let value: Int64? = optional(column)
    return value == 1
  }

  /// A flag whose ABSENCE is meaningful: nil when the column is absent or unreadable.
  @inlinable
  public func boolIfPresent(_ column: String) -> Bool? {
    guard let value: Int64 = optional(column) else { return nil }
    return value == 1
  }
}

extension Row {
  /// One row, mapped on its own.
  ///
  /// Builds a `ColumnIndex` for a single row, which is precisely the cost `mapRows` exists to
  /// amortise: right for a fixture or a single-row lookup, wrong inside a loop.
  public func mapped<T>(in source: RowSource, _ transform: (MappedRow) throws -> T) rethrows
    -> T
  {
    try transform(MappedRow(row: self, columns: ColumnIndex(self), source: source))
  }
}

extension Array where Element == Row {
  /// Maps a whole result set through ONE shared `ColumnIndex`.
  ///
  /// The point of the index is that it is built once per statement rather than once per
  /// row, so this is the only intended way to build row values in bulk.
  public func mapRows<T>(in source: RowSource, _ transform: (MappedRow) throws -> T) rethrows
    -> [T]
  {
    guard let first = first else { return [] }
    let columns = ColumnIndex(first)
    // The precondition, enforced in debug rather than written down and hoped for: every row
    // must have the SAME columns in the same order. True for any result set, because one
    // statement produces one column list -- and false for rows built from a dictionary
    // literal, whose order is arbitrary and varies between processes. A row that disagrees
    // reads another column's value under the name it asked for, which is silent, and the
    // name-miss fallback cannot catch it because the name is present, just elsewhere.
    assert(
      allSatisfy { $0.columnNames.elementsEqual(first.columnNames) },
      "mapRows was given rows from more than one statement; use `Row.mapped` per row instead"
    )
    return try map { try transform(MappedRow(row: $0, columns: columns, source: source)) }
  }
}

/// A row that cannot be built, because a cell it cannot exist without (a ROWID, a GUID) is
/// absent or does not hold the type it is read as.
///
/// `found` is a storage class or "no such column", NEVER the value: the value may be a
/// message's text, and this error reaches both the log and the client's `error.message`.
/// GRDB's own `RowDecodingError` prints the whole row, which is why it is not passed on.
public enum RowReadError: BBError, Equatable {
  case unreadableCell(column: String, expected: String, found: String, in: RowSource)

  public var code: String { "database.unreadable_cell" }
  public var domain: String { "Storage" }
  public var title: String {
    switch self {
    case .unreadableCell(_, _, _, let source): "A row in \(source.summary) could not be read"
    }
  }
  public var body: String {
    switch self {
    case .unreadableCell(let column, let expected, let found, let source):
      "The `\(column)` column of \(source.file) was read as \(expected) and holds \(found), "
        + "so the row it belongs to could not be read."
    }
  }
}

/// Where a cell that did not convert is reported. One logger for every store rather than one
/// per row type, which would be a logger per message.
@usableFromInline
enum CellReport {
  static let logger = Logger(label: "bluebubbles.db.rows")

  /// Store and column pairs that have already produced a warning for an unreadable cell.
  ///
  /// Once per column per store per process, because the same row is read on every page that
  /// holds it and, in chat.db, on every change-detector tick whose window covers it: a
  /// warning per read would be a warning every few seconds for one stray cell. Bounded by the
  /// number of column names.
  private static let warnedColumns = Locked<Set<String>>([])

  /// SQLite's name for what a cell holds, for a log line or an error that must not carry
  /// the value itself: a message's text is the value.
  @usableFromInline
  static func storageClass(of value: DatabaseValue) -> String {
    switch value.storage {
    case .null: "NULL"
    case .int64: "INTEGER"
    case .double: "REAL"
    case .string: "TEXT"
    case .blob: "BLOB"
    }
  }

  /// An optional cell that did not convert and is being read as NULL.
  ///
  /// Names the store, the column, the type asked for, what the cell holds and the row's key
  /// when the result carries one: enough to find the row, and none of it content.
  @usableFromInline
  static func unreadable(
    column: String, expected: String, value: DatabaseValue, in row: MappedRow
  ) {
    let source = row.source
    let first = warnedColumns.withLock { $0.insert("\(source.file)\u{0}\(column)").inserted }
    var metadata: Logger.Metadata = [
      "database": .string(source.file),
      "column": .string(column),
      "expected": .string(expected),
      "found": .string(storageClass(of: value)),
    ]
    // Read directly rather than through `optional`, which would report a bad key by calling
    // back into this function.
    if let keyColumn = source.keyColumn, row.row.hasColumn(keyColumn),
      let key = Int64.fromDatabaseValue(row.row[keyColumn] as DatabaseValue)
    {
      metadata["rowID"] = .stringConvertible(key)
    }
    let message: Logger.Message =
      "A \(source.file) cell does not hold its column's type; it is read as NULL"
    if first {
      logger.warning(message, metadata: metadata)
    } else {
      logger.debug(message, metadata: metadata)
    }
  }
}

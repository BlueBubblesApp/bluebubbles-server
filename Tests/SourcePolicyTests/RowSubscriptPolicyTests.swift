//  RowSubscriptPolicyTests
//  A database another process writes is read through `MappedRow`, never `row["x"]`.
//
//  SQLite does not enforce a column's declared type, and GRDB's typed `Row` subscript decodes
//  with `try!`, so one cell holding a type that does not convert ends the process. chat.db,
//  the sticker store and the call log are all written by Apple's processes. `MappedRow`
//  (BBPersistence) reads every cell as a `DatabaseValue` and converts it itself, so a bad
//  cell reads as NULL or throws a typed error instead.
//
//  The scan finds its own files: everything that holds the read-only handle, which is how
//  this server opens a database it does not own, together with each one's `+` extensions.
//  A new reader of a foreign store is covered the day it is written.

import BBTestCore
import Foundation
import Testing

@Suite("Foreign databases are read through MappedRow")
struct RowSubscriptPolicyTests {

  static let mappedRows = PolicyRule(
    rule: "A database another process writes is read through `MappedRow`, never a raw `Row` "
      + "subscript, which traps on a mistyped cell.",
    fix: "Read the cell through `mapRows(in:)` or `Row.mapped(in:)`.",
    home: #"Sources/BBPersistence/CLAUDE.md, "Read every cell through `MappedRow`""#)

  /// Files that hold the handle and may still subscript a row, with the reason.
  private static let exempt: [String: String] = [
    // Introspection: `PRAGMA table_info` and `sqlite_master` are SQLite's own output, whose
    // `name` and `detail` are always TEXT. No other process writes them.
    "Sources/BBPersistence/ReadOnlyDatabase.swift": "SQLite's own catalogue, always TEXT"
  ]

  /// The readers the scan must find, so a rename cannot leave it passing over nothing.
  private static let knownReaders = [
    "Sources/BBIMessage/MessageRepository.swift",
    "Sources/BBIMessage/StickerRepository.swift",
    "Sources/BBSystem/CallHistoryRepository.swift",
  ]

  @Test("No reader of a foreign database subscripts a row by column name")
  func noRawSubscripts() throws {
    let holders = try SourceScanner.swiftFiles(under: "Sources", minimum: 500)
      .filter { file in file.codeLines.contains { $0.code.contains("ReadOnlyDatabase") } }
    let readers = try holders.flatMap { try SourceScanner.family($0.path) }
      .filter { Self.exempt[$0.path] == nil }
    let paths = Set(readers.map(\.path))
    for known in Self.knownReaders {
      #expect(paths.contains(known), "\(known) no longer holds the read-only handle")
    }
    #expect(readers.count >= 10, "the scan found only \(readers.count) files")

    let pattern = try Regex(#"(\w|\$0|\))\["[A-Za-z_]+"\]"#)
    let offences = SourceScanner.offences(in: readers) { _, line in line.code.contains(pattern) }
    #expect(offences.isEmpty, Self.mappedRows.comment(offences))
  }
}

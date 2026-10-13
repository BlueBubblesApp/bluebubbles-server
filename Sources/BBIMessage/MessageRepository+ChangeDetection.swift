//  MessageRepository+ChangeDetection
//  The narrow reads the change detector and the search indexer walk: fingerprints paged by
//  date or by ROWID, when each chat was last read, each message's searchable text, which
//  ROWIDs still exist, and full rows for the few that changed.
//
//  Kept apart from `+Messages` because these run on the detector's tick rather than once per
//  request. A column added to a fingerprint is paid on every tick, and the fingerprint
//  statements' plans are asserted in `ChangeDetectorTests` so neither can start to scan.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  // MARK: - Change detection

  /// The columns the change detector compares. Everything a message can change after it
  /// is written, and nothing else: no text, no blobs, no joins.
  static let fingerprintColumns: [String] = [
    "ROWID", "guid", "date", "date_read", "date_delivered", "date_played", "date_edited",
    "date_retracted", "did_notify_recipient", "error",
  ]

  /// Where a fingerprint page stopped: the `(date, ROWID)` of its last row.
  public struct FingerprintCursor: Sendable, Hashable {
    public let date: Int64
    public let rowID: Int64

    public init(date: Int64, rowID: Int64) {
      self.date = date
      self.rowID = rowID
    }
  }

  /// Fingerprints of every message dated after `floor`, oldest first, one page at a time.
  ///
  /// Keyset-paged on `(date, ROWID)` rather than `OFFSET`: SQLite re-walks the skipped rows
  /// for every OFFSET page, so a 20-page window cost far more than 20 pages, and a row
  /// Messages inserted between two pages shifted every offset after it, duplicating or
  /// skipping a row. Resuming from the last row seen is stable and walks the index once.
  ///
  /// Narrow on purpose. The detector compares eight numbers per row; decoding the whole
  /// 70-column row with its attributed-body and payload blobs to get at them was most of
  /// what a tick cost. `messages(rowIDs:)` hydrates the few rows that actually changed.
  public func messageFingerprints(
    after floor: Date,
    resumingFrom cursor: FingerprintCursor? = nil,
    limit: Int = 1000
  ) async throws -> [MessageFingerprintRow] {
    let (sql, arguments) = fingerprintQuery(after: floor, resumingFrom: cursor, limit: limit)
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments)
        .mapRows { MessageFingerprintRow($0, dateUnit: unit) }
    }
  }

  /// Fingerprints of every message INSERTED after `rowID`, oldest first.
  ///
  /// The arrival query, where `messageFingerprints(after:)` is the sent-time query. A row's
  /// ROWID is assigned when Messages inserts it into this database; its `date` is when the
  /// sender sent it. Those diverge exactly when the Mac was offline, which is the case the
  /// date window cannot see: a message sent an hour before it lands is outside any sane
  /// recent-window and is still news.
  ///
  /// **It must be its own query, not a disjunction added to the other one.** Measured on a
  /// 421,941-row `chat.db`: `WHERE date > ? OR ROWID > ?` cannot seek two columns through
  /// one index, so SQLite degrades from `SEARCH … USING INDEX message_idx_date` to `SCAN`,
  /// walking all 421,941 index entries — 0.005 ms becomes 12.478 ms, at the detector's
  /// twice-a-second tick, on the oldest hardware this server supports.
  /// `FingerprintPlanTests` asserts the plan so that cannot be reintroduced.
  ///
  /// As its own query it is the cheapest access path SQLite has: ROWID IS the b-tree key,
  /// so this is a seek that returns nothing at all on a quiet Mac (0.002 ms measured),
  /// against a date window that re-examines the same recent rows on every tick forever.
  public func messageFingerprints(
    afterRowID rowID: Int64,
    limit: Int = 1000
  ) async throws -> [MessageFingerprintRow] {
    let (sql, arguments) = fingerprintQuery(afterRowID: rowID, limit: limit)
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments)
        .mapRows { MessageFingerprintRow($0, dateUnit: unit) }
    }
  }

  /// One message's searchable words, already resolved from wherever they live.
  public struct SearchableText: Sendable {
    public let rowID: Int64
    public let text: String
  }

  /// Messages in arrival order from a cursor, with their text resolved for the index.
  ///
  /// Resolution is the point of this living here rather than in the indexer: the `text`
  /// column is authoritative when it has anything in it, and empty on macOS 26 for almost
  /// everything, where the words are in `attributedBody`. That rule and the decoder are both
  /// this module's, and an indexer reimplementing either would be a second answer to
  /// "what does this message say".
  ///
  /// Rows that resolve to nothing are DROPPED rather than indexed empty: an attachment with
  /// no caption, a tapback, a row whose body will not decode. They are not searchable by
  /// text and a row for each would be a row per message in the index for no matches.
  ///
  /// `ROWID > ? ORDER BY ROWID ASC` seeks the integer primary key and never scans; it is the
  /// same statement shape `fingerprintQuery(afterRowID:)` uses, for the same reason.
  public func searchableText(
    afterRowID rowID: Int64, limit: Int = 500
  ) async throws -> [SearchableText] {
    let columns = profile.select(["ROWID", "text", "attributedBody"], from: .message, alias: "m")
    let bounded = min(max(1, limit), 2000)
    let rows: [(Int64, String?, Data?)] = try await database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT \(columns) FROM message m WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?",
        arguments: [rowID, bounded]
      ).map { ($0["ROWID"], $0["text"], $0["attributedBody"]) }
    }
    return rows.compactMap(Self.searchable)
  }

  /// One row's words by the same rule the wire `text` uses, `IMessageRow.universalText`, or
  /// nil when it says nothing.
  private static func searchable(_ row: (Int64, String?, Data?)) -> SearchableText? {
    let (rowID, text, blob) = row
    guard
      let words = IMessageRow.universalText(
        text: text, attributedBody: blob, logMetadata: ["rowID": .stringConvertible(rowID)]),
      !words.isEmpty
    else { return nil }
    return SearchableText(rowID: rowID, text: words)
  }

  /// The searchable text of specific rows, for re-reading a message that changed.
  ///
  /// Separate from the cursor walk because it answers a different question: that one asks
  /// "what is next", this one asks "what does THIS say now". A row that has lost its text —
  /// an unsent message — is absent from the result rather than returned empty, which is what
  /// tells the caller to remove it from the index rather than rewrite it.
  public func searchableText(rowIDs: [Int64]) async throws -> [SearchableText] {
    guard !rowIDs.isEmpty else { return [] }
    let columns = profile.select(["ROWID", "text", "attributedBody"], from: .message, alias: "m")
    // Literal integers: these are `Int64` values this server read out of chat.db or its own
    // index, never anything a client sent. The same reasoning as the
    // `resolvedSearches` splice in `MessageQueryPlan`.
    let list = rowIDs.map(String.init).joined(separator: ",")
    let rows: [(Int64, String?, Data?)] = try await database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT \(columns) FROM message m WHERE m.ROWID IN (\(list))"
      ).map { ($0["ROWID"], $0["text"], $0["attributedBody"]) }
    }
    return rows.compactMap(Self.searchable)
  }

  /// Which `message.ROWID`s in a window still exist.
  ///
  /// For reconciling anything built by walking ROWIDs upward against a table rows can leave.
  /// A window rather than the whole table, because the caller compares it against a set of
  /// the same shape and neither wants four hundred thousand integers in memory at once.
  ///
  /// `BETWEEN` on the integer primary key is a range scan of the b-tree and reads only the
  /// keys, so the cost is the window and not the table.
  public func messageRowIDs(from lower: Int64, through upper: Int64) async throws -> Set<Int64> {
    guard upper >= lower else { return [] }
    return try await database.read { db in
      Set(
        try Int64.fetchAll(
          db, sql: "SELECT ROWID FROM message WHERE ROWID BETWEEN ? AND ?",
          arguments: [lower, upper]))
    }
  }

  /// The `guid` at a given ROWID, or nil when no row has that id any more.
  ///
  /// For asking "is this the same database I was built from". `message.ROWID` is
  /// `AUTOINCREMENT`, so an id is never reused within one file: a DIFFERENT guid back from
  /// this is proof the file was replaced, and nil only says that one message is gone.
  ///
  /// An integer-primary-key seek, the same shape and cost as `maximumMessageRowID`.
  public func messageGUID(rowID: Int64) async throws -> String? {
    try await database.read { db in
      try String.fetchOne(
        db, sql: "SELECT guid FROM message WHERE ROWID = ?", arguments: [rowID])
    }
  }

  /// The oldest row still in the table, as the pair that identifies this database.
  ///
  /// The LOWEST id rather than the highest, because the point is to pick a row that will
  /// still be there later: the newest message is the one most likely to be deleted, undone
  /// or replaced within the minute.
  public func oldestMessageIdentity() async throws -> (rowID: Int64, guid: String)? {
    try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT ROWID, guid FROM message ORDER BY ROWID ASC LIMIT 1"),
        let guid = row["guid"] as String?
      else { return nil }
      return (row["ROWID"] as Int64, guid)
    }
  }

  /// The highest ROWID in the table, for detecting a `chat.db` that was replaced.
  ///
  /// `SEARCH message` on the integer primary key — the last entry of the b-tree, 0.0027 ms
  /// measured. Not a count and not a scan.
  public func maximumMessageRowID() async throws -> Int64? {
    try await database.read { db in
      try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message")
    }
  }

  /// Every chat last read after `floor`, oldest read first.
  ///
  /// What `chat-read-status-changed` is detected from. Three columns, never the chat row: the
  /// `properties` blob is in that row and the detector compares one number.
  ///
  /// `SCAN chat`, because Apple indexes nothing on this column and we cannot add an index.
  /// That is affordable where the same scan of `message` is not: `chat` is one row per
  /// conversation, and on a 487-chat `chat.db` this statement measured 0.026 ms when it
  /// returns nothing, which is every tick on which nobody read anything.
  ///
  /// Empty, not an error, on a schema without the column. Every supported macOS has it.
  public func chatReadMarks(readAfter floor: Date) async throws -> [ChatReadMark] {
    guard let (sql, arguments) = chatReadQuery(readAfter: floor) else { return [] }
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments)
        .mapRows { ChatReadMark($0, dateUnit: unit) }
    }
  }

  /// The statement behind `chatReadMarks(readAfter:)`, or nil where the column is absent.
  func chatReadQuery(
    readAfter floor: Date
  ) -> (sql: String, arguments: [(any DatabaseValueConvertible)?])? {
    guard profile.has("last_read_message_timestamp", on: .chat) else { return nil }
    let sql = """
      SELECT c.ROWID, c.guid, c.last_read_message_timestamp FROM chat c
      WHERE c.last_read_message_timestamp > ?
      ORDER BY c.last_read_message_timestamp ASC
      """
    return (sql, [AppleTimestamp.from(floor, unit: dateUnit).rawValue])
  }

  /// The statement behind `messageFingerprints(afterRowID:)`, exposed for the plan test.
  func fingerprintQuery(
    afterRowID rowID: Int64,
    limit: Int
  ) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
    let columns = profile.select(Self.fingerprintColumns, from: .message, alias: "m")
    // No `date` predicate at all, deliberately: adding one is what costs the index seek.
    let sql =
      "SELECT \(columns) FROM message m WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?"
    return (sql, [rowID, min(max(1, limit), 1000)])
  }

  /// The statement behind `messageFingerprints`, exposed so a test can ask SQLite for its
  /// plan: both page shapes must walk `message_idx_date` and neither may sort.
  func fingerprintQuery(
    after floor: Date,
    resumingFrom cursor: FingerprintCursor?,
    limit: Int
  ) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
    let columns = profile.select(Self.fingerprintColumns, from: .message, alias: "m")
    var sql = "SELECT \(columns) FROM message m WHERE "
    var arguments: [(any DatabaseValueConvertible)?] = []
    if let cursor {
      // One range scan from the cursor's date; only rows sharing that exact date are
      // re-examined, and the ROWID test drops the ones already seen.
      sql += "m.date >= ? AND (m.date > ? OR m.ROWID > ?)"
      arguments = [cursor.date, cursor.date, cursor.rowID]
    } else {
      sql += "m.date > ?"
      arguments = [AppleTimestamp.from(floor, unit: dateUnit).rawValue]
    }
    // ROWID is the index's implicit trailing key, so this order comes straight off
    // `message_idx_date` with no temp b-tree.
    sql += " ORDER BY m.date ASC, m.ROWID ASC LIMIT ?"
    arguments.append(min(max(1, limit), 1000))
    return (sql, arguments)
  }

  /// Full rows for the given ROWIDs, oldest first. Chunked so a large changed set cannot
  /// exceed SQLite's bound-parameter limit.
  public func messages(rowIDs: [Int64]) async throws -> [IMessageRow] {
    guard !rowIDs.isEmpty else { return [] }
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let unit = dateUnit
    var collected: [IMessageRow] = []
    for start in stride(from: 0, to: rowIDs.count, by: Self.hydrationChunk) {
      let chunk = Array(rowIDs[start..<min(start + Self.hydrationChunk, rowIDs.count)])
      let placeholders = SQLPlaceholders.list(chunk.count)
      let sql =
        "SELECT \(columns) FROM message m WHERE m.ROWID IN (\(placeholders)) ORDER BY m.date ASC"
      let statementArguments = StatementArguments(chunk)
      collected += try await database.read { db in
        try Row.fetchAll(db, sql: sql, arguments: statementArguments)
          .mapRows { IMessageRow($0, dateUnit: unit) }
      }
    }
    return collected
  }
}

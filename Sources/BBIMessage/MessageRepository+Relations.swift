//  MessageRepository+Relations
//  What hangs off a message: its attachments, and the handles, chats and attachments for a
//  whole page of messages at once.
//
//  The bulk forms answer a page in a few chunked statements rather than three per message,
//  which serialised through the single database queue and blocked every other client for
//  the duration. The section comment below has the measurement.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  // MARK: - Attachments

  public func attachments(forMessageGUID guid: String) async throws -> [AttachmentRow] {
    let columns = profile.select(Self.attachmentColumns, from: .attachment, alias: "a")
    let sql = """
      SELECT \(columns) FROM attachment a
      JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
      JOIN message m ON m.ROWID = maj.message_id
      WHERE m.guid = ?
      """
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: [guid])
        .mapRows { AttachmentRow($0, dateUnit: unit) }
    }
  }

  public func attachment(guid: String) async throws -> AttachmentRow? {
    let columns = profile.select(Self.attachmentColumns, from: .attachment, alias: "a")
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM attachment a WHERE a.guid = ?", arguments: [guid]
      )?.mapped { AttachmentRow($0, dateUnit: unit) }
    }
  }

  // MARK: - Relations, in bulk
  //
  // A page of messages used to ask for its relations one message at a time: a handle lookup,
  // a chats query and an attachments query EACH, so a 1000-row page ran 3,000 statements --
  // measured at 143ms, 1.6 times the cost of fetching the rows themselves, and all of it
  // serialised through the single database queue, so it head-of-line blocked every other
  // client for the duration. Each plan was fine on its own; the COUNT was the problem.
  //
  // These answer the same questions for a whole page. Chunked at `hydrationChunk`, because
  // SQLite's default parameter limit is 999 and the read routes accept a 1000-row page.

  /// Handles by ROWID, for a page's worth of messages.
  public func handles(rowIDs: [Int64]) async throws -> [Int64: HandleRow] {
    let wanted = Array(Set(rowIDs))
    guard !wanted.isEmpty else { return [:] }
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    var result: [Int64: HandleRow] = [:]
    for chunk in wanted.chunked(into: Self.hydrationChunk) {
      let placeholders = SQLPlaceholders.list(chunk.count)
      let sql = "SELECT \(columns) FROM handle h WHERE h.ROWID IN (\(placeholders))"
      let statementArguments = StatementArguments(chunk)
      let rows = try await database.read { db in
        try Row.fetchAll(db, sql: sql, arguments: statementArguments).mapRows { HandleRow($0) }
      }
      for row in rows { result[row.rowID] = row }
    }
    return result
  }

  /// Chats by message GUID. Many-to-many: a message can be in several.
  ///
  /// Ordered by `c.ROWID` so a message's chats come back in a defined order. The per-message
  /// query it replaces declared none and got this one from its plan, which was checked
  /// against the real database rather than assumed.
  public func chats(forMessageGUIDs guids: [String]) async throws -> [String: [ChatRow]] {
    try await grouped(
      guids: guids,
      columns: profile.select(Self.chatColumns, from: .chat, alias: "c"),
      from: """
        FROM chat c
        JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id
        """,
      orderBy: "c.ROWID"
    ) { ChatRow($0) }
  }

  /// Attachments by message GUID, in `a.ROWID` order — the order the per-message query
  /// already returned, verified against the real database before this replaced it.
  public func attachments(forMessageGUIDs guids: [String]) async throws -> [String:
    [AttachmentRow]]
  {
    let unit = dateUnit
    return try await grouped(
      guids: guids,
      columns: profile.select(Self.attachmentColumns, from: .attachment, alias: "a"),
      from: """
        FROM attachment a
        JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
        JOIN message m ON m.ROWID = maj.message_id
        """,
      orderBy: "a.ROWID"
    ) { AttachmentRow($0, dateUnit: unit) }
  }

  /// The shared shape: select the message GUID alongside the relation's columns, then group.
  ///
  /// The key column is aliased `bb_message_guid` because both `chat` and `attachment` have a
  /// `guid` of their own, and a duplicate name would resolve to whichever came first.
  private func grouped<T: Sendable>(
    guids: [String],
    columns: String,
    from: String,
    orderBy: String,
    make: @escaping @Sendable (MappedRow) -> T
  ) async throws -> [String: [T]] {
    let wanted = Array(Set(guids))
    guard !wanted.isEmpty else { return [:] }
    var result: [String: [T]] = [:]
    for chunk in wanted.chunked(into: Self.hydrationChunk) {
      let placeholders = SQLPlaceholders.list(chunk.count)
      let sql = """
        SELECT m.guid AS bb_message_guid, \(columns) \(from)
        WHERE m.guid IN (\(placeholders)) ORDER BY m.guid, \(orderBy)
        """
      let statementArguments = StatementArguments(chunk)
      let pairs = try await database.read { db in
        try Row.fetchAll(db, sql: sql, arguments: statementArguments)
          .mapRows { (($0.row["bb_message_guid"] as String?) ?? "", make($0)) }
      }
      for (guid, value) in pairs { result[guid, default: []].append(value) }
    }
    return result
  }
}

//  MessageRepository+Activity
//  How many messages moved, when, in which conversations, and which conversations are new:
//  the reads behind Home's message-flow charts.
//
//  **What counts as a message here.** A row with `item_type = 0` and no associated message:
//  something a person typed or sent. Tapbacks, group renames and participant changes are all
//  rows in `message` too, and counting them would make a chat where three
//  people reacted to one photo look four times busier than it was. So these totals are
//  deliberately NOT the `/message/count` total, which counts every row and is wire contract.
//
//  **Days are the caller's.** A day is a local calendar day, and what "local" means (the
//  zone, its daylight-saving transitions) belongs to the caller, which holds a `Calendar`. So
//  the caller passes the day boundaries it wants and SQLite only counts between them. The
//  obvious alternative, SQLite's `'localtime'` modifier, reads the process's zone from the C
//  library, which a test cannot pin without mutating global state under a parallel runner.
//
//  **Every query is bounded by `m.date` and walks `message_idx_date`**, which every `chat.db`
//  since High Sierra has. The day list is the OUTER loop (`CROSS JOIN` is SQLite's order
//  hint), so each day is one index range scan, and a year is 366 of them rather than a scan
//  of the whole table.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  /// One local day, as the caller's calendar draws it.
  public struct ActivityDay: Sendable, Equatable {
    public let start: Date
    /// Exclusive.
    public let end: Date
    /// Seconds east of UTC at `start`, for placing a message in its local hour. A day that
    /// contains a daylight-saving transition puts the hour after it one hour out; a heatmap
    /// can afford that, and the day totals are unaffected because they are bounded by `start`
    /// and `end`, not by the offset.
    public let utcOffset: Int

    public init(start: Date, end: Date, utcOffset: Int) {
      self.start = start
      self.end = end
      self.utcOffset = utcOffset
    }
  }

  /// A count of messages in one hour of one day, one direction and one service.
  public struct ActivityCell: Sendable, Equatable {
    /// Index into the `days` the query was given.
    public let day: Int
    /// Local hour of day, `0..<24`.
    public let hour: Int
    public let isFromMe: Bool
    /// `iMessage`, `SMS`, `RCS`; empty when the row has none.
    public let service: String
    public let count: Int

    public init(day: Int, hour: Int, isFromMe: Bool, service: String, count: Int) {
      self.day = day
      self.hour = hour
      self.isFromMe = isFromMe
      self.service = service
      self.count = count
    }
  }

  /// Messages per day, hour, direction and service across `days`.
  ///
  /// One query rather than three (per day, per hour, per service) because they are the same
  /// rows grouped three ways, and the grouping is cheap once they are in hand: a year of a
  /// busy account is a few thousand cells.
  public func messageActivity(days: [ActivityDay]) async throws -> [ActivityCell] {
    guard !days.isEmpty else { return [] }
    // Chunked so a long range stays inside SQLite's bound-parameter limit with room to
    // spare: four parameters per day.
    var cells: [ActivityCell] = []
    for (chunkIndex, chunk) in days.chunked(into: 200).enumerated() {
      let base = chunkIndex * 200
      let values = SQLPlaceholders.rows(chunk.count, width: 4)
      let unixSeconds = "m.date / \(dateUnit.ticksPerSecond) + \(Int(appleEpochOffset))"
      let sql = """
        WITH days(idx, start, finish, offset) AS (VALUES \(values))
        SELECT d.idx AS day,
               ((\(unixSeconds) + d.offset) % 86400) / 3600 AS hour,
               m.is_from_me AS from_me,
               COALESCE(m.service, '') AS service,
               COUNT(*) AS total
        FROM days d
        CROSS JOIN message m ON m.date >= d.start AND m.date < d.finish
        WHERE \(Self.isPersonMessageClause)
        GROUP BY day, hour, from_me, service
        """
      var arguments: [(any DatabaseValueConvertible)?] = []
      for (offset, day) in chunk.enumerated() {
        arguments.append(base + offset)
        arguments.append(AppleTimestamp.from(day.start, unit: dateUnit).rawValue)
        arguments.append(AppleTimestamp.from(day.end, unit: dateUnit).rawValue)
        arguments.append(day.utcOffset)
      }
      let statementArguments = StatementArguments(arguments)
      cells += try await database.read { db in
        try Row.fetchAll(db, sql: sql, arguments: statementArguments).map { row in
          ActivityCell(
            day: row["day"],
            hour: row["hour"],
            isFromMe: row["from_me"] ?? false,
            service: row["service"] ?? "",
            count: row["total"])
        }
      }
    }
    return cells
  }

  /// A conversation and how many messages it carried in a window.
  public struct ChatActivity: Sendable, Equatable {
    public let chatRowID: Int64
    public let guid: String
    public let displayName: String?
    public let participants: [String]
    /// From `chat.style` (43), which is how the database says it, rather than from the GUID's
    /// separator, which is a spelling.
    public let isGroup: Bool
    public let count: Int

    public init(
      chatRowID: Int64, guid: String, displayName: String?, participants: [String],
      isGroup: Bool, count: Int
    ) {
      self.chatRowID = chatRowID
      self.guid = guid
      self.displayName = displayName
      self.participants = participants
      self.isGroup = isGroup
      self.count = count
    }
  }

  /// The busiest conversations in `[start, end)`, busiest first.
  ///
  /// A conversation stored as more than one chat row (the same address under an `iMessage;`
  /// and an `SMS;` GUID, on a release that still has prefixes) is ONE entry, merged on
  /// `ChatGUID.identityKey`: two rows for one person would put them in the list twice with
  /// half their messages each, and possibly push somebody else out of it.
  public func busiestChats(from start: Date, to end: Date, limit: Int) async throws
    -> [ChatActivity]
  {
    guard limit > 0, start < end else { return [] }
    // Over-fetched, because merging can fold two rows into one and a limit applied before
    // the merge would return fewer than asked for.
    let sql = """
      SELECT c.ROWID AS chat_id, c.guid AS guid, c.display_name AS display_name,
             c.style AS style, COUNT(*) AS total
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      WHERE m.date >= ? AND m.date < ?
        AND \(Self.isPersonMessageClause)
        AND \(Self.hasParticipantsClause)
      GROUP BY c.ROWID
      ORDER BY total DESC, c.ROWID
      LIMIT ?
      """
    let arguments = StatementArguments([
      AppleTimestamp.from(start, unit: dateUnit).rawValue,
      AppleTimestamp.from(end, unit: dateUnit).rawValue,
      Int64(limit * 3),
    ])
    let tallies = try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: arguments).map(ChatTally.init(row:))
    }
    let busiest = Array(
      Self.mergedByConversation(tallies, guid: \.guid) { $0.merged(with: $1) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.chatRowID < $1.chatRowID }
        .prefix(limit))

    // Participants only for what is shown. A merged entry keeps its first row's ROWID, so
    // these are that row's participants.
    let participants = try await participants(forChatRowIDs: busiest.map(\.chatRowID))
    return busiest.map { tally in
      ChatActivity(
        chatRowID: tally.chatRowID, guid: tally.guid, displayName: tally.displayName,
        participants: (participants[tally.chatRowID] ?? []).map(\.id),
        isGroup: tally.isGroup, count: tally.count)
    }
  }

  /// A conversation whose first message fell inside a window.
  public struct NewChat: Sendable, Equatable {
    public let chatRowID: Int64
    public let guid: String
    public let displayName: String?
    public let participants: [String]
    public let isGroup: Bool
    /// When its first message was sent or received.
    public let started: Date
    /// Messages since, inside the window.
    public let count: Int

    public init(
      chatRowID: Int64, guid: String, displayName: String?, participants: [String],
      isGroup: Bool, started: Date, count: Int
    ) {
      self.chatRowID = chatRowID
      self.guid = guid
      self.displayName = displayName
      self.participants = participants
      self.isGroup = isGroup
      self.started = started
      self.count = count
    }
  }

  /// Conversations that began in `[start, end)`, newest first.
  ///
  /// "Began" means no person message before `start` in ANY row of the conversation. A
  /// person whose `iMessage;` chat is years old and whose `SMS;` twin appeared this week has
  /// not become a new conversation, and the old twin need not have said anything in the
  /// window, so the probe cannot be limited to the rows the outer query sees.
  ///
  /// Three steps, each linear. The outer query groups the window's messages by chat row.
  /// The twins of every active conversation are then found in Swift, from one pass over
  /// `chat`'s `ROWID` and `guid` (two columns; the table is small) matched on
  /// `ChatGUID.identityKey`, the one comparison rule 3 allows, so a legacy prefix, `any;`
  /// and a difference in address case all resolve to the same conversation. Last, one
  /// `EXISTS` per twin row asks whether anything person-sent precedes the window, walking
  /// that chat's join rows in `ROWID` order, which is close enough to date order that an old
  /// chat answers on its first row. The first version spelled the twin match in SQL as a
  /// `substr` of every `chat` row for every active chat, which no index can serve and which
  /// grows as active chats times all chats.
  public func newChats(from start: Date, to end: Date, limit: Int) async throws -> [NewChat] {
    guard limit > 0, start < end else { return [] }
    let sql = """
      SELECT c.ROWID AS chat_id, c.guid AS guid, c.display_name AS display_name,
             c.style AS style, MIN(m.date) AS first_date, COUNT(*) AS total
      FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      JOIN chat c ON c.ROWID = cmj.chat_id
      WHERE m.date >= ? AND m.date < ?
        AND \(Self.isPersonMessageClause)
        AND \(Self.hasParticipantsClause)
      GROUP BY c.ROWID
      """
    let startStamp = AppleTimestamp.from(start, unit: dateUnit).rawValue
    let arguments = StatementArguments([
      startStamp, AppleTimestamp.from(end, unit: dateUnit).rawValue,
    ])
    let unit = dateUnit
    let rows: [(tally: ChatTally, started: Date)] = try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
        guard let started = AppleTimestamp.column(row["first_date"], unit: unit)?.date else {
          return nil
        }
        return (ChatTally(row: row), started)
      }
    }
    guard !rows.isEmpty else { return [] }

    // Every chat row that names one of the active conversations, the active rows included.
    let activeKeys = Set(rows.map { Self.conversationKey($0.tally.guid) })
    let twins: [(rowID: Int64, key: String)] = try await database.read { db in
      try Row.fetchAll(db, sql: "SELECT ROWID, guid FROM chat").compactMap { row in
        let key = Self.conversationKey(row["guid"])
        return activeKeys.contains(key) ? (row["ROWID"], key) : nil
      }
    }

    // The conversations with a person message before the window, in any of their rows.
    var earlier = Set<String>()
    for chunk in twins.chunked(into: 500) {
      let values = SQLPlaceholders.rows(chunk.count, width: 1)
      let probe = """
        WITH twins(chat_id) AS (VALUES \(values))
        SELECT chat_id FROM twins
        WHERE EXISTS (
          SELECT 1 FROM chat_message_join earlier
          JOIN message e ON e.ROWID = earlier.message_id
          WHERE earlier.chat_id = twins.chat_id
            AND e.date < ?
            AND e.item_type = 0 AND COALESCE(e.associated_message_type, 0) = 0
        )
        """
      var probeArguments: [(any DatabaseValueConvertible)?] = chunk.map { $0.rowID }
      probeArguments.append(startStamp)
      let statementArguments = StatementArguments(probeArguments)
      let keyByRowID = Dictionary(uniqueKeysWithValues: chunk.map { ($0.rowID, $0.key) })
      let withEarlier = try await database.read { db in
        try Int64.fetchAll(db, sql: probe, arguments: statementArguments)
      }
      for rowID in withEarlier {
        if let key = keyByRowID[rowID] { earlier.insert(key) }
      }
    }

    // Twins that are both active in the window are one entry with one count.
    let merged = Self.mergedByConversation(rows, guid: \.tally.guid) { existing, twin in
      (existing.tally.merged(with: twin.tally), min(existing.started, twin.started))
    }
    let began = merged.filter { !earlier.contains(Self.conversationKey($0.tally.guid)) }
    let newestFirst = began.sorted { lhs, rhs in
      if lhs.started != rhs.started { return lhs.started > rhs.started }
      return lhs.tally.chatRowID < rhs.tally.chatRowID
    }
    let new = Array(newestFirst.prefix(limit))

    // Participants only for what is shown, which is at most `limit` chats.
    let participants = try await participants(forChatRowIDs: new.map(\.tally.chatRowID))
    return new.map { chat in
      NewChat(
        chatRowID: chat.tally.chatRowID, guid: chat.tally.guid,
        displayName: chat.tally.displayName,
        participants: (participants[chat.tally.chatRowID] ?? []).map(\.id),
        isGroup: chat.tally.isGroup, started: chat.started, count: chat.tally.count)
    }
  }

  /// One chat row's share of a window: the columns `busiestChats` and `newChats` both select
  /// (`chat_id`, `guid`, `display_name`, `style`, `total`), read one way for both.
  ///
  /// An empty display name is read as none HERE, when the row is read, rather than when the
  /// entry is built. A merge then falls through an empty name to its twin's and never adopts
  /// an empty one: a chat row with no name stores `''` as often as NULL.
  struct ChatTally: Sendable, Equatable {
    let chatRowID: Int64
    let guid: String
    let displayName: String?
    /// From `chat.style` (43), which is how the database says it, rather than from the
    /// GUID's separator, which is a spelling.
    let isGroup: Bool
    let count: Int

    init(chatRowID: Int64, guid: String, displayName: String?, isGroup: Bool, count: Int) {
      self.chatRowID = chatRowID
      self.guid = guid
      self.displayName = (displayName?.isEmpty ?? true) ? nil : displayName
      self.isGroup = isGroup
      self.count = count
    }

    init(row: Row) {
      self.init(
        chatRowID: row["chat_id"], guid: row["guid"], displayName: row["display_name"],
        isGroup: (row["style"] as Int?) == MessageRepository.groupChatStyle,
        count: row["total"])
    }

    /// This entry with a twin row folded in: the first row's identity and kind, the first
    /// name either of them has, and both counts.
    func merged(with twin: ChatTally) -> ChatTally {
      ChatTally(
        chatRowID: chatRowID, guid: guid, displayName: displayName ?? twin.displayName,
        isGroup: isGroup, count: count + twin.count)
    }
  }

  /// Folds the rows of one conversation into one entry, keeping the order in which each
  /// conversation first appears.
  ///
  /// A conversation stored as more than one chat row (the same address under an `iMessage;`
  /// and an `SMS;` GUID, on a release that still has prefixes) would otherwise be listed
  /// once per row, with its messages split between them.
  static func mergedByConversation<Entry>(
    _ entries: [Entry], guid: KeyPath<Entry, String>, merge: (Entry, Entry) -> Entry
  ) -> [Entry] {
    var merged: [Entry] = []
    var positionByKey: [String: Int] = [:]
    for entry in entries {
      let key = conversationKey(entry[keyPath: guid])
      if let position = positionByKey[key] {
        merged[position] = merge(merged[position], entry)
      } else {
        positionByKey[key] = merged.count
        merged.append(entry)
      }
    }
    return merged
  }

  /// What makes two chat rows one conversation: `ChatGUID.identityKey`, or the GUID itself
  /// for a spelling the parser does not recognise.
  static func conversationKey(_ guid: String) -> String {
    ChatGUID(guid)?.identityKey ?? guid
  }

  /// `chat.style` for a group conversation; 45 is one-to-one.
  static let groupChatStyle = 43

  /// Something a person sent: not a tapback (an associated message), not a group event
  /// (a non-zero `item_type`).
  static let isPersonMessageClause =
    "m.item_type = 0 AND COALESCE(m.associated_message_type, 0) = 0"
}

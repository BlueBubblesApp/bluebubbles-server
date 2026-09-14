//  MessageRepository
//  Read-only access to chat.db.
//
//  Raw SQL behind typed request structs rather than an ORM, because Apple owns this schema
//  and changes it per release: an entity model forces version branching into the type
//  definitions.
//
//  Two rules hold everywhere in this file:
//    - Never SELECT *. A column that vanished takes the query with it, and Sequoia removes
//      a table Sonoma has.
//    - Never widen a query to avoid a join. We cannot add indexes, so a query that misses
//      the ones Messages.app ships full-scans `message`, which is the worst case on the old
//      hardware this targets.
//
//  See `.claude/docs/database.md`.

import BBCore
import BBPersistence
import Foundation
import GRDB

public struct MessageRepository: Sendable {

  private let database: ReadOnlyDatabase
  private let profile: SchemaProfile

  /// Whether this database's `chat_message_join.message_date` can order a chat's messages.
  /// Probed once, lazily; see `joinDatesCanOrderAChat()`.
  private let joinDates = JoinDateSupport()

  /// Counts, held against the commit counter that produced them. See `messageCount`.
  private let counts = CountCache()

  /// Balloon artwork by bundle id. See `balloonIcon`.
  private let balloonIcons = BalloonIconCache()

  /// Chat GUID to the ROWIDs it names. See `chatRowIDs(for:)`.
  private let chatRowIDCache = CountCache()

  public init(database: ReadOnlyDatabase, profile: SchemaProfile) {
    self.database = database
    self.profile = profile
  }

  private var dateUnit: AppleTimestamp.Unit { profile.dateUnit }

  /// Whether anything was committed to chat.db, as a comparable token. See
  /// `ReadOnlyDatabase.changeToken()`.
  public func changeToken() async throws -> Int {
    try await database.changeToken()
  }

  // MARK: - Column sets
  //
  // Requested columns, filtered to what this schema actually has. Ordered roughly as the
  // serializer needs them so the mapping below reads top to bottom.

  static let messageColumns: [String] = [
    "ROWID", "guid", "text", "replace", "service_center", "handle_id", "subject",
    "country", "attributedBody", "version", "type", "service", "account", "account_guid",
    "error", "date", "date_read", "date_delivered", "is_delivered", "is_finished",
    "is_emote", "is_from_me", "is_empty", "is_delayed", "is_auto_reply", "is_prepared",
    "is_read", "is_system_message", "is_sent", "has_dd_results", "is_service_message",
    "is_forward", "was_downgraded", "is_archive", "cache_has_attachments",
    "cache_roomnames", "was_data_detected", "was_deduplicated", "is_audio_message",
    "is_played", "date_played", "item_type", "other_handle", "group_title",
    "group_action_type", "share_status", "share_direction", "is_expirable",
    "expire_state", "message_action_type", "message_source", "associated_message_guid",
    "associated_message_type", "associated_message_emoji", "schedule_type", "schedule_state",
    "balloon_bundle_id", "payload_data",
    "expressive_send_style_id", "associated_message_range_location",
    "associated_message_range_length", "time_expressive_send_played",
    "message_summary_info", "is_corrupt", "is_spam", "thread_originator_guid",
    "thread_originator_part", "date_edited", "date_retracted", "part_count",
    "was_delivered_quietly", "did_notify_recipient", "reply_to_guid",
  ]

  static let chatColumns: [String] = [
    "ROWID", "guid", "style", "state", "chat_identifier", "service_name", "room_name",
    "account_login", "is_archived", "last_addressed_handle", "display_name", "group_id",
    "is_filtered", "successful_query", "last_read_message_timestamp",
    // A binary-plist blob, decoded on the way out exactly like `attributedBody`. It
    // carries `lastSeenMessageGuid`, `shouldForceToSMS` and the thread-response count;
    // without it `chat.properties` is an empty array on every chat.
    "properties",
  ]

  static let handleColumns: [String] = [
    "ROWID", "id", "country", "service", "uncanonicalized_id", "person_centric_id",
  ]

  static let attachmentColumns: [String] = [
    // `start_date` is deliberately absent: it was selected here and mapped by no row type,
    // so every attachment read paid for a column nothing could see.
    "ROWID", "guid", "created_date", "filename", "uti", "mime_type",
    "transfer_state", "is_outgoing", "transfer_name", "total_bytes", "is_sticker",
    "hide_attachment", "original_guid",
  ]

  // MARK: - Messages

  public struct MessageQuery: Sendable {
    public var chatGUID: String?
    public var after: Date?
    public var before: Date?
    public var limit: Int
    public var offset: Int
    public var ascending: Bool
    public var includeAttachments: Bool
    /// Restricts to messages the account sent. Backs GET /message/count/me.
    public var onlyFromMe: Bool
    /// Restricts to messages that belong to at least one chat.
    ///
    /// Set when a caller asks for chats. The reference switches to an INNER JOIN in that
    /// case (`else if (withChats)`), so asking for chats also filters out messages that
    /// are in none: 3,739 of them on this development database, which is what made its
    /// `metadata.total` disagree with its own `/message/count`. Reproduced rather than
    /// tidied, because a message in no chat cannot be shown in any conversation.
    public var requiresChat: Bool

    /// The client's `where` clause, understood. See `MessageFilter`.
    ///
    /// Applied by `messagePredicate`, so the listing and its `total` are filtered by the
    /// same conditions: a count that ignored the filter is what made the app's incremental
    /// sync page the whole database.
    public var filters: [MessageFilter]

    /// `minRowId` and `maxRowId`, which the three count routes accept.
    ///
    /// Inclusive on both ends, as the reference's are (`message.ROWID >= :minRowId`,
    /// `message.ROWID <= :maxRowId`). Deliberately NOT expressed as `MessageFilter` cases:
    /// those are the client's `where` clause, an allowlisted passthrough, where these are
    /// first-class query parameters the route declares. Folding them together would mean a
    /// `where`-less request carrying a filter, and `>=` is not a case that clause has.
    public var minRowID: Int64?
    public var maxRowID: Int64?

    /// `chatGUID` resolved to ROWIDs, when the caller has done so.
    ///
    /// NOT part of the public initialiser: it is a derived value the repository fills in,
    /// not something a caller states. See `messagePredicate` for why it matters.
    var resolvedChatRowIDs: [Int64]?

    /// Whether this query is "every message in one conversation", with no condition that
    /// needs a column of `message`.
    ///
    /// `requiresChat` is not consulted: it only adds an EXISTS when `chatGUID` is nil, and
    /// `dateField` only matters when `after` or `before` is set. Written as a list of what
    /// must be ABSENT rather than a flag, so a new condition added to `messagePredicate`
    /// without a thought here fails the parity test rather than silently counting wrong.
    var countsAWholeChat: Bool {
      chatGUID != nil && after == nil && before == nil && !onlyFromMe && filters.isEmpty
        && minRowID == nil && maxRowID == nil
    }

    /// Which dates `after`/`before` compare against.
    public enum DateField: Sendable {
      /// `message.date`: when it was sent. The default, and what every listing uses.
      case created
      /// `date_delivered` OR `date_read`: what `GET /message/count/updated` asks about.
      ///
      /// A mode on the shared query rather than its own SQL, because the route accepts
      /// `chatGuid`, `minRowId` and `maxRowId` too and a second hand-written statement
      /// could not honour them. That is exactly how it came to ignore all three.
      case updated
    }
    public var dateField: DateField

    public init(
      chatGUID: String? = nil,
      after: Date? = nil,
      before: Date? = nil,
      limit: Int = 100,
      offset: Int = 0,
      ascending: Bool = false,
      includeAttachments: Bool = true,
      onlyFromMe: Bool = false,
      requiresChat: Bool = false,
      filters: [MessageFilter] = [],
      minRowID: Int64? = nil,
      maxRowID: Int64? = nil,
      dateField: DateField = .created
    ) {
      self.chatGUID = chatGUID
      self.after = after
      self.before = before
      // Matches the existing cap. A client asking for more gets 1000.
      self.limit = min(max(1, limit), 1000)
      self.offset = max(0, offset)
      self.ascending = ascending
      self.includeAttachments = includeAttachments
      self.onlyFromMe = onlyFromMe
      self.requiresChat = requiresChat
      self.filters = filters
      self.minRowID = minRowID
      self.maxRowID = maxRowID
      self.dateField = dateField
    }
  }

  /// The FROM and WHERE shared by the listing and its count.
  ///
  /// Extracted rather than written twice: a count whose predicate has drifted from the
  /// listing it counts produces a total that never agrees with the pages, which is the
  /// classic and very confusing pagination bug.
  private func messagePredicate(
    _ query: MessageQuery
  ) -> (clause: String, arguments: [(any DatabaseValueConvertible)?]) {
    var sql = ""
    var arguments: [(any DatabaseValueConvertible)?] = []
    var conditions: [String] = []

    // Joined only when scoping to a chat. Joining unconditionally would multiply rows
    // for a message in several chats and force a DISTINCT.
    //
    // Scoped by `cmj.chat_id` when the GUID has already been resolved to ROWIDs, and that
    // is not a tidy-up: `chat_message_join_idx_message_date_id_chat_id` leads on `chat_id`,
    // so ONE chat_id lets SQLite walk the index in date order and stop at the limit, while
    // `c.guid IN (?, ?, ?)` makes it gather rows for several chats and sort them. The
    // candidate list is always three spellings -- `any;`, `iMessage;`, `SMS;` -- so in
    // production the sort was always there. Measured on a 54,777-message conversation:
    // 52ms through the GUID list, 1ms scoped by chat_id, for the same hundred rows.
    if let chatRowIDs = query.resolvedChatRowIDs, !chatRowIDs.isEmpty {
      sql += "\n JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
      let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ", ")
      conditions.append("cmj.chat_id IN (\(placeholders))")
      arguments.append(contentsOf: chatRowIDs.map { $0 as (any DatabaseValueConvertible)? })
    } else if let chatGUID = query.chatGUID {
      sql += """
         JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
         JOIN chat c ON c.ROWID = cmj.chat_id
        """
      let chat = Self.chatCondition(chatGUID)
      conditions.append(chat.condition)
      arguments.append(contentsOf: chat.arguments)
    }

    // INCLUSIVE, which is what the reference compares with (`message.date >= :after`,
    // `message.date <= :before`) and this did not: it used `>` and `<`, so a message whose
    // timestamp is exactly the boundary was dropped. That is the dangerous direction for
    // the incremental sync, which passes its last sync time as `after`: a message landing
    // on that millisecond was never sent and never asked for again.
    if let after = query.after, let before = query.before {
      conditions.append(Self.dateCondition(query.dateField, bounded: true))
      arguments.append(
        contentsOf: Self.dateArguments(
          query.dateField, after: after, before: before, unit: dateUnit))
    } else if let after = query.after {
      conditions.append(Self.dateCondition(query.dateField, bounded: false, isAfter: true))
      arguments.append(
        contentsOf: Self.dateArguments(
          query.dateField, after: after, before: nil, unit: dateUnit))
    } else if let before = query.before {
      conditions.append(Self.dateCondition(query.dateField, bounded: false, isAfter: false))
      arguments.append(
        contentsOf: Self.dateArguments(
          query.dateField, after: nil, before: before, unit: dateUnit))
    }

    // The row-id window the count routes accept. Inclusive at both ends, as the reference's.
    if let minRowID = query.minRowID {
      conditions.append("m.ROWID >= ?")
      arguments.append(minRowID)
    }
    if let maxRowID = query.maxRowID {
      conditions.append("m.ROWID <= ?")
      arguments.append(maxRowID)
    }
    if query.onlyFromMe {
      conditions.append("m.is_from_me = 1")
    }
    // EXISTS rather than a join: a message in several chats would otherwise be counted
    // once per chat, and the total would exceed the number of messages.
    if query.requiresChat, query.chatGUID == nil {
      conditions.append(
        "EXISTS (SELECT 1 FROM chat_message_join cmj2 WHERE cmj2.message_id = m.ROWID)"
      )
    }

    // The client's own filters, last, so the conditions above still read in the order the
    // reference applies them.
    //
    // Each of the two that reach another table is a SUBQUERY rather than a join, for the
    // reason the chat condition above gives: a message in three chats joined to `chat` is
    // three rows, and the fix for that is either a DISTINCT on every query or not joining.
    for filter in query.filters {
      switch filter {
      case .rowIDGreaterThan(let rowID):
        conditions.append("m.ROWID > ?")
        arguments.append(rowID)
      case .rowIDAtMost(let rowID):
        conditions.append("m.ROWID <= ?")
        arguments.append(rowID)
      case .isFromMe(let fromMe):
        conditions.append("m.is_from_me = ?")
        arguments.append(fromMe ? 1 : 0)
      case .textLike(let term):
        // NOCASE, as the client writes it. The wildcards are the client's own and the
        // whole pattern is bound, so a `%` the user typed is their wildcard here exactly
        // as it is on the reference.
        conditions.append("m.text LIKE ? COLLATE NOCASE")
        arguments.append(term)
      case .guidIn(let guids):
        // An empty list matches NOTHING rather than being dropped. `IN ()` is not valid
        // SQLite, and dropping the condition would turn "hydrate these zero messages"
        // into "send me every message", which is the failure this whole file is about.
        guard !guids.isEmpty else {
          conditions.append("0")
          continue
        }
        let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ", ")
        conditions.append("m.guid IN (\(placeholders))")
        arguments.append(contentsOf: guids.map { $0 as (any DatabaseValueConvertible)? })
      case .notAssociated:
        // The reference's `IS NULL`, plus the empty string. Measured on 26.5.2: a plain
        // message carries `''` in this column, not NULL, so the literal translation
        // would exclude nothing and a search would return every reaction.
        conditions.append(
          "(m.associated_message_guid IS NULL OR m.associated_message_guid = '')")
      case .chatGUID(let guid):
        // Prefix-tolerant, never `=`: see `ChatGUID`, and rule 3 in the root CLAUDE.md.
        let candidates = ChatGUID(guid)?.lookupCandidates() ?? [guid]
        let placeholders = Array(repeating: "?", count: candidates.count)
          .joined(separator: ", ")
        conditions.append(
          """
          EXISTS (
            SELECT 1 FROM chat_message_join cmjF
            JOIN chat cF ON cF.ROWID = cmjF.chat_id
            WHERE cmjF.message_id = m.ROWID AND cF.guid IN (\(placeholders))
          )
          """)
        arguments.append(contentsOf: candidates.map { $0 as (any DatabaseValueConvertible)? })
      case .handleAddress(let address):
        conditions.append("m.handle_id IN (SELECT hF.ROWID FROM handle hF WHERE hF.id = ?)")
        arguments.append(address)
      }
    }
    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    return (sql, arguments)
  }

  /// How a chat GUID is matched, in one place.
  ///
  /// Service-prefix tolerant, same as `chats(guid:)`: macOS 26 rewrote every `chat.guid` to
  /// the `any;` spelling as a migration, so a client holding `iMessage;-;X` must still find
  /// the chat sitting right there. See ChatGUID.
  ///
  /// Shared by the full predicate and by the whole-chat count, which joins the other way
  /// round and needs the same matching: two copies of this would drift, and the one nobody
  /// looked at would be the one that stopped finding a conversation.
  private static func chatCondition(
    _ guid: String
  ) -> (condition: String, arguments: [(any DatabaseValueConvertible)?]) {
    let candidates = ChatGUID(guid)?.lookupCandidates() ?? [guid]
    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
    return (
      "c.guid IN (\(placeholders))",
      candidates.map { $0 as (any DatabaseValueConvertible)? }
    )
  }

  /// The SQL for a date window, in the mode the query asked for.
  ///
  /// The `updated` form is the reference's bracketing, which is not the obvious one: it is
  /// `(delivered in window) OR (read in window)`, NOT `(delivered or read after) AND
  /// (delivered or read before)`. The difference is real — the second matches a message
  /// delivered after the window and read before it, where neither column is actually inside
  /// — and it is the shape this used to have.
  private static func dateCondition(
    _ field: MessageQuery.DateField, bounded: Bool, isAfter: Bool = true
  ) -> String {
    func window(_ column: String) -> String {
      if bounded { return "(\(column) >= ? AND \(column) <= ?)" }
      return isAfter ? "\(column) >= ?" : "\(column) <= ?"
    }
    switch field {
    case .created:
      return window("m.date")
    case .updated:
      // `> 0` on each column, because ZERO MEANS "never", not "at the epoch".
      //
      // An unread message stores `date_read = 0`, and a `before`-only window asks
      // `date_read <= ?`, which zero satisfies: every unread message in the database counted
      // as updated before any instant, whatever its delivery date. A bounded window already
      // excluded it (`0 >= after` is false), and the route requires `after`, so this is not
      // reachable through the API today. It is reachable through this repository, which is
      // public, and a guard that depends on a validator two layers up is not a guard.
      let delivered = "(m.date_delivered > 0 AND \(window("m.date_delivered")))"
      let read = "(m.date_read > 0 AND \(window("m.date_read")))"
      return "(\(delivered) OR \(read))"
    }
  }

  /// The bindings for `dateCondition`, in the order it writes its placeholders.
  private static func dateArguments(
    _ field: MessageQuery.DateField, after: Date?, before: Date?, unit: AppleTimestamp.Unit
  ) -> [(any DatabaseValueConvertible)?] {
    var window: [(any DatabaseValueConvertible)?] = []
    if let after { window.append(AppleTimestamp.from(after, unit: unit).rawValue) }
    if let before { window.append(AppleTimestamp.from(before, unit: unit).rawValue) }
    // `updated` writes the same window twice, once per column.
    return field == .updated ? window + window : window
  }

  public func messages(_ query: MessageQuery) async throws -> [IMessageRow] {
    var query = query
    // Resolved BEFORE the SQL is built, because what it changes is the shape of the query
    // rather than its arguments. One indexed lookup, cached; see `chatRowIDs(for:)`.
    if let guid = query.chatGUID {
      query.resolvedChatRowIDs = await chatRowIDs(for: guid)
    }
    return try await messagesWithoutResolution(query)
  }

  /// `messages` with whatever resolution the caller has already done, and none of its own.
  ///
  /// The seam the parity test uses to run the same query down both scoping paths; the
  /// guid-joined path is also what a database whose guid resolves to nothing still takes.
  func messagesWithoutResolution(_ query: MessageQuery) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let predicate = messagePredicate(query)

    var sql = "SELECT \(columns) FROM message m" + predicate.clause
    var arguments = predicate.arguments

    // Ordering by date, not ROWID: iCloud backfills history out of ROWID order, so the
    // two disagree. This is also why the poller needs its reconcile pass.
    //
    // WHICH copy of the date, though, is the difference between a page that costs 45ms and
    // one that costs 1.4ms. `m.date` has no index that also covers the chat, so a
    // chat-scoped query plans as USE TEMP B-TREE FOR ORDER BY: for a 54,777-message
    // conversation, 54,777 random seeks into a 343MB table and a full sort, to return a
    // hundred rows. Apple already ships `chat_message_join_idx_message_date_id_chat_id`
    // over the join's own copy of the same instant, and ordering by that makes the sort
    // disappear entirely.
    //
    // Only when the copy is trustworthy, which is asked of the database rather than
    // assumed. See `joinDatesCanOrderAChat()`.
    var orderColumn = "m.date"
    if query.chatGUID != nil, await joinDatesCanOrderAChat() { orderColumn = "cmj.message_date" }
    sql += " ORDER BY \(orderColumn) \(query.ascending ? "ASC" : "DESC")"
    sql += " LIMIT ? OFFSET ?"
    arguments.append(query.limit)
    arguments.append(query.offset)

    // Frozen before the closure. `sql` and `arguments` are accumulated as vars, and
    // GRDB's read closure is @Sendable: it may capture neither a mutable var nor the
    // non-Sendable [any DatabaseValueConvertible]. StatementArguments is Sendable, so
    // converting here rather than inside the closure is what makes this legal.
    let statement = sql
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .mapRows { IMessageRow($0, dateUnit: unit) }
    }
  }

  /// The newest message in each of several chats, in two queries rather than two per chat.
  ///
  /// The per-chat form is the right SQL and the wrong number of round trips. Each lookup is a
  /// covering-index seek -- all 486 of them together are about a millisecond of SQLite -- but
  /// going through `messages()` once per chat costs statement preparation, row mapping and an
  /// actor hop apiece, measured at 165ms for one conversation list.
  ///
  /// A window function was tried and is 180 TIMES slower: `ROW_NUMBER() OVER (PARTITION BY
  /// chat_id ...)` has to scan all 417,331 join rows, where the correlated subquery seeks
  /// straight to each chat's newest row. So the shape stays and only the count changes.
  public func lastMessages(forChatRowIDs rowIDs: [Int64]) async throws -> [Int64: IMessageRow] {
    guard !rowIDs.isEmpty else { return [:] }

    var newestByChat: [Int64: Int64] = [:]
    for chunk in rowIDs.chunked(into: Self.hydrationChunk) {
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
      let sql = """
        SELECT c.ROWID AS chat_rowid, (
          SELECT cmj.message_id FROM chat_message_join cmj
          WHERE cmj.chat_id = c.ROWID ORDER BY cmj.message_date DESC LIMIT 1
        ) AS message_rowid
        FROM chat c WHERE c.ROWID IN (\(placeholders))
        """
      let statementArguments = StatementArguments(chunk)
      let pairs = try await database.read { db in
        try Row.fetchAll(db, sql: sql, arguments: statementArguments)
          .compactMap { row -> (Int64, Int64)? in
            guard let chat = row["chat_rowid"] as Int64?,
              let message = row["message_rowid"] as Int64?
            else { return nil }
            return (chat, message)
          }
      }
      for (chat, message) in pairs { newestByChat[chat] = message }
    }

    let rows = try await messages(rowIDs: Array(Set(newestByChat.values)))
    let byRowID = Dictionary(rows.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
    return newestByChat.compactMapValues { byRowID[$0] }
  }

  /// The `chat` ROWIDs a GUID names, matched across every service-prefix spelling.
  ///
  /// Cached against the commit counter, like the counts are: chats are created rarely, and
  /// the lookup is a covering-index seek either way. Nil when the GUID resolves to nothing,
  /// which leaves the caller on the GUID-joined path and therefore on today's behaviour --
  /// an empty result rather than a wrong one.
  func chatRowIDs(for guid: String) async -> [Int64]? {
    let key = "chatRowIDs|\(guid)"
    let token = try? await database.changeToken()
    if let token, let cached = chatRowIDCache.rowIDs(token: token, key: key) { return cached }

    let chat = Self.chatCondition(guid)
    let sql = "SELECT c.ROWID FROM chat c WHERE \(chat.condition)"
    let statementArguments = StatementArguments(chat.arguments)
    let resolved = try? await database.read { db in
      try Int64.fetchAll(db, sql: sql, arguments: statementArguments)
    }
    guard let resolved, !resolved.isEmpty else { return nil }
    if let token { chatRowIDCache.store(resolved, token: token, key: key) }
    return resolved
  }

  /// Whether `chat_message_join.message_date` can be used to order a chat's messages.
  ///
  /// It is a copy of `message.date` that Messages maintains, and on this machine all 417,332
  /// join rows agree with the message they point at. That has NOT been verified on Sonoma or
  /// Sequoia, and a row where the copy is zero or null would sort that message to the wrong
  /// end of the transcript — a wrong answer, not a slow one. So the database is asked rather
  /// than assumed: one covering-index seek, measured well under a millisecond, cached for the
  /// life of the repository, and any disagreement falls back to `m.date` and the temp b-tree.
  ///
  /// A failure to probe answers false, because the slow ordering is the correct one.
  func joinDatesCanOrderAChat() async -> Bool {
    if let known = joinDates.cached { return known }
    let usable =
      (try? await database.read { db in
        try Bool.fetchOne(
          db,
          sql: """
            SELECT NOT EXISTS (
              SELECT 1 FROM chat_message_join WHERE message_date = 0 OR message_date IS NULL
            )
            """) ?? false
      }) ?? false
    joinDates.store(usable)
    return usable
  }

  /// Messages Send Later is still holding: `schedule_type` set and `schedule_state` 1
  /// (accepted) or 2 (scheduled). Measured on 26.5.2: a fresh scheduled message reads 1 in
  /// the send's own response and 2 seconds later; a cancelled one is deleted outright, and
  /// the states a delivered one moves through were not observed, so they are excluded by
  /// listing the two known-pending values rather than by excluding known-done ones.
  /// Soonest delivery first.
  /// Whether this Mac's `chat.db` has the Send Later columns at all.
  ///
  /// Exposed so the interface layer can refuse BEFORE building a query that cannot run:
  /// `schedule_type` and `schedule_state` are Sequoia additions and the deployment floor is
  /// Sonoma, where `pendingScheduledMessages` failed with SQLite's "no such column", which
  /// reads as a server fault rather than as a feature this OS does not have.
  public var supportsScheduledMessages: Bool { profile.supportsScheduledMessages }

  /// What `schedule_type` holds for a Send Later message.
  ///
  /// Mirrors `ScheduledSend.type` in `BBPrivateAPIContract`, which this module deliberately
  /// does not depend on: the read path over chat.db has to work with the Private API absent.
  static let sendLaterScheduleType = 2

  public func pendingScheduledMessages(
    chatGUID: String? = nil, limit: Int = 500
  ) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    // CLAMPED, like every other paged read here. The query below binds `limit` to `LIMIT ?`
    // directly, and SQLite reads a negative LIMIT as no limit at all, so the value had to
    // pass through the same clamp the `MessageQuery` applies rather than around it.
    let query = MessageQuery(chatGUID: chatGUID, limit: limit, offset: 0)
    let predicate = messagePredicate(query)
    var clause = predicate.clause
    // `= 2`, not `!= 0`. Apple ships `message_idx_is_scheduled_message`, a PARTIAL index
    // over `(schedule_type, rowid) WHERE schedule_type = 2`, and only an equality test on
    // the leading column reaches it: `!=`, `>` and `IN` all fall back to scanning all
    // 421,071 rows. Measured on this Mac: 200ms to under a millisecond.
    //
    // 2 is the only value Send Later writes -- `ScheduledSend.type` in the Private API
    // contract, and the value Apple's own partial index is keyed on, which is the stronger
    // evidence of the two since Apple would not index a single type if others existed.
    // A future type would stop matching here where `!= 0` would have caught it, so
    // `ScheduledMessagePredicateTests` pins the value against that contract constant.
    let scheduled = "m.schedule_type = \(Self.sendLaterScheduleType) AND m.schedule_state IN (1, 2)"
    clause = clause.isEmpty ? " WHERE \(scheduled)" : clause + " AND \(scheduled)"
    let statement =
      "SELECT \(columns) FROM message m" + clause + " ORDER BY m.date ASC LIMIT ?"
    var arguments = predicate.arguments
    arguments.append(query.limit)
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .mapRows { IMessageRow($0, dateUnit: unit) }
    }
  }

  /// Every message associated with one of `guids`: a poll's updates and votes, oldest
  /// first. Chat-independent: a poll's thread is addressed by GUID alone.
  public func messages(
    associatedWith guids: [String], limit: Int = 2000
  ) async throws -> [IMessageRow] {
    guard !guids.isEmpty else { return [] }
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let placeholders = Array(repeating: "?", count: guids.count).joined(separator: ", ")
    let statement =
      "SELECT \(columns) FROM message m WHERE m.associated_message_guid IN (\(placeholders)) "
      + "ORDER BY m.date ASC LIMIT ?"
    var arguments: [(any DatabaseValueConvertible)?] = guids.map { $0 }
    arguments.append(limit)
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .mapRows { IMessageRow($0, dateUnit: unit) }
    }
  }

  /// The balloon artwork an app sent us, for re-use on a message we send as that app.
  ///
  /// A Mac generally does not have a third-party iMessage app installed: Game Pigeon ships
  /// iOS-only, so there is no local icon to read, and a balloon we send draws without one.
  /// The app's own artwork IS present, though, in the `ai` key of any message that app sent
  /// to this Mac. This finds the most recent one.
  ///
  /// Nil when this Mac has never received a message from that app, which is the honest
  /// answer: there is nowhere else the icon could come from.
  ///
  /// CACHED, which the comment here used to argue against on the grounds that this is "one
  /// indexed lookup on a send". It is not indexed: `balloon_bundle_id` has no index in
  /// Apple's schema, and adding one to chat.db is not something this server may do, so the
  /// plan is `SCAN m` over every row -- measured at 104ms when nothing matches, which is the
  /// COMMON case, since most Macs have never received a message from a third-party iMessage
  /// app. That cost was paid on every send as that app.
  ///
  /// The invalidation the old comment worried about is answered by a TTL rather than by a
  /// token: an app's own artwork does not change, and chat.db commits constantly on an
  /// active Mac -- our own sends commit -- so a commit-counter key would miss precisely when
  /// it is wanted. An hour-old icon is the same icon.
  public func balloonIcon(bundleID: String) async throws -> Data? {
    if let cached = balloonIcons.value(for: bundleID) { return cached }
    let icon = try await loadBalloonIcon(bundleID: bundleID)
    balloonIcons.store(icon, for: bundleID)
    return icon
  }

  private func loadBalloonIcon(bundleID: String) async throws -> Data? {
    try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT m.payload_data AS payload FROM message m
          WHERE m.is_from_me = 0 AND m.balloon_bundle_id = ? AND m.payload_data IS NOT NULL
          ORDER BY m.ROWID DESC LIMIT 5
          """,
        arguments: [bundleID]
      )
      for row in rows {
        guard let payload = row["payload"] as Data?,
          let icon = AppMessagePayload.icon(in: payload)
        else { continue }
        return icon
      }
      return nil
    }
  }

  public func message(guid: String) async throws -> IMessageRow? {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM message m WHERE m.guid = ? LIMIT 1",
        arguments: [guid]
      )?.mapped { IMessageRow($0, dateUnit: unit) }
    }
  }

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
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
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

  public static let hydrationChunk = 500

  // MARK: - Chats

  public func chats(
    guid: String? = nil,
    includeArchived: Bool = true,
    limit: Int = 1000,
    offset: Int = 0,
    sortByLastMessage: Bool = false
  ) async throws -> [ChatRow] {
    let columns = profile.select(Self.chatColumns, from: .chat, alias: "c")
    var useJoinDates = false
    if sortByLastMessage { useJoinDates = await joinDatesCanOrderAChat() }
    var sql = "SELECT \(columns) FROM chat c"
    // A chat with no participants is not a conversation anyone can act on: there is
    // nobody to send to, so it is excluded, matching the reference, whose `getChats`
    // inner-joins participants with the comment "a chat must have participants".
    //
    // EXISTS rather than a join: joining would multiply a group chat's row by its
    // participant count and force a DISTINCT, which is what the reference pays for it.
    var conditions: [String] = [Self.hasParticipantsClause]
    var arguments: [(any DatabaseValueConvertible)?] = []

    if sortByLastMessage {
      // The order a client actually wants for a conversation list, and one it cannot
      // produce itself without fetching every chat and every chat's last message.
      //
      // LEFT JOIN, not JOIN: a chat with no messages still belongs in the list, and an
      // inner join would silently drop it. Its NULL last_date sorts last under DESC,
      // which is where an empty chat belongs anyway.
      // MAX over the JOIN's copy of the date rather than the message's. `MAX(m.date)`
      // materialises the whole subquery over all 417,331 join rows with a rowid seek into
      // `message` for each, purely to answer "when did this chat last move" -- 340ms on a
      // real database, against 24ms for the same answer read out of the join alone, where
      // `chat_message_join_idx_message_date_id_chat_id` already has it.
      //
      // Guarded by the same probe as the transcript ordering: a database whose copy is
      // zero or null gets the message table back. See `joinDatesCanOrderAChat()`.
      let lastDate = useJoinDates ? "MAX(cmj.message_date)" : "MAX(m.date)"
      let messageJoin = useJoinDates ? "" : "JOIN message m ON m.ROWID = cmj.message_id"
      sql += """
         LEFT JOIN (
             SELECT cmj.chat_id AS chat_id, \(lastDate) AS last_date
             FROM chat_message_join cmj
             \(messageJoin)
             GROUP BY cmj.chat_id
         ) lm ON lm.chat_id = c.ROWID
        """
    }

    if let guid {
      // Matched across every service-prefix spelling, not on the literal string.
      //
      // macOS 26 rewrote every `chat.guid` from `iMessage;-;X` / `SMS;-;X` to
      // `any;-;X`, as a migration, so historical rows changed too. A client that
      // cached `iMessage;-;X` would otherwise get an empty result for a chat sitting
      // right there. See ChatGUID.
      if let parsed = ChatGUID(guid) {
        let candidates = parsed.lookupCandidates()
        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
        conditions.append("c.guid IN (\(placeholders))")
        arguments.append(contentsOf: candidates.map { $0 as (any DatabaseValueConvertible)? })
      } else {
        conditions.append("c.guid = ?")
        arguments.append(guid)
      }
    }
    if !includeArchived {
      conditions.append("c.is_archived = 0")
    }
    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    // The join has to be part of the FROM clause, so it was added above, before any
    // WHERE conditions.
    sql +=
      sortByLastMessage
      ? " ORDER BY lm.last_date DESC LIMIT ? OFFSET ?"
      : " ORDER BY c.ROWID DESC LIMIT ? OFFSET ?"
    arguments.append(limit)
    arguments.append(offset)

    let statement = sql
    let statementArguments = StatementArguments(arguments)
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .mapRows { ChatRow($0) }
    }
  }

  /// Every handle, paged.
  ///
  /// Backs `POST /api/v1/handle/query`. Ordered by ROWID rather than by address: the
  /// address ordering a user would expect depends on a collation chat.db does not define,
  /// and a stable order matters more here than a pretty one, because the client pages
  /// through it.
  public func handles(limit: Int = 1000, offset: Int = 0) async throws -> [HandleRow] {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    let sql = "SELECT \(columns) FROM handle h ORDER BY h.ROWID ASC LIMIT ? OFFSET ?"
    let statementArguments = StatementArguments([limit, offset])
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments).mapRows { HandleRow($0) }
    }
  }

  public func participants(chatGUID: String) async throws -> [HandleRow] {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    // Same service-prefix tolerance as `chats(guid:)`; see the note there.
    let candidates = ChatGUID(chatGUID)?.lookupCandidates() ?? [chatGUID]
    let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
    let sql = """
      SELECT \(columns) FROM handle h
      JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
      JOIN chat c ON c.ROWID = chj.chat_id
      WHERE c.guid IN (\(placeholders))
      """
    let statementArguments = StatementArguments(
      candidates.map { $0 as (any DatabaseValueConvertible)? }
    )
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments).mapRows { HandleRow($0) }
    }
  }

  /// This Mac's own iMessage address, as far as `chat.db` records it.
  ///
  /// Read from `chat.last_addressed_handle`: the handle the user last sent FROM in each
  /// conversation, and reduced to the most common value. That beats the alternatives:
  /// AppleScript's `account` objects expose a `description` that is prefixed and often
  /// `missing value`, and there is no supported API for "who am I" without the helper.
  ///
  /// The mode rather than the newest, because a single message sent from a secondary alias
  /// would otherwise become the answer. On a real database the winner is unambiguous;
  /// measured, the top value held 453 of 471 rows and the runner-up 17.
  ///
  /// Nil when the database is empty or the column is unpopulated. Callers must have a path
  /// that asks the user instead: this is a convenience, not a guarantee.
  public func ownAddress() async throws -> String? {
    try await database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT last_addressed_handle FROM chat
          WHERE last_addressed_handle IS NOT NULL AND last_addressed_handle != ''
          GROUP BY last_addressed_handle
          ORDER BY COUNT(*) DESC
          LIMIT 1
          """
      )
    }
  }

  /// Every chat whose participant set is exactly `addresses`.
  ///
  /// Serves both creation paths, which is why it is not called `groupChats`: a one-to-one
  /// chat is the single-address case, and the direct path needs the same lookup.
  ///
  /// This is how the Shortcuts group-creation path learns the GUID of the chat it just
  /// caused: the Shortcuts send action returns NOTHING, so the conversation has to be found
  /// afterwards by the only thing the caller knows about it: who is in it.
  ///
  /// Matching is on the SET, not on an ordered list and not on a subset. Both matter:
  /// Messages does not preserve the order addresses were given in, and a subset match would
  /// happily return a four-person chat when a three-person one was asked for.
  ///
  /// `normalize` is supplied by the caller rather than done here, because the authority on
  /// what makes two addresses the same is `AddressFormatter`, which lives above this layer
  /// and knows about phone-number regions. Handles are stored in whatever form Messages
  /// wrote them, so comparing raw strings misses `+15551234567` against `(555) 123-4567`.
  ///
  /// The SQL narrows by participant COUNT rather than by address. That is deliberate: an
  /// address filter would have to match the stored spelling to be useful, which is the
  /// exact thing `normalize` exists because we cannot do. A count is exact, needs no
  /// formatting agreement, and cuts the candidate set to a handful.
  ///
  /// Newest first, so a caller that finds several takes the one most recently created.
  public func chats(
    matchingParticipants addresses: [String],
    normalize: (String) -> String
  ) async throws -> [ChatRow] {
    let wanted = Set(addresses.map(normalize))
    guard !wanted.isEmpty else { return [] }

    let columns = profile.select(Self.chatColumns, from: .chat, alias: "c")
    let sql = """
      SELECT \(columns) FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      GROUP BY c.ROWID
      HAVING COUNT(DISTINCT chj.handle_id) = ?
      ORDER BY c.ROWID DESC
      """
    let candidates = try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: [wanted.count]).mapRows { ChatRow($0) }
    }

    var matches: [ChatRow] = []
    for chat in candidates {
      let members = Set(try await participants(chatGUID: chat.guid).map { normalize($0.id) })
      if members == wanted { matches.append(chat) }
    }
    return matches
  }

  /// One handle by address.
  ///
  /// Matched on `id` exactly. Deliberately not fuzzy: `ContactIndex` does the normalized
  /// matching, and doing it in both places produced the bug where `a@example.com`
  /// resolved to `bba@example.com`: suffix matching is right for phone numbers and
  /// catastrophic for emails.
  public func handle(address: String) async throws -> HandleRow? {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM handle h WHERE h.id = ? LIMIT 1",
        arguments: [address]
      )?.mapped { HandleRow($0) }
    }
  }

  /// Every chat a handle participates in.
  public func chats(forHandleRowID rowID: Int64) async throws -> [ChatRow] {
    let columns = profile.select(Self.chatColumns, from: .chat, alias: "c")
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT \(columns) FROM chat c
          JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
          WHERE chj.handle_id = ?
          ORDER BY c.ROWID DESC
          """, arguments: [rowID]
      ).mapRows { ChatRow($0) }
    }
  }

  public func handle(rowID: Int64) async throws -> HandleRow? {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM handle h WHERE h.ROWID = ?", arguments: [rowID]
      )?.mapped { HandleRow($0) }
    }
  }

  /// Chats a message belongs to. Many-to-many: a message can be in several.
  public func chats(forMessageGUID guid: String) async throws -> [ChatRow] {
    let columns = profile.select(Self.chatColumns, from: .chat, alias: "c")
    let sql = """
      SELECT \(columns) FROM chat c
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message m ON m.ROWID = cmj.message_id
      WHERE m.guid = ?
      """
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: [guid]).mapRows { ChatRow($0) }
    }
  }

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
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
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
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
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

  // MARK: - Counts

  /// Total messages, with the same filters the listing accepts.
  ///
  /// Uses `COUNT(DISTINCT m.ROWID)` rather than `COUNT(*)`: with the chat join present, a
  /// message that belongs to more than one chat row would otherwise be counted once per
  /// join row and inflate the total.
  public func messageCount(_ query: MessageQuery = MessageQuery()) async throws -> Int {
    try await messageCount(query, countingTheJoinWherePossible: true)
  }

  /// - Parameter countingTheJoinWherePossible: false forces the `message`-table form even for
  ///   a whole-conversation query. The only caller that passes false is the parity test, which
  ///   needs the same answer computed the slow way to compare against; a second hand-written
  ///   statement in the test would be a second thing to keep correct.
  func messageCount(
    _ query: MessageQuery, countingTheJoinWherePossible: Bool
  ) async throws -> Int {
    let predicate = messagePredicate(query)
    // Counting a whole conversation needs no column of `message` at all, and reaching for
    // one costs a rowid seek per row plus a temp b-tree for the DISTINCT: 42ms on a
    // 54,777-message chat, against 2ms counting the join alone, for the same answer. This
    // total accompanies every page of that conversation, so it cost more than the page did.
    //
    // `DISTINCT` is kept rather than dropped. `sqlite_autoindex_chat_message_join_1` makes
    // (chat_id, message_id) unique so it is redundant for a single chat -- and the planner
    // sees that, which is why the temp b-tree disappears -- but `c.guid IN (...)` is matched
    // across every service-prefix spelling, and a database carrying the same conversation
    // under two chat rows would otherwise count its messages twice.
    var statement = "SELECT COUNT(DISTINCT m.ROWID) FROM message m" + predicate.clause
    var arguments = predicate.arguments
    if countingTheJoinWherePossible, let chatGUID = query.chatGUID, query.countsAWholeChat {
      let chat = Self.chatCondition(chatGUID)
      statement = """
        SELECT COUNT(DISTINCT cmj.message_id) FROM chat_message_join cmj
        JOIN chat c ON c.ROWID = cmj.chat_id WHERE \(chat.condition)
        """
      arguments = chat.arguments
    }
    // Frozen before the closure, which is `@Sendable` and may capture neither a mutable
    // var nor the non-Sendable argument array.
    let sql = statement
    let statementArguments = StatementArguments(arguments)

    // Held against SQLite's commit counter.
    //
    // Two of these counts have no index behind them and cannot get one: `count/updated`
    // filters on `date_delivered` and `date_read`, which Apple leaves unindexed, and adding
    // an index to chat.db is not something this server may do. So the scan stays and the
    // ANSWER is remembered instead. `PRAGMA data_version` changes whenever another
    // connection commits -- Messages, here -- so two equal tokens mean nothing was written
    // in between and the count cannot have moved.
    //
    // Read BEFORE the query, for the reason the change detector reads it first: a commit
    // that lands while the query runs is then newer than this token, so the next call
    // misses rather than serving a count taken across a write.
    let key = "\(sql)|\(arguments.map { $0.map { "\($0.databaseValue)" } ?? "nil" })"
    let token = try? await database.changeToken()
    if let token, let cached = counts.value(token: token, key: key) { return cached }

    let result = try await database.read { db in
      try Int.fetchOne(db, sql: sql, arguments: statementArguments) ?? 0
    }
    if let token { counts.store(result, token: token, key: key) }
    return result
  }

  /// Messages whose delivery or read state changed in a window.
  ///
  /// Distinct from `messageCount`, which filters on `date`: the moment a message was
  /// created. A receipt arriving today for a message sent last week moves `date_delivered`
  /// and leaves `date` alone, so counting on `date` would miss exactly the updates this is
  /// asked for.
  /// `GET /message/count/updated`: how many messages were delivered or read in a window.
  ///
  /// A thin wrapper over `messageCount` now, rather than its own statement. Its own statement
  /// is why the route ignored `chatGuid`, `minRowId` and `maxRowId`, all three of which the
  /// reference accepts: the parameters were parsed nowhere because there was nothing on this
  /// path to parse them into.
  public func updatedMessageCount(_ query: MessageQuery = MessageQuery()) async throws -> Int {
    var updated = query
    updated.dateField = .updated
    return try await messageCount(updated)
  }

  /// One chat by GUID, service-prefix tolerant.
  public func chat(guid: String) async throws -> ChatRow? {
    try await chats(guid: guid, limit: 1).first
  }

  /// The Apple ID this Mac sends iMessages from, or nil.
  ///
  /// Read from the newest iMessage chat's `account_login` rather than from any account API,
  /// because it is the only place the value is available without private frameworks. (The
  /// reference reads it the same way, for the same lack of an alternative: the agreement is
  /// a consequence, not the argument.) `account_login` is stored as `E:user@example.com` or
  /// `P:+12025550143`, so the part after the last colon is the address.
  ///
  /// Nil on a database with no iMessage chats: a brand-new Mac, or one that only uses SMS,
  /// which is a normal state and not a failure to report.
  public func iMessageAccount() async throws -> String? {
    try await database.read { db in
      let sql =
        "SELECT account_login FROM chat "
        + "WHERE service_name = \'iMessage\' AND account_login IS NOT NULL "
        + "ORDER BY ROWID DESC LIMIT 1"
      guard let login = try String.fetchOne(db, sql: sql),
        let address = login.split(separator: ":").last,
        !address.isEmpty
      else { return nil }
      return String(address)
    }
  }

  /// A chat with somebody in it.
  ///
  /// One definition, used by the listing and by both counts, so a total can never disagree
  /// with the rows it claims to count.
  static let hasParticipantsClause =
    "EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID)"

  /// Chat counts keyed by SERVICE NAME: `iMessage`, `SMS`, `RCS`.
  ///
  /// Was keyed by `style` (43 for a group, 45 for a direct chat), which produced
  /// `{"43": 311, "45": 170}` where the wire contract is
  /// `{"iMessage": 480, "SMS": 1}`. Two different questions, and only one of them is the
  /// one clients ask.
  public func chatCountsByService(includeArchived: Bool = true) async throws -> [String: Int] {
    var conditions = [Self.hasParticipantsClause]
    if !includeArchived { conditions.append("c.is_archived = 0") }
    let sql = """
      SELECT COALESCE(c.service_name, '') AS service, COUNT(*) AS total
      FROM chat c
      WHERE \(conditions.joined(separator: " AND "))
      GROUP BY service
      """
    return try await database.read { db in
      var counts: [String: Int] = [:]
      for row in try Row.fetchAll(db, sql: sql) {
        counts[row["service"] ?? ""] = row["total"] ?? 0
      }
      return counts
    }
  }

  public func chatCount(includeArchived: Bool = true) async throws -> Int {
    var conditions = [Self.hasParticipantsClause]
    if !includeArchived { conditions.append("c.is_archived = 0") }
    let sql = "SELECT COUNT(*) FROM chat c WHERE " + conditions.joined(separator: " AND ")
    return try await database.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
  }

  public func handleCount() async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM handle") ?? 0
    }
  }

  /// Attachment counts by media bucket: "412 images", not a histogram over `image/jpeg`,
  /// `image/heic` and `image/png`. Rows with no mime type at all count as `other` rather
  /// than being dropped: a purged attachment often has none, and omitting them makes the
  /// totals disagree with `attachmentCount`.
  ///
  /// Grouped on the FULL mime type rather than the part before the slash, because one of
  /// the buckets the wire contract names is not a top-level type: the reference counts
  /// locations as `mime_type LIKE 'text/x-vlocation%'`, which slicing at the slash turns
  /// into `text` and buries in `other`. Mime types are few, so grouping on the whole string
  /// and bucketing in Swift costs nothing and keeps the rule readable.
  public func mediaCounts(chatGUID: String? = nil) async throws -> [String: Int] {
    var sql = """
      SELECT LOWER(COALESCE(a.mime_type, '')) AS kind,
             COUNT(*) AS total
      FROM attachment a
      """
    var arguments: [(any DatabaseValueConvertible)?] = []

    if let chatGUID {
      sql += """
         JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
         JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
         JOIN chat c ON c.ROWID = cmj.chat_id
        """
      let candidates = ChatGUID(chatGUID)?.lookupCandidates() ?? [chatGUID]
      let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
      sql += " WHERE c.guid IN (\(placeholders))"
      arguments.append(contentsOf: candidates.map { $0 as (any DatabaseValueConvertible)? })
    }
    sql += " GROUP BY kind"

    let statement = sql
    let statementArguments = StatementArguments(arguments)
    return try await database.read { db in
      var counts: [String: Int] = [:]
      for row in try Row.fetchAll(db, sql: statement, arguments: statementArguments) {
        let kind: String = row["kind"] ?? ""
        counts[Self.mediaBucket(forMimeType: kind), default: 0] += row["total"] ?? 0
      }
      return counts
    }
  }

  /// Which bucket a mime type counts toward.
  ///
  /// `location` is checked first and by prefix: a location attachment is
  /// `text/x-vlocation`, so a top-level-type rule would file it under `text` and then under
  /// `other`, and the wire's `locations` count would be zero on every install.
  static func mediaBucket(forMimeType mimeType: String) -> String {
    if mimeType.hasPrefix("text/x-vlocation") { return "location" }
    let topLevel = mimeType.split(separator: "/").first.map(String.init) ?? ""
    // Anything that is not image, video, audio or a location lands in `other`, which is
    // where PDFs, vCards and Apple's own balloon payloads belong.
    return ["image", "video", "audio"].contains(topLevel) ? topLevel : "other"
  }

  /// Per-chat media counts, one row per chat that has any.
  ///
  /// The reference's `/server/statistics/media/chat` returns EVERY chat rather than one, so
  /// this does the grouping in SQL instead of running the single-chat query in a loop.
  ///
  /// Carries the same participants clause the listing and both counts carry. Their shared
  /// header says "one definition, used by the listing and by both counts, so a total can
  /// never disagree with the rows it claims to count" — and this query was the one that did
  /// not use it, so per-chat media statistics could report rows for chats the chat listing
  /// excludes, which is a chat nobody can act on because there is nobody in it.
  public func mediaCountsByChat() async throws -> [(
    guid: String, displayName: String?, counts: [String: Int]
  )] {
    let sql = """
      SELECT c.guid AS guid,
             c.display_name AS display_name,
             LOWER(COALESCE(a.mime_type, '')) AS kind,
             COUNT(*) AS total
      FROM chat c
      JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      JOIN message_attachment_join maj ON maj.message_id = cmj.message_id
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE \(Self.hasParticipantsClause)
      GROUP BY c.guid, c.display_name, kind
      """
    return try await database.read { db in
      // Insertion-ordered, so the response is stable run to run rather than following
      // a dictionary's hashing.
      var order: [String] = []
      var names: [String: String?] = [:]
      var buckets: [String: [String: Int]] = [:]
      for row in try Row.fetchAll(db, sql: sql) {
        let guid: String = row["guid"] ?? ""
        if buckets[guid] == nil {
          order.append(guid)
          names[guid] = row["display_name"]
          buckets[guid] = [:]
        }
        let kind: String = row["kind"] ?? ""
        buckets[guid]?[Self.mediaBucket(forMimeType: kind), default: 0] += row["total"] ?? 0
      }
      return order.map { (guid: $0, displayName: names[$0] ?? nil, counts: buckets[$0] ?? [:]) }
    }
  }

  public func attachmentCount() async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment") ?? 0
    }
  }
}

/// Counts held against the commit counter that produced them.
///
/// `MessageRepository` is a `Sendable` struct built once at composition, so it has nowhere to
/// keep these; this is that place. A token change drops everything rather than expiring
/// entries one at a time: any commit can move any count, and there is no cheap way to know
/// which.
private final class CountCache: @unchecked Sendable {
  private let lock = NSLock()
  private var token: Int?
  private var counts: [String: Int] = [:]

  /// Bounded because the key includes the query's arguments, which a client chooses. A
  /// client paging with a moving `after` would otherwise add an entry per request.
  private let capacity = 64

  private var rowIDLists: [String: [Int64]] = [:]

  func value(token: Int, key: String) -> Int? {
    lock.withLock { self.token == token ? counts[key] : nil }
  }

  func rowIDs(token: Int, key: String) -> [Int64]? {
    lock.withLock { self.token == token ? rowIDLists[key] : nil }
  }

  func store(_ value: [Int64], token: Int, key: String) {
    lock.withLock {
      if self.token != token {
        self.token = token
        counts.removeAll(keepingCapacity: true)
        rowIDLists.removeAll(keepingCapacity: true)
      }
      if rowIDLists.count >= capacity { rowIDLists.removeAll(keepingCapacity: true) }
      rowIDLists[key] = value
    }
  }

  func store(_ value: Int, token: Int, key: String) {
    lock.withLock {
      if self.token != token {
        self.token = token
        counts.removeAll(keepingCapacity: true)
        rowIDLists.removeAll(keepingCapacity: true)
      }
      if counts.count >= capacity { counts.removeAll(keepingCapacity: true) }
      counts[key] = value
    }
  }
}

/// Balloon artwork by bundle id, with a TTL. See `balloonIcon`.
private final class BalloonIconCache: @unchecked Sendable {
  private let lock = NSLock()
  /// `Data?` because a MISS is the expensive answer and the one worth remembering: a full
  /// scan that finds nothing costs the same as one that finds something.
  private var cache = BoundedCache<String, Data?>(capacity: 16, ttl: .seconds(3600))

  func value(for bundleID: String) -> Data?? {
    lock.withLock { cache[bundleID] }
  }

  func store(_ icon: Data?, for bundleID: String) {
    lock.withLock { cache[bundleID] = icon }
  }
}

/// One lazily probed boolean, shared by every copy of a `MessageRepository` value.
///
/// `MessageRepository` is a `Sendable` struct built once at composition, so it has nowhere to
/// keep a cached answer; this is that place. Two callers racing the probe both run it and
/// reach the same answer, which is why the race is not worth preventing.
private final class JoinDateSupport: @unchecked Sendable {
  private let lock = NSLock()
  private var known: Bool?

  var cached: Bool? { lock.withLock { known } }
  func store(_ value: Bool) { lock.withLock { known = value } }
}

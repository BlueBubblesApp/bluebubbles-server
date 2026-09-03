//  MessageRepository
//  Read-only access to chat.db.
//
//  Raw SQL behind typed request structs rather than an ORM, because Apple owns this schema
//  and changes it per release — an entity model forces version branching into the type
//  definitions, which is how `isMinHighSierra` checks ended up scattered through the current
//  data layer.
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

  public init(database: ReadOnlyDatabase, profile: SchemaProfile) {
    self.database = database
    self.profile = profile
  }

  private var dateUnit: AppleTimestamp.Unit { profile.dateUnit }

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
    // carries `lastSeenMessageGuid`, `shouldForceToSMS` and the thread-response count,
    // and it was simply not being selected — so `chat.properties` was an empty array on
    // every chat this server returned.
    "properties",
  ]

  static let handleColumns: [String] = [
    "ROWID", "id", "country", "service", "uncanonicalized_id", "person_centric_id",
  ]

  static let attachmentColumns: [String] = [
    "ROWID", "guid", "created_date", "start_date", "filename", "uti", "mime_type",
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
    /// are in none — 3,739 of them on this development database, which is what made its
    /// `metadata.total` disagree with its own `/message/count`. Reproduced rather than
    /// tidied, because a message in no chat cannot be shown in any conversation.
    public var requiresChat: Bool

    public init(
      chatGUID: String? = nil,
      after: Date? = nil,
      before: Date? = nil,
      limit: Int = 100,
      offset: Int = 0,
      ascending: Bool = false,
      includeAttachments: Bool = true,
      onlyFromMe: Bool = false,
      requiresChat: Bool = false
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
    if let chatGUID = query.chatGUID {
      sql += """
         JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
         JOIN chat c ON c.ROWID = cmj.chat_id
        """
      // Service-prefix tolerant, same as `chats(guid:)`. See ChatGUID.
      let candidates = ChatGUID(chatGUID)?.lookupCandidates() ?? [chatGUID]
      let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
      conditions.append("c.guid IN (\(placeholders))")
      arguments.append(contentsOf: candidates.map { $0 as (any DatabaseValueConvertible)? })
    }

    if let after = query.after {
      conditions.append("m.date > ?")
      arguments.append(AppleTimestamp.from(after, unit: dateUnit).rawValue)
    }
    if let before = query.before {
      conditions.append("m.date < ?")
      arguments.append(AppleTimestamp.from(before, unit: dateUnit).rawValue)
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

    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    return (sql, arguments)
  }

  public func messages(_ query: MessageQuery) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let predicate = messagePredicate(query)

    var sql = "SELECT \(columns) FROM message m" + predicate.clause
    var arguments = predicate.arguments

    // Ordering by date, not ROWID: iCloud backfills history out of ROWID order, so the
    // two disagree. This is also why the poller needs its reconcile pass.
    sql += " ORDER BY m.date \(query.ascending ? "ASC" : "DESC")"
    sql += " LIMIT ? OFFSET ?"
    arguments.append(query.limit)
    arguments.append(query.offset)

    // Frozen before the closure. `sql` and `arguments` are accumulated as vars, and
    // GRDB's read closure is @Sendable — it may capture neither a mutable var nor the
    // non-Sendable [any DatabaseValueConvertible]. StatementArguments is Sendable, so
    // converting here rather than inside the closure is what makes this legal.
    let statement = sql
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .map { IMessageRow(row: $0, dateUnit: unit) }
    }
  }

  /// Every message associated with one of `guids` — a poll's updates and votes, oldest
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
        .map { IMessageRow(row: $0, dateUnit: unit) }
    }
  }

  public func message(guid: String) async throws -> IMessageRow? {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM message m WHERE m.guid = ? LIMIT 1",
        arguments: [guid]
      ).map { IMessageRow(row: $0, dateUnit: unit) }
    }
  }

  /// Messages changed since `date`, by any of the timestamps that can move after insert.
  ///
  /// Rows are UPDATED after they are written — delivery, read receipts, edits — so a
  /// poller watching only for new ROWIDs misses all of that.
  public func messagesChanged(since date: Date, limit: Int = 1000) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let threshold = AppleTimestamp.from(date, unit: dateUnit).rawValue

    var clauses = ["m.date > ?", "m.date_read > ?", "m.date_delivered > ?"]
    var arguments: [(any DatabaseValueConvertible)?] = [threshold, threshold, threshold]

    if profile.supportsEditedMessages {
      clauses.append("m.date_edited > ?")
      arguments.append(threshold)
      clauses.append("m.date_retracted > ?")
      arguments.append(threshold)
    }

    let sql = """
      SELECT \(columns) FROM message m
      WHERE \(clauses.joined(separator: " OR "))
      ORDER BY m.date ASC
      LIMIT ?
      """
    arguments.append(limit)

    let statement = sql
    let statementArguments = StatementArguments(arguments)
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchAll(db, sql: statement, arguments: statementArguments)
        .map { IMessageRow(row: $0, dateUnit: unit) }
    }
  }

  // MARK: - Chats

  public func chats(
    guid: String? = nil,
    includeArchived: Bool = true,
    limit: Int = 1000,
    offset: Int = 0,
    sortByLastMessage: Bool = false
  ) async throws -> [ChatRow] {
    let columns = profile.select(Self.chatColumns, from: .chat, alias: "c")
    var sql = "SELECT \(columns) FROM chat c"
    // A chat with no participants is not a conversation anyone can act on — there is
    // nobody to send to — so it is excluded, matching the reference, whose `getChats`
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
      sql += """
         LEFT JOIN (
             SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
             FROM chat_message_join cmj
             JOIN message m ON m.ROWID = cmj.message_id
             GROUP BY cmj.chat_id
         ) lm ON lm.chat_id = c.ROWID
        """
    }

    if let guid {
      // Matched across every service-prefix spelling, not on the literal string.
      //
      // macOS 26 rewrote every `chat.guid` from `iMessage;-;X` / `SMS;-;X` to
      // `any;-;X` — as a migration, so historical rows changed too. A client that
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
        .map { ChatRow(row: $0) }
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
      try Row.fetchAll(db, sql: sql, arguments: statementArguments).map { HandleRow(row: $0) }
    }
  }

  public func participants(chatGUID: String) async throws -> [HandleRow] {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    // Same service-prefix tolerance as `chats(guid:)` — see the note there.
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
      try Row.fetchAll(db, sql: sql, arguments: statementArguments).map { HandleRow(row: $0) }
    }
  }

  /// This Mac's own iMessage address, as far as `chat.db` records it.
  ///
  /// Read from `chat.last_addressed_handle` — the handle the user last sent FROM in each
  /// conversation — and reduced to the most common value. That beats the alternatives:
  /// AppleScript's `account` objects expose a `description` that is prefixed and often
  /// `missing value`, and there is no supported API for "who am I" without the helper.
  ///
  /// The mode rather than the newest, because a single message sent from a secondary alias
  /// would otherwise become the answer. On a real database the winner is unambiguous;
  /// measured, the top value held 453 of 471 rows and the runner-up 17.
  ///
  /// Nil when the database is empty or the column is unpopulated. Callers must have a path
  /// that asks the user instead — this is a convenience, not a guarantee.
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
  /// afterwards by the only thing the caller knows about it — who is in it.
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
      try Row.fetchAll(db, sql: sql, arguments: [wanted.count]).map { ChatRow(row: $0) }
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
  /// resolved to `bba@example.com` — suffix matching is right for phone numbers and
  /// catastrophic for emails.
  public func handle(address: String) async throws -> HandleRow? {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM handle h WHERE h.id = ? LIMIT 1",
        arguments: [address]
      ).map { HandleRow(row: $0) }
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
      ).map { ChatRow(row: $0) }
    }
  }

  public func handle(rowID: Int64) async throws -> HandleRow? {
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM handle h WHERE h.ROWID = ?", arguments: [rowID]
      ).map { HandleRow(row: $0) }
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
      try Row.fetchAll(db, sql: sql, arguments: [guid]).map { ChatRow(row: $0) }
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
        .map { AttachmentRow(row: $0, dateUnit: unit) }
    }
  }

  public func attachment(guid: String) async throws -> AttachmentRow? {
    let columns = profile.select(Self.attachmentColumns, from: .attachment, alias: "a")
    let unit = dateUnit
    return try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT \(columns) FROM attachment a WHERE a.guid = ?", arguments: [guid]
      ).map { AttachmentRow(row: $0, dateUnit: unit) }
    }
  }

  // MARK: - Counts

  /// Total messages, with the same filters the listing accepts.
  ///
  /// Uses `COUNT(DISTINCT m.ROWID)` rather than `COUNT(*)`: with the chat join present, a
  /// message that belongs to more than one chat row would otherwise be counted once per
  /// join row and inflate the total.
  public func messageCount(_ query: MessageQuery = MessageQuery()) async throws -> Int {
    let predicate = messagePredicate(query)
    let statement = "SELECT COUNT(DISTINCT m.ROWID) FROM message m" + predicate.clause
    let statementArguments = StatementArguments(predicate.arguments)
    return try await database.read { db in
      try Int.fetchOne(db, sql: statement, arguments: statementArguments) ?? 0
    }
  }

  /// Messages whose delivery or read state changed in a window.
  ///
  /// Distinct from `messageCount`, which filters on `date` — the moment a message was
  /// created. A receipt arriving today for a message sent last week moves `date_delivered`
  /// and leaves `date` alone, so counting on `date` would miss exactly the updates this is
  /// asked for.
  public func updatedMessageCount(after: Date, before: Date? = nil) async throws -> Int {
    let unit = dateUnit
    var conditions = ["(m.date_delivered > ? OR m.date_read > ?)"]
    var arguments: [(any DatabaseValueConvertible)?] = [
      AppleTimestamp.from(after, unit: unit).rawValue,
      AppleTimestamp.from(after, unit: unit).rawValue,
    ]
    if let before {
      conditions.append("(m.date_delivered < ? OR m.date_read < ?)")
      arguments.append(AppleTimestamp.from(before, unit: unit).rawValue)
      arguments.append(AppleTimestamp.from(before, unit: unit).rawValue)
    }
    let statement = "SELECT COUNT(*) FROM message m WHERE " + conditions.joined(separator: " AND ")
    let statementArguments = StatementArguments(arguments)
    return try await database.read { db in
      try Int.fetchOne(db, sql: statement, arguments: statementArguments) ?? 0
    }
  }

  /// One chat by GUID, service-prefix tolerant.
  public func chat(guid: String) async throws -> ChatRow? {
    try await chats(guid: guid, limit: 1).first
  }

  /// The Apple ID this Mac sends iMessages from, or nil.
  ///
  /// Read from the newest iMessage chat's `account_login` rather than from any account API,
  /// which is what the current server does and is the only place the value is available
  /// without private frameworks. `account_login` is stored as `E:user@example.com` or
  /// `P:+12025550143`, so the part after the last colon is the address.
  ///
  /// Nil on a database with no iMessage chats — a brand-new Mac, or one that only uses SMS
  /// — which is a normal state and not a failure to report.
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

  /// Chat counts keyed by SERVICE NAME — `iMessage`, `SMS`, `RCS`.
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

  /// Attachment counts by media bucket — "412 images", not a histogram over `image/jpeg`,
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

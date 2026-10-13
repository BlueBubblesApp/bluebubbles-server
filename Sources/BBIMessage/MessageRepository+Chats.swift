//  MessageRepository+Chats
//  Chats, handles and who is in them: the conversation listing, participants singly and in
//  bulk, a chat found by its participant set, and the addresses this Mac sends from.
//
//  Every chat-GUID match goes through `MessageQueryPlan.chatCondition`, never `c.guid = ?`.
//  macOS 26 rewrote every prefix to `any`, so a literal match on a GUID a client cached
//  finds nothing for a chat that is right there.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

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
      let chat = MessageQueryPlan.chatCondition(guid)
      conditions.append(chat.condition)
      arguments.append(contentsOf: chat.arguments)
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
    let chat = MessageQueryPlan.chatCondition(chatGUID)
    let sql = """
      SELECT \(columns) FROM handle h
      JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
      JOIN chat c ON c.ROWID = chj.chat_id
      WHERE \(chat.condition)
      """
    let statementArguments = StatementArguments(chat.arguments)
    return try await database.read { db in
      try Row.fetchAll(db, sql: sql, arguments: statementArguments).mapRows { HandleRow($0) }
    }
  }

  /// Participants for many chats at once, keyed by `chat.ROWID`.
  ///
  /// The bulk form of `participants(chatGUID:)`, and the difference is not only the round
  /// trips. Keying on **ROWID** rather than GUID skips the three-candidate prefix matching the
  /// per-chat form has to do, because a row the caller already holds carries its own ROWID and
  /// there is nothing to disambiguate: rule 3 is about comparing GUIDs, and this compares none.
  ///
  /// Why it exists: `ChatInterface.project` batched the last-message sender lookup through
  /// `handles(rowIDs:)` and then, three lines below, called `participants(chatGUID:)` once per
  /// row. `POST /chat/query` defaults to a limit of 1000 and sets `withParticipants` true
  /// unconditionally, so on a real Mac (486 chats measured) one request issued 486 sequential
  /// queries. Every one serialises through the single `DatabaseQueue`, so the change
  /// detector's tick and every other in-flight request queued behind the whole thing. That
  /// function's own comment already recorded the measurement for the identical pattern it had
  /// just fixed one loop earlier: **165 ms against 5 ms batched.**
  public func participants(forChatRowIDs rowIDs: [Int64]) async throws -> [Int64: [HandleRow]] {
    let wanted = Array(Set(rowIDs))
    guard !wanted.isEmpty else { return [:] }
    let columns = profile.select(Self.handleColumns, from: .handle, alias: "h")
    var result: [Int64: [HandleRow]] = [:]
    for chunk in wanted.chunked(into: Self.hydrationChunk) {
      let placeholders = SQLPlaceholders.list(chunk.count)
      // `chj.chat_id` is selected alongside the handle columns because one handle can belong
      // to several chats, so the join row is what says which bucket a handle lands in.
      let sql = """
        SELECT chj.chat_id AS bb_chat_id, \(columns) FROM handle h
        JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
        WHERE chj.chat_id IN (\(placeholders))
        ORDER BY chj.chat_id, h.ROWID
        """
      let statementArguments = StatementArguments(chunk)
      let pairs = try await database.read { db in
        // `mapRows` rather than `map`: it builds the column index once for the result set
        // instead of resolving every column by name on every row.
        try Row.fetchAll(db, sql: sql, arguments: statementArguments).mapRows {
          ($0.required("bb_chat_id") as Int64, HandleRow($0))
        }
      }
      for (chatID, handle) in pairs { result[chatID, default: []].append(handle) }
    }
    return result
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
}

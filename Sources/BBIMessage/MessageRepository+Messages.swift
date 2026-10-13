//  MessageRepository+Messages
//  Reading messages: a page through `MessageQuery`, one message by GUID, the newest message
//  in each chat, the rows Send Later is holding, a poll's associated messages, and the
//  balloon artwork a third-party app sent.
//
//  `resolvingSearch` is internal rather than private because `messageCount` in `+Counts`
//  calls it as well. A search resolved for the page and not for its total answers a page of
//  matches beside a count of the whole database.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  // MARK: - Messages
  //
  // `MessageQuery` and the predicate it renders into are in `MessageQueryPlan.swift`.

  public func messages(_ query: MessageQuery) async throws -> [IMessageRow] {
    var query = query
    // Resolved BEFORE the SQL is built, because what it changes is the shape of the query
    // rather than its arguments. One indexed lookup, cached; see `chatRowIDs(for:)`.
    if let guid = query.chatGUID {
      query.resolvedChatRowIDs = await chatRowIDs(for: guid)
    }
    query = await resolvingSearch(query)
    return try await messagesWithoutResolution(query)
  }

  /// Widens each `.textLike` filter with whatever the search index can add to it.
  ///
  /// **Called from the listing AND the count, and that is the whole point.** The two build
  /// their own `MessageQuery` and share only `MessageQueryPlan`, so a search resolved in one
  /// and not the other would return a page of matches beside a total counting the whole
  /// database — which is precisely the class of bug that made the incremental sync page
  /// everything. Resolving here, inside the repository, means neither caller can forget.
  ///
  /// **Widens, never replaces.** Each result is `index matches OR the column matches`, so
  /// this can only ever ADD rows to what the server returned before the feature existed.
  /// `resolvedSearches` has the measurements for what replacing them cost instead.
  ///
  /// A filter is left exactly as it was when there is no index, when the backfill has not
  /// finished, when the read fails, when its term is one a token index cannot express, and
  /// when the index matched nothing for it — five ways of saying "the index has nothing to
  /// add here". Each filter is decided on its own, so one unanswerable term does not stop
  /// another from being widened.
  func resolvingSearch(_ query: MessageQuery) async -> MessageQuery {
    guard let searchIndex else { return query }
    let hasText = query.filters.contains {
      if case .textLike = $0 { return true }
      return false
    }
    guard hasText else { return query }

    var remaining: [MessageFilter] = []
    var widened: [MessageQuery.ResolvedSearch] = []

    for filter in query.filters {
      guard case .textLike(let term) = filter else {
        remaining.append(filter)
        continue
      }
      // Past the ceiling the index stops answering and the condition goes down the path it
      // always had. Never an error and never a narrowing: see `maximumIndexedTextTerms`.
      guard widened.count < Self.maximumIndexedTextTerms,
        let candidates = await searchIndex.matchingRowIDs(
          likeTerm: term, newestFirst: !query.ascending)
      else {
        remaining.append(filter)
        continue
      }
      // An anchored term (`hello%`, `hello`) asks where the words sit, which a token index
      // cannot answer, so its matches are re-checked against the text before they join the
      // union. Without this the union was BROADER than `LIKE`: "starts with hello" found
      // every message containing the word. See `MessageSearchTerm.Anchoring`.
      var rowIDs = candidates
      if let anchoring = MessageSearchTerm.anchoring(ofLikeTerm: term), !rowIDs.isEmpty {
        rowIDs = await admitted(rowIDs, by: anchoring)
      }
      // Nothing to add to the union, so nothing to change. The filter stays where it is
      // and answers on its own, exactly as it did before this feature existed.
      guard !rowIDs.isEmpty else {
        remaining.append(filter)
        continue
      }
      widened.append(.init(term: term, rowIDs: rowIDs))
    }

    guard !widened.isEmpty else { return query }
    var resolved = query
    // Each widened filter is removed from `filters` and re-emitted by the query plan as
    // one half of `m.ROWID IN (…) OR m.text LIKE ?`. Removing one WITHOUT putting it back
    // is the mistake to avoid, and it is not a hypothetical one: the two answers overlap
    // but neither contains the other, so replacing the column match with the index's left
    // every infix term and every unspaced script with whatever the index happened to find.
    resolved.filters = remaining
    resolved.resolvedSearches = widened
    return resolved
  }

  /// The candidates whose text an anchored `LIKE` term really matches, in the index's order.
  ///
  /// Read through `searchableText(rowIDs:)`, which is the rule the index was built with and
  /// the wire `text` uses, so the re-check asks the same text the index answered for. A read
  /// that fails admits nothing: the filter then answers through `LIKE` alone, which is the
  /// behaviour without the index, and narrower is the safe direction for a search.
  private func admitted(
    _ candidates: [Int64], by anchoring: MessageSearchTerm.Anchoring
  ) async -> [Int64] {
    do {
      let texts = try await searchableText(rowIDs: candidates)
      let matching = Set(texts.filter { anchoring.admits($0.text) }.map(\.rowID))
      return candidates.filter(matching.contains)
    } catch {
      logger.warning(
        "Search candidates could not be re-read; the term will match through LIKE alone",
        metadata: [
          "candidates": .stringConvertible(candidates.count),
          "error": .string(String(describing: error)),
        ])
      return []
    }
  }

  /// How many text conditions in one query the index will answer.
  ///
  /// A bound on the STATEMENT, not on what the route accepts. Each answered term splices up
  /// to `SearchIndexStore.defaultMatchLimit` literal row ids into the SQL — around 70 KB of
  /// text — so an authenticated client sending a hundred `message.text` conditions would
  /// otherwise have this build a seven-megabyte statement and run a hundred index reads for
  /// it. Four keeps the worst case in the hundreds of kilobytes.
  ///
  /// Conditions past the fourth are not refused and not narrowed: they keep the plain
  /// `m.text LIKE ?` they would have had with no index at all, which is the invariant this
  /// whole path is built on. No client is known to send even two; the number is headroom,
  /// not a modelled limit.
  static let maximumIndexedTextTerms = 4

  /// `messages` with whatever resolution the caller has already done, and none of its own.
  ///
  /// The seam the parity test uses to run the same query down both scoping paths; the
  /// guid-joined path is also what a database whose guid resolves to nothing still takes.
  func messagesWithoutResolution(_ query: MessageQuery) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    let predicate = queryPlan.predicate(for: query)

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
    // assumed (see `joinDatesCanOrderAChat()`), and only when the plan joined exactly one
    // chat row: a conversation spread over several rows is scoped by a semi-join with no
    // `cmj` to order by. See `MessageQueryPlan.joinsOneChat`.
    var orderColumn = "m.date"
    if queryPlan.joinsOneChat(query), await joinDatesCanOrderAChat() {
      orderColumn = "cmj.message_date"
    }
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
      let placeholders = SQLPlaceholders.list(chunk.count)
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
    if let token, let cached = chatRowIDCache.withLock({ $0.rowIDs(token: token, key: key) }) {
      return cached
    }

    let chat = MessageQueryPlan.chatCondition(guid)
    let sql = "SELECT c.ROWID FROM chat c WHERE \(chat.condition)"
    let statementArguments = StatementArguments(chat.arguments)
    let resolved = try? await database.read { db in
      try Int64.fetchAll(db, sql: sql, arguments: statementArguments)
    }
    guard let resolved, !resolved.isEmpty else { return nil }
    if let token { chatRowIDCache.withLock { $0.store(resolved, token: token, key: key) } }
    return resolved
  }

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

  /// Messages Send Later is still holding: `schedule_type` set and `schedule_state` 1
  /// (accepted) or 2 (scheduled). Measured on 26.5.2: a fresh scheduled message reads 1 in
  /// the send's own response and 2 seconds later; a cancelled one is deleted outright, and
  /// the states a delivered one moves through were not observed, so they are excluded by
  /// listing the two known-pending values rather than by excluding known-done ones.
  /// Soonest delivery first.
  public func pendingScheduledMessages(
    chatGUID: String? = nil, limit: Int = 500
  ) async throws -> [IMessageRow] {
    let columns = profile.select(Self.messageColumns, from: .message, alias: "m")
    // CLAMPED, like every other paged read here. The query below binds `limit` to `LIMIT ?`
    // directly, and SQLite reads a negative LIMIT as no limit at all, so the value had to
    // pass through the same clamp the `MessageQuery` applies rather than around it.
    let query = MessageQuery(chatGUID: chatGUID, limit: limit, offset: 0)
    let predicate = queryPlan.predicate(for: query)
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
    let placeholders = SQLPlaceholders.list(guids.count)
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
  /// CACHED, because this is not one indexed lookup on a send: `balloon_bundle_id` has no index in
  /// Apple's schema, and adding one to chat.db is not something this server may do, so the
  /// plan is `SCAN m` over every row -- measured at 104ms when nothing matches, which is the
  /// COMMON case, since most Macs have never received a message from a third-party iMessage
  /// app. That cost was paid on every send as that app.
  ///
  /// Invalidation is answered by a TTL rather than by a token: an app's own artwork does not change, and chat.db commits constantly on an
  /// active Mac -- our own sends commit -- so a commit-counter key would miss precisely when
  /// it is wanted. An hour-old icon is the same icon.
  public func balloonIcon(bundleID: String) async throws -> Data? {
    if let cached = balloonIcons.withLock({ $0[bundleID] }) { return cached }
    let icon = try await loadBalloonIcon(bundleID: bundleID)
    balloonIcons.withLock { $0[bundleID] = icon }
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
}

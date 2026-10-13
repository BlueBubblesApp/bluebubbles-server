//  MessageRepository+Counts
//  The totals: messages filtered as the listing is and cached against the commit counter,
//  messages updated in a window, chats by service, handles, and attachments by media bucket.
//
//  A count shares `MessageQueryPlan`, `resolvingSearch` and `hasParticipantsClause` with the
//  listing it accompanies. A total built any other way can disagree with the rows it claims
//  to count, and a client paging by that total pages the wrong number of times.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  // MARK: - Counts

  /// Total messages, with the same filters the listing accepts.
  ///
  /// Uses `COUNT(DISTINCT m.ROWID)` rather than `COUNT(*)`, which is the same rule the
  /// listing keeps: a message appears once however many chat rows it belongs to. The
  /// listing gets there by never joining more than one chat row (`MessageQueryPlan`); the
  /// DISTINCT says the same thing here so the two cannot drift if a join is ever added.
  public func messageCount(_ query: MessageQuery = MessageQuery()) async throws -> Int {
    // The same resolution the listing does; see `resolvingSearch`.
    try await messageCount(await resolvingSearch(query), countingTheJoinWherePossible: true)
  }

  /// - Parameter countingTheJoinWherePossible: false forces the `message`-table form even for
  ///   a whole-conversation query. The only caller that passes false is the parity test, which
  ///   needs the same answer computed the slow way to compare against; a second hand-written
  ///   statement in the test would be a second thing to keep correct.
  func messageCount(
    _ query: MessageQuery, countingTheJoinWherePossible: Bool
  ) async throws -> Int {
    let predicate = queryPlan.predicate(for: query)
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
      let chat = MessageQueryPlan.chatCondition(chatGUID)
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
    if let token, let cached = counts.withLock({ $0.value(token: token, key: key) }) {
      return cached
    }

    let result = try await database.read { db in
      try Int.fetchOne(db, sql: sql, arguments: statementArguments) ?? 0
    }
    if let token { counts.withLock { $0.store(result, token: token, key: key) } }
    return result
  }

  /// `GET /message/count/updated`: how many messages were delivered or read in a window.
  ///
  /// Distinct from `messageCount`, which filters on `date`: the moment a message was
  /// created. A receipt arriving today for a message sent last week moves `date_delivered`
  /// and leaves `date` alone, so counting on `date` would miss exactly the updates this is
  /// asked for.
  ///
  /// It is `messageCount` with the date field switched, not a statement of its own, so the
  /// route applies `chatGuid`, `minRowId` and `maxRowId`, which the reference accepts,
  /// through the same predicate as every other count.
  public func updatedMessageCount(_ query: MessageQuery = MessageQuery()) async throws -> Int {
    var updated = query
    updated.dateField = .updated
    return try await messageCount(updated)
  }

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
      let chat = MessageQueryPlan.chatCondition(chatGUID)
      sql += " WHERE \(chat.condition)"
      arguments.append(contentsOf: chat.arguments)
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

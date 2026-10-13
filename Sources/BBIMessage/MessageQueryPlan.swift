//  MessageQueryPlan
//  What a message query is, and the SQL it becomes.
//
//  Split out of `MessageRepository` because it is the one part of that file that touches no
//  database handle and no cache: given a `MessageQuery` and the schema's date unit it
//  returns a WHERE clause and its bindings, and nothing else. So it is the part a test can
//  drive without a chat.db, and it is the part that GROWS -- every new `MessageFilter` case
//  lands here, next to the filter it renders.
//
//  `MessageRepository`'s two rules still govern every clause written here: never SELECT *,
//  and never widen a query to avoid a join. A third one belongs to this file alone: a
//  condition the caller asked for is either rendered or refused, never dropped. A predicate
//  that silently drops one answers a narrow question with the whole database and returns a
//  200 on it, which the client cannot tell from an honest answer.
//
//  See `.claude/docs/database.md`.

import BBCore
import Foundation
import GRDB

extension MessageRepository {

  public struct MessageQuery: Sendable {
    public var chatGUID: String?
    public var after: Date?
    public var before: Date?
    public var limit: Int
    public var offset: Int
    public var ascending: Bool
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
    /// Applied by `MessageQueryPlan.predicate(for:)`, so the listing and its `total` are filtered by the
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
    /// not something a caller states. See `MessageQueryPlan.predicate(for:)` for why it
    /// matters.
    var resolvedChatRowIDs: [Int64]?

    /// The `.textLike` filters the search index could widen: each term, with the ROWIDs
    /// the index matched for it.
    ///
    /// Derived exactly like `resolvedChatRowIDs`, and for the same reason: it changes the
    /// SHAPE of the query rather than its arguments, so it is resolved before the SQL is
    /// built and is not something a caller states.
    ///
    /// **Each entry carries its term as well as its row ids because the condition is a
    /// UNION**: `m.ROWID IN (…) OR m.text LIKE ?`. The index and the column are two
    /// different questions and NEITHER answer contains the other —
    ///
    ///   - the index reaches messages whose `text` column is empty, which is the whole
    ///     point of it and is everything sent since macOS 26;
    ///   - `LIKE` reaches a fragment in the middle of a word, and a word inside a Chinese
    ///     or Japanese sentence, neither of which a token index can express.
    ///
    /// Replacing the filter instead of widening it was the first shape, and it took results
    /// away. Measured against a real database: `%omorrow%` went from 2,020 messages to
    /// none, and `%morrow%` — where the index legitimately matched ONE token and so looked
    /// like a working answer — went from 2,031 to 1. A search feature that loses 2,030
    /// results is the defect this one exists to fix, wearing the fix as a costume.
    ///
    /// The union costs the scan `LIKE` always cost (110 ms over 422,042 messages, measured)
    /// and buys back every one of those rows, so the feature is purely additive: it cannot
    /// return less than the server did before it existed. That is the property to keep.
    ///
    /// **An ARRAY, because the union composes under `AND` and needs no set arithmetic.**
    /// Every entry becomes its own bracketed `OR` and the `AND` already between filters
    /// does the combining, so two text conditions are two independent widenings rather
    /// than an intersection anybody has to compute. That was not true of the replacement
    /// shape, which is why this was a single value and why only one condition was
    /// answerable: a leftover, not a limit.
    var resolvedSearches: [ResolvedSearch] = []

    /// See `resolvedSearches`.
    struct ResolvedSearch: Sendable, Equatable {
      /// Exactly what the client sent, wildcards included, for the `LIKE` half.
      var term: String
      /// What the index matched. Never empty: `resolvingSearch` leaves a filter alone
      /// rather than resolving it, since an empty set adds nothing to the union.
      var rowIDs: [Int64]
    }

    /// Whether this query is "every message in one conversation", with no condition that
    /// needs a column of `message`.
    ///
    /// `requiresChat` is not consulted: it only adds an EXISTS when `chatGUID` is nil, and
    /// `dateField` only matters when `after` or `before` is set. Written as a list of what
    /// must be ABSENT rather than a flag, so a new condition added to the query plan
    /// without a thought here fails the parity test rather than silently counting wrong.
    var countsAWholeChat: Bool {
      chatGUID != nil && after == nil && before == nil && !onlyFromMe && filters.isEmpty
        && minRowID == nil && maxRowID == nil
        // A resolved search is the case this comment was written for. `resolvingSearch`
        // REMOVES the `.textLike` filter once the index has widened it, so `filters` goes
        // empty and every other clause above stays nil — which without this line reads as
        // "no conditions at all" and counts the whole conversation while the page beside it
        // shows the matches. A search for one word in a chat would have reported the chat's
        // entire message count as its total.
        && resolvedSearches.isEmpty
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
      self.onlyFromMe = onlyFromMe
      self.requiresChat = requiresChat
      self.filters = filters
      self.minRowID = minRowID
      self.maxRowID = maxRowID
      self.dateField = dateField
    }
  }
}

/// Renders a `MessageRepository.MessageQuery` into the FROM and WHERE that a listing and
/// its count both run.
///
/// One renderer rather than one per caller: a count whose predicate has drifted from the
/// listing it counts produces a total that never agrees with the pages, which is the classic
/// and very confusing pagination bug.
struct MessageQueryPlan: Sendable {

  /// Shorthand for the query this plan renders.
  typealias Query = MessageRepository.MessageQuery

  /// Which scale the date columns use.
  ///
  /// The whole of the schema a predicate needs. Taking `SchemaProfile` instead would say
  /// this consults the column sets, and it does not: what exists in the schema decides what
  /// a query SELECTs, which is the repository's job, not this one's.
  let dateUnit: AppleTimestamp.Unit

  /// The FROM and WHERE for one query: the joins it needs, followed by every condition it
  /// asked for, ANDed. Empty for a query that states none.
  func predicate(
    for query: Query
  ) -> (clause: String, arguments: [(any DatabaseValueConvertible)?]) {
    var sql = ""
    var arguments: [(any DatabaseValueConvertible)?] = []
    var conditions: [String] = []

    // Joined only when scoping to ONE chat row, and that is what keeps every message on
    // the page once. `sqlite_autoindex_chat_message_join_1` makes (chat_id, message_id)
    // unique, so a join to a single chat_id cannot repeat a message; a join to two can: a
    // conversation stored under two chat rows (one per service-prefix spelling on an older
    // macOS) would return each message once per row while `messageCount` answers
    // `COUNT(DISTINCT m.ROWID)`, a page and a `total` that disagree. The reference matches
    // `chat.guid = :guid` exactly, one row, so it never sees a message twice either
    // (`getMessages` in `databases/imessage/index.ts`).
    //
    // Scoped by `cmj.chat_id` rather than the GUID when there is one row, and that is not a
    // tidy-up: `chat_message_join_idx_message_date_id_chat_id` leads on `chat_id`, so ONE
    // chat_id lets SQLite walk the index in date order and stop at the limit, while
    // `c.guid IN (?, ?, ?)` makes it gather rows for several chats and sort them. Measured on
    // a 54,777-message conversation: 52ms through the GUID list, 1ms scoped by chat_id, for
    // the same hundred rows.
    //
    // Several rows, or a GUID nothing resolved, is a SEMI-JOIN instead: `m.ROWID IN (…)`
    // asks whether a message belongs to any of them, which no row can answer twice. It
    // leaves no `cmj` in the outer query, so the listing orders by `m.date`; see
    // `joinsOneChat`.
    if let chatRowIDs = query.resolvedChatRowIDs, chatRowIDs.count == 1 {
      sql += "\n JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
      conditions.append("cmj.chat_id = ?")
      arguments.append(chatRowIDs[0])
    } else if let chatRowIDs = query.resolvedChatRowIDs, !chatRowIDs.isEmpty {
      let placeholders = SQLPlaceholders.list(chatRowIDs.count)
      conditions.append(
        """
        m.ROWID IN (
          SELECT cmjS.message_id FROM chat_message_join cmjS
          WHERE cmjS.chat_id IN (\(placeholders))
        )
        """)
      arguments.append(contentsOf: chatRowIDs.map { $0 as (any DatabaseValueConvertible)? })
    } else if let chatGUID = query.chatGUID {
      let chat = Self.chatCondition(chatGUID)
      conditions.append(
        """
        m.ROWID IN (
          SELECT cmjS.message_id FROM chat_message_join cmjS
          JOIN chat c ON c.ROWID = cmjS.chat_id
          WHERE \(chat.condition)
        )
        """)
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

    // Each search index answer ORed with the `LIKE` the client actually sent, and the
    // several of them ANDed by the same rule as any other pair of filters. See
    // `resolvedSearches` for why it is a union rather than a replacement.
    //
    // Literal integers rather than bound parameters, and that is safe BY CONSTRUCTION
    // rather than by inspection: every element is an `Int64` this server read out of its
    // own index, never a value a client sent. Binding them instead would put ten thousand
    // parameters on a statement, against a `SQLITE_MAX_VARIABLE_NUMBER` this code does not
    // get to choose. The term beside them is bound, because that one IS a client's value.
    for search in query.resolvedSearches {
      let list = search.rowIDs.map(String.init).joined(separator: ",")
      conditions.append("(m.ROWID IN (\(list)) OR m.text LIKE ? COLLATE NOCASE)")
      arguments.append(search.term)
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
        let placeholders = SQLPlaceholders.list(guids.count)
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
        let chat = Self.chatCondition(guid, alias: "cF")
        conditions.append(
          """
          EXISTS (
            SELECT 1 FROM chat_message_join cmjF
            JOIN chat cF ON cF.ROWID = cmjF.chat_id
            WHERE cmjF.message_id = m.ROWID AND \(chat.condition)
          )
          """)
        arguments.append(contentsOf: chat.arguments)
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

  /// Whether `predicate(for:)` joins `chat_message_join` as `cmj`, so a listing may order by
  /// `cmj.message_date`.
  ///
  /// True for exactly one resolved chat row, the only scoping that joins. Asked of the plan
  /// rather than inferred from `chatGUID` by the caller, because the two decisions have to
  /// agree: ordering by a `cmj` the FROM clause does not have is a syntax error, and joining
  /// when the scope is several rows is the duplication `predicate` avoids.
  func joinsOneChat(_ query: Query) -> Bool {
    query.resolvedChatRowIDs?.count == 1
  }

  /// How a chat GUID is matched, in one place.
  ///
  /// Service-prefix tolerant, same as `chats(guid:)`: macOS 26 rewrote every `chat.guid` to
  /// the `any;` spelling as a migration, so a client holding `iMessage;-;X` must still find
  /// the chat sitting right there. See ChatGUID.
  ///
  /// The ONLY producer of a chat-GUID clause in this module. It was hand-built five times,
  /// and one copy fell back to `c.guid = ?` for a GUID `ChatGUID` could not parse: the
  /// comparison rule 3 forbids, in the one place nobody was looking.
  /// `ChatGUIDClausePolicyTests` fails the build on a clause written anywhere else.
  ///
  /// `alias` is the table alias the caller joined `chat` as: `c` everywhere except the
  /// correlated subquery in the `where` filters, which needs a name of its own.
  static func chatCondition(
    _ guid: String, alias: String = "c"
  ) -> (condition: String, arguments: [(any DatabaseValueConvertible)?]) {
    let candidates = ChatGUID(guid)?.lookupCandidates() ?? [guid]
    let placeholders = SQLPlaceholders.list(candidates.count)
    return (
      "\(alias).guid IN (\(placeholders))",
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
    _ field: Query.DateField, bounded: Bool, isAfter: Bool = true
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
    _ field: Query.DateField, after: Date?, before: Date?, unit: AppleTimestamp.Unit
  ) -> [(any DatabaseValueConvertible)?] {
    var window: [(any DatabaseValueConvertible)?] = []
    if let after { window.append(AppleTimestamp.from(after, unit: unit).rawValue) }
    if let before { window.append(AppleTimestamp.from(before, unit: unit).rawValue) }
    // `updated` writes the same window twice, once per column.
    return field == .updated ? window + window : window
  }
}

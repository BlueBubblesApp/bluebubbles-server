//  MessageRepository
//  Read-only access to chat.db.
//
//  Raw SQL behind typed request structs rather than an ORM, because Apple owns this schema
//  and changes it per release: an entity model forces version branching into the type
//  definitions.
//
//  Two rules hold everywhere in this file and in every `MessageRepository+*.swift` beside it:
//    - Never SELECT *. A column that vanished takes the query with it, and Sequoia removes
//      a table Sonoma has.
//    - Never widen a query to avoid a join. We cannot add indexes, so a query that misses
//      the ones Messages.app ships full-scans `message`, which is the worst case on the old
//      hardware this targets.
//
//  One type, split by concern: this file holds the stored state, the column sets and what
//  several concerns share; `+Messages`, `+ChangeDetection`, `+Chats`, `+Relations`, `+Counts`
//  and `+Activity` hold the reads. One type rather than one per concern, because the caches,
//  the profile and the query plan belong to the database, and a second repository over the
//  same file would keep a second copy of each.
//
//  See `.claude/docs/database.md`.

import BBCore
import BBPersistence
import Foundation
import GRDB
import Logging

public struct MessageRepository: Sendable {

  /// Internal rather than private, like the state below it that the extension files read:
  /// each concern lives in its own `MessageRepository+*.swift`, and Swift's `private` stops
  /// at the file.
  let database: ReadOnlyDatabase
  let profile: SchemaProfile

  /// Whether this database's `chat_message_join.message_date` can order a chat's messages.
  /// Probed once, lazily; see `joinDatesCanOrderAChat()`. Two callers racing the probe both
  /// run it and reach the same answer, which is why the race is not worth preventing.
  private let joinDates = Locked<Bool?>(nil)

  /// Counts, held against the commit counter that produced them. See `messageCount`.
  let counts = Locked(TokenCache())

  /// Balloon artwork by bundle id, with a TTL. See `balloonIcon`. `Data?` because a MISS is
  /// the expensive answer and the one worth remembering: a full scan that finds nothing
  /// costs the same as one that finds something.
  let balloonIcons = Locked(
    BoundedCache<String, Data?>(capacity: 16, ttl: .seconds(3600)))

  /// Chat GUID to the ROWIDs it names. See `chatRowIDs(for:)`.
  let chatRowIDCache = Locked(TokenCache())

  /// Renders a query into SQL. Holds no database and no cache; see `MessageQueryPlan`.
  let queryPlan: MessageQueryPlan

  /// The search index, when this install has one.
  ///
  /// Optional because it is opt-in and because most callers of this repository have nothing
  /// to do with search: a test, the parity replay and the migration all build a repository
  /// and none of them should have to know this exists. Nil means every `.textLike` filter
  /// goes down the `LIKE` path, which is the behaviour without the feature.
  let searchIndex: SearchIndexStore?

  let logger: Logger

  public init(
    database: ReadOnlyDatabase, profile: SchemaProfile, searchIndex: SearchIndexStore? = nil,
    logger: Logger = Logger(label: "bluebubbles.imessage.messages")
  ) {
    self.database = database
    self.profile = profile
    self.searchIndex = searchIndex
    self.logger = logger
    self.queryPlan = MessageQueryPlan(dateUnit: profile.dateUnit)
  }

  /// Whether a search index was supplied at construction.
  ///
  /// Exists for one assertion: that the composition root hands one over. The parameter
  /// defaults to nil, so a repository built without it is well-formed and silently never
  /// consults an index — which is exactly the wiring bug that shipped past every unit test
  /// in `MessageSearchIndexServiceTests`, because each of those injects its own.
  public var hasSearchIndex: Bool { searchIndex != nil }

  var dateUnit: AppleTimestamp.Unit { profile.dateUnit }

  /// Whether anything was committed to chat.db, as a comparable token. See
  /// `ReadOnlyDatabase.changeToken()`.
  public func changeToken() async throws -> Int {
    try await database.changeToken()
  }

  // MARK: - Column sets
  //
  // Requested columns, filtered to what this schema actually has. Ordered roughly as the
  // serializer needs them so the mapping below reads top to bottom.

  /// Exactly the columns `IMessageRow` maps, and no others.
  ///
  /// A column selected and never mapped costs every message read its bytes and a slot in
  /// the row's column index, for nothing anybody can see. The serializer reads
  /// `IMessageRow`, never a raw row, so a column it needs becomes a field there first and
  /// then joins this list. `MessageColumnTests` holds both directions.
  static let messageColumns: [String] = [
    "ROWID", "guid", "text", "handle_id", "subject", "country", "attributedBody",
    "service", "error", "date", "date_read", "date_delivered", "is_delivered",
    "is_from_me", "is_empty", "is_delayed", "is_auto_reply",
    "is_read", "is_system_message", "is_sent", "has_dd_results", "is_service_message",
    "is_forward", "is_archive", "cache_has_attachments",
    "cache_roomnames", "was_data_detected", "was_deduplicated", "is_audio_message",
    "is_played", "date_played", "item_type", "other_handle", "group_title",
    "group_action_type", "share_status", "share_direction", "is_expirable",
    "associated_message_guid",
    "associated_message_type", "associated_message_emoji", "schedule_type", "schedule_state",
    "balloon_bundle_id", "payload_data",
    "expressive_send_style_id", "time_expressive_send_played",
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

  // MARK: - Shared across the family
  //
  // Read by more than one of the extension files, so it belongs to none of them.

  public static let hydrationChunk = 500

  /// A chat with somebody in it.
  ///
  /// One definition, used by the listing and by both counts, so a total can never disagree
  /// with the rows it claims to count.
  static let hasParticipantsClause =
    "EXISTS (SELECT 1 FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID)"

  /// Whether `chat_message_join.message_date` can be used to order a chat's messages.
  ///
  /// It is a copy of `message.date` that Messages maintains, and on this machine all 417,332
  /// join rows agree with the message they point at. That has NOT been verified on Sonoma or
  /// Sequoia, and a row where the copy is zero or null would sort that message to the wrong
  /// end of the transcript — a wrong answer, not a slow one. So the database is asked rather
  /// than assumed: one covering-index seek, measured well under a millisecond, cached for the
  /// life of the repository, and any disagreement falls back to `m.date` and the temp b-tree.
  ///
  /// A failure to probe answers false for THIS query, because the slow ordering is the
  /// correct one, and is not cached: a probe that failed says nothing about the rows, and
  /// caching its `false` kept every chat on the slow plan for the life of the process with
  /// nothing said. The next query asks again.
  func joinDatesCanOrderAChat() async -> Bool {
    if let known = joinDates.withLock({ $0 }) { return known }
    do {
      let usable = try await database.read { db in
        try Bool.fetchOne(
          db,
          sql: """
            SELECT NOT EXISTS (
              SELECT 1 FROM chat_message_join WHERE message_date = 0 OR message_date IS NULL
            )
            """) ?? false
      }
      joinDates.withLock { $0 = usable }
      return usable
    } catch {
      logger.warning(
        "Could not check whether join dates can order a chat; using the slower ordering",
        metadata: ["error": .string(String(describing: error))])
      return false
    }
  }
}

/// Counts and ROWID lists held against the commit counter that produced them.
///
/// `MessageRepository` is a `Sendable` struct built once at composition, so it has nowhere to
/// keep these; a `Locked` of this is that place, shared by every copy. A token change drops
/// everything rather than expiring entries one at a time: any commit can move any count, and
/// there is no cheap way to know which.
struct TokenCache: Sendable {
  private var token: Int?
  private var counts: [String: Int] = [:]
  private var rowIDLists: [String: [Int64]] = [:]

  /// Bounded because the key includes the query's arguments, which a client chooses. A
  /// client paging with a moving `after` would otherwise add an entry per request.
  private let capacity = 64

  func value(token: Int, key: String) -> Int? {
    self.token == token ? counts[key] : nil
  }

  func rowIDs(token: Int, key: String) -> [Int64]? {
    self.token == token ? rowIDLists[key] : nil
  }

  mutating func store(_ value: [Int64], token: Int, key: String) {
    reset(to: token)
    if rowIDLists.count >= capacity { rowIDLists.removeAll(keepingCapacity: true) }
    rowIDLists[key] = value
  }

  mutating func store(_ value: Int, token: Int, key: String) {
    reset(to: token)
    if counts.count >= capacity { counts.removeAll(keepingCapacity: true) }
    counts[key] = value
  }

  /// Drops both maps when `token` is not the one they were taken against.
  private mutating func reset(to token: Int) {
    guard self.token != token else { return }
    self.token = token
    counts.removeAll(keepingCapacity: true)
    rowIDLists.removeAll(keepingCapacity: true)
  }
}

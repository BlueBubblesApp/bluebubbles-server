//  ScheduledMessageRepository
//  The only path to the `scheduled_message` table.
//
//  `ScheduleInterface` owned the record type and every CRUD statement, and
//  `ScheduledMessageService` reached around it with two hand-written UPDATEs against the
//  same table, including the one that decides whether a recurring message moves forward or
//  is marked terminal. A table whose most consequential write lives outside its owner is a
//  table with no owner.
//
//  Storage lives here. `ScheduleInterface` keeps what is genuinely its job (validating what
//  a client sent) and the service keeps the scheduling decisions.

import BBPersistence
import BBSerialization
import Foundation
import GRDB

/// What a scheduled message is waiting on.
public enum ScheduledMessageStatus: String, Sendable, CaseIterable {
  case pending
  case sent
  case failed
  /// Recurring schedules stay `pending` and move their date forward; this is for one the
  /// user stopped.
  case cancelled
}

public struct ScheduledMessage: Sendable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "scheduled_message"

  public var id: Int64?
  public var type: String
  public var payload: Data
  public var scheduledFor: Date
  /// The date the series started from, which recurrence counts from; see
  /// `ScheduledMessageService.nextOccurrence`. Set when the message is created or
  /// rescheduled and never moved by a send. Nil only on a row written before the column
  /// existed and not yet backfilled, which the service treats as "count from
  /// `scheduledFor`". Not on the wire: the v1 projection is frozen.
  public var firstScheduledFor: Date?
  /// Recurrence, as an opaque client blob. Nil for a one-shot.
  public var schedule: Data?
  public var status: String
  public var error: String?
  public var sentAt: Date?
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, type, payload, schedule, status, error
    case scheduledFor = "scheduled_for"
    case firstScheduledFor = "first_scheduled_for"
    case sentAt = "sent_at"
    case createdAt = "created_at"
  }

  public init(
    id: Int64?,
    type: String,
    payload: Data,
    scheduledFor: Date,
    schedule: Data?,
    status: String,
    error: String?,
    sentAt: Date?,
    createdAt: Date,
    firstScheduledFor: Date? = nil
  ) {
    self.id = id
    self.type = type
    self.payload = payload
    self.scheduledFor = scheduledFor
    self.firstScheduledFor = firstScheduledFor
    self.schedule = schedule
    self.status = status
    self.error = error
    self.sentAt = sentAt
    self.createdAt = createdAt
  }

  /// ISO 8601 STRINGS for the three dates, not epoch milliseconds.
  ///
  /// Third place this has come up, and the rule that separates them is worth stating once:
  /// the contract's epoch-milliseconds rule governs the MESSAGE serializers, where the
  /// reference converts by hand with `.getTime()`. This route returns a TypeORM entity, and
  /// `scheduledFor`, `sentAt` and `created` are `Date` columns on it, so `JSON.stringify`
  /// renders them as ISO, exactly as it does for `alert.created` and for the dates inside a
  /// decoded `chat.properties` blob.
  ///
  /// Measured against a live Electron server: `"2026-08-30T16:24:00.000Z"` there against
  /// `1787869718000` here, on all three fields at once.
  public var json: JSONValue {
    var object = JSONObjectBuilder()
    object.set("id", .int64(id ?? 0))
    object.set("type", .string(type))
    object.set("payload", (try? JSONValue.parse(payload)) ?? .null)
    object.set("scheduledFor", .string(WireDate.iso(scheduledFor)))
    // NEVER null: the column is `nullable: false` on the reference and a one-shot carries
    // `{"type":"once", …}` just as a recurring one carries `{"type":"recurring", …}`.
    // Falling back to an object rather than null keeps a client from having to handle a
    // case the reference cannot produce.
    object.set(
      "schedule",
      schedule.flatMap { try? JSONValue.parse($0) } ?? .object(["type": .string("once")])
    )
    object.set("status", .string(status))
    object.setOrNull("error", error.map(JSONValue.string))
    object.setOrNull("sentAt", sentAt.map { .string(WireDate.iso($0)) })
    object.set("created", .string(WireDate.iso(createdAt)))
    return object.build()
  }
}

public struct ScheduledMessageRepository: Sendable {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func all(status: ScheduledMessageStatus? = nil) async throws -> [ScheduledMessage] {
    try await database.read { db in
      var request = ScheduledMessage.order(Column("scheduled_for").asc)
      if let status { request = request.filter(Column("status") == status.rawValue) }
      return try request.fetchAll(db)
    }
  }

  public func find(id: Int64) async throws -> ScheduledMessage? {
    try await database.read { db in
      try ScheduledMessage.filter(Column("id") == id).fetchOne(db)
    }
  }

  /// Messages that are due, oldest first.
  ///
  /// Bounded: a server that was off for a month must not try to send its whole backlog in
  /// one tick. The rest go on the next one.
  public func due(
    at moment: Date, limit: Int = 50
  ) async throws -> [ScheduledMessage] {
    try await database.read { db in
      try ScheduledMessage
        .filter(Column("status") == ScheduledMessageStatus.pending.rawValue)
        .filter(Column("scheduled_for") <= moment)
        .order(Column("scheduled_for").asc)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// Inserts a new message and returns it with its assigned id.
  public func insert(_ record: ScheduledMessage) async throws -> ScheduledMessage {
    try await database.write { db in
      var stored = record
      try stored.insert(db)
      stored.id = db.lastInsertedRowID
      return stored
    }
  }

  public func update(_ record: ScheduledMessage) async throws {
    try await database.write { db in try record.update(db) }
  }

  public func delete(id: Int64) async throws -> Bool {
    try await database.write { db in
      try ScheduledMessage.filter(Column("id") == id).deleteAll(db) > 0
    }
  }

  /// Removes every message that has reached a terminal status, and reports how many.
  ///
  /// Keyed on NOT pending rather than on a list of finished statuses, so a status added
  /// later is cleared rather than left behind. Pending is the one row this must not touch,
  /// and it includes a recurring message between occurrences: that one stays `pending` and
  /// moves its date forward, so it never appears in the history this clears.
  public func deleteFinished() async throws -> Int {
    try await database.write { db in
      try ScheduledMessage
        .filter(Column("status") != ScheduledMessageStatus.pending.rawValue)
        .deleteAll(db)
    }
  }

  /// Takes a due message OUT of the due set, before the send is attempted.
  ///
  /// **This is what makes a dispatch at-most-once, and it has to happen first.** `due(at:)`
  /// selects on `status = pending AND scheduled_for <= now`, so a row stays due for as long
  /// as it has not been written. Recording the outcome only AFTER the send meant a crash, an
  /// out-of-memory kill or a `replaceProcess()` mid-send left the row exactly as it was, and
  /// the next sweep sent the same message to a real person again. The comment on the sweep
  /// described this ordering; the code did not implement it.
  ///
  /// The trade is deliberate and is the one the sweep's comment asks for: a send interrupted
  /// after this write and before it completes is NOT retried. Sending a message twice is
  /// visible to the recipient and cannot be taken back; not sending one is visible to the
  /// sender, who still has the text. `recordOutcome` corrects the row afterwards, including
  /// back to `failed` when the send threw.
  ///
  /// - Parameter nextOccurrence: the next due date for a recurring message, nil for a
  ///   one-shot, which is then marked sent provisionally.
  public func claimForDispatch(id: Int64, nextOccurrence: Date?, at moment: Date) async throws {
    try await database.write { db in
      if let nextOccurrence {
        try db.execute(
          sql: """
            UPDATE scheduled_message
            SET scheduled_for = ?, sent_at = ?, error = NULL
            WHERE id = ?
            """,
          arguments: [nextOccurrence, moment, id]
        )
      } else {
        try db.execute(
          sql: """
            UPDATE scheduled_message
            SET status = ?, sent_at = ?, error = NULL
            WHERE id = ?
            """,
          arguments: [ScheduledMessageStatus.sent.rawValue, moment, id]
        )
      }
    }
  }

  /// Records what a dispatch attempt did.
  ///
  /// The two branches are the whole recurrence rule. A RECURRING message stays `pending` and
  /// moves its date forward whatever this attempt did; only a one-shot reaches a terminal
  /// status. Keeping both in one method is what stops the rule from being restated
  /// (differently) wherever a dispatch happens to end.
  ///
  /// **A failure used to end the series.** The condition was `outcome == .sent`, so a
  /// recurring row whose send threw fell to the else-branch and was written `failed`, and
  /// nothing ever picked it up again. One transient refusal from Messages — the app
  /// restarting, a chat momentarily unresolvable, the helper reconnecting — silently ended a
  /// daily reminder, with the only trace a status the user has no reason to look at. The
  /// reference does the opposite and says so in its own code: `tryReschedule` puts the row
  /// back to pending and reschedules it
  /// (`packages/server/src/server/services/scheduledMessagesService/index.ts:362`).
  ///
  /// The error text is still recorded on the recurring row, so a series that is failing every
  /// time is visible rather than merely quiet. What is not done is giving up after N
  /// failures: a schedule the user created should outlive a bad week, and nothing here can
  /// tell a bad week from a permanent one.
  ///
  /// `sent_at` stays where `claimForDispatch` put it. On this path the column records when
  /// the dispatch was attempted, not when it last succeeded, and that predates this change.
  public func recordOutcome(
    id: Int64,
    nextOccurrence: Date?,
    outcome: ScheduledMessageStatus,
    failure: String?,
    at moment: Date
  ) async throws {
    try await database.write { db in
      if let nextOccurrence {
        try db.execute(
          sql: """
            UPDATE scheduled_message
            SET scheduled_for = ?, error = ?
            WHERE id = ?
            """,
          arguments: [
            nextOccurrence,
            outcome == .sent ? nil : failure,
            // `sent_at` is deliberately NOT written here. `claimForDispatch` sets it when it
            // takes the row, which is the moment the dispatch was attempted, and that is
            // what the column has always meant on this path. Re-writing it from the outcome
            // would either restate the same value or, on a failure, have to decide between
            // erasing a real timestamp and carrying a stale one.
            id,
          ]
        )
      } else {
        try db.execute(
          sql: """
            UPDATE scheduled_message
            SET status = ?, sent_at = ?, error = ?
            WHERE id = ?
            """,
          arguments: [outcome.rawValue, outcome == .sent ? moment : nil, failure, id]
        )
      }
    }
  }
}

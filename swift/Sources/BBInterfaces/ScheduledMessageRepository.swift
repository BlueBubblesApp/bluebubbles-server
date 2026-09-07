//  ScheduledMessageRepository
//  The only path to the `scheduled_message` table.
//
//  `ScheduleInterface` owned the record type and every CRUD statement, and
//  `ScheduledMessageService` reached around it with two hand-written UPDATEs against the
//  same table — including the one that decides whether a recurring message moves forward or
//  is marked terminal. A table whose most consequential write lives outside its owner is a
//  table with no owner.
//
//  Storage lives here. `ScheduleInterface` keeps what is genuinely its job — validating what
//  a client sent — and the service keeps the scheduling decisions.

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
  /// Recurrence, as an opaque client blob. Nil for a one-shot.
  public var schedule: Data?
  public var status: String
  public var error: String?
  public var sentAt: Date?
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, type, payload, schedule, status, error
    case scheduledFor = "scheduled_for"
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
    createdAt: Date
  ) {
    self.id = id
    self.type = type
    self.payload = payload
    self.scheduledFor = scheduledFor
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
  /// `scheduledFor`, `sentAt` and `created` are `Date` columns on it — so `JSON.stringify`
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

  /// Records what a dispatch attempt did.
  ///
  /// The two branches are the whole recurrence rule. A recurring message that sent stays
  /// `pending` and moves its date forward, so the next tick picks it up again; anything
  /// else reaches a terminal status. Keeping both in one method is what stops the rule from
  /// being restated — differently — wherever a dispatch happens to end.
  public func recordOutcome(
    id: Int64,
    nextOccurrence: Date?,
    outcome: ScheduledMessageStatus,
    failure: String?,
    at moment: Date
  ) async throws {
    try await database.write { db in
      if let nextOccurrence, outcome == .sent {
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
            SET status = ?, sent_at = ?, error = ?
            WHERE id = ?
            """,
          arguments: [outcome.rawValue, outcome == .sent ? moment : nil, failure, id]
        )
      }
    }
  }
}

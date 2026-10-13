//  ScheduleInterface
//  Scheduled messages.
//
//  Stored rather than held in memory, and re-read on start: a message scheduled for tomorrow
//  must survive a restart tonight. The current server keeps these in a database too, and a
//  restart there loses the in-flight timers rather than the rows; this reconstructs them.
//
//  Storage and the record type live in `ScheduledMessageRepository`. What is here is this
//  layer's own job: deciding whether what a client sent is acceptable.

import BBAppStore
import BBAudit
import BBCore
import BBPersistence
import BBSerialization
import Foundation
import Logging

public struct ScheduleInterface: Sendable {

  private let store: ScheduledMessageRepository
  /// Where a change to the queue is recorded. Nil in tests; see `AdminInterface.audit`.
  private let audit: (any AuditRecording)?
  private let logger: Logger

  public init(
    database: AppDatabase,
    audit: (any AuditRecording)? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.schedule")
  ) {
    self.store = ScheduledMessageRepository(database: database)
    self.audit = audit
    self.logger = logger
  }

  /// The audit record for a message queued or re-queued. The payload is never in it: the
  /// chat and the text are message content, and the id is enough to find the row.
  private func auditQueued(
    _ kind: AuditEventKind, _ record: ScheduledMessage, _ summary: String
  ) {
    audit?.record(
      AuditEvent(
        kind: kind,
        subject: .scheduledMessage(record.id ?? 0),
        summary: summary,
        metadata: [
          "type": .string(record.type),
          "scheduled_for": .string(AuditTimestamp.string(from: record.scheduledFor)),
          "recurring": .bool(record.schedule != nil),
        ]
      ))
  }

  /// Spelled here as well so callers that already speak in terms of this interface do not
  /// have to learn a second name for the same three words.
  public typealias Status = ScheduledMessageStatus

  /// Every scheduled message, soonest first. The wire projection is `ScheduledMessage.json`.
  public func list(status: Status? = nil) async throws -> [ScheduledMessage] {
    try await store.all(status: status)
  }

  public func find(id: Int64) async throws -> ScheduledMessage {
    guard let record = try await store.find(id: id) else {
      throw InterfaceError.notFound("no scheduled message with id \(id)")
    }
    return record
  }

  // MARK: - What a caller asks for

  /// What is sent when the time comes.
  ///
  /// Stored VERBATIM and echoed back by every read, so a v1 client's own keys survive the
  /// round trip: that is why this wraps the fields rather than modelling them. The typed
  /// initialiser is for a caller with nothing extra to carry, which is the app.
  public struct Payload: Sendable, Equatable {
    let fields: [String: JSONValue]

    /// How the message is sent, in the payload's own spelling.
    public enum Method: String, Sendable {
      case appleScript = "apple-script"
      case privateAPI = "private-api"
    }

    public init(chatGUID: String, message: String, method: Method) {
      fields = [
        "chatGuid": .string(chatGUID),
        "message": .string(message),
        "method": .string(method.rawValue),
      ]
    }

    /// A v1 body's `payload`, kept whole. Anything but an object reads as no fields, which
    /// `validate(payload:)` refuses with the reference's sentence, exactly as it refused the
    /// raw value.
    init(v1 value: JSONValue) {
      if case .object(let fields) = value { self.fields = fields } else { fields = [:] }
    }

    var json: JSONValue { .object(fields) }
  }

  /// When a message repeats.
  ///
  /// Wraps what is stored rather than modelling it, for the reason `Payload` does: a v1
  /// body's `schedule` is stored as it was sent and read back as it was sent, including keys
  /// and `type`s this server does not interpret, and including an explicit `null`.
  public struct Recurrence: Sendable, Equatable {
    let value: JSONValue

    /// - Parameters:
    ///   - intervalType: one of `ScheduleInterface.intervalTypes`.
    ///   - interval: how many of them between sends; at least 1.
    public init(intervalType: String, interval: Int) {
      value = .object([
        "type": .string("recurring"),
        "intervalType": .string(intervalType),
        "interval": .int64(Int64(interval)),
      ])
    }

    init(v1 value: JSONValue) { self.value = value }
  }

  /// A message to schedule.
  public struct NewMessage: Sendable, Equatable {
    /// `send-message` is the only type that is ever performed; see `ScheduledMessageService`.
    public var type: String
    public var payload: Payload
    public var scheduledFor: Date
    public var schedule: Recurrence?

    public init(
      type: String = "send-message", payload: Payload, scheduledFor: Date,
      schedule: Recurrence? = nil
    ) {
      self.type = type
      self.payload = payload
      self.scheduledFor = scheduledFor
      self.schedule = schedule
    }

    /// A `POST /message/schedule` body, refused in the order and with the sentences the
    /// route has always used: the payload, then the schedule, then the date. A date in the
    /// past is `create`'s refusal, because it holds for every caller.
    public init(v1 body: JSONValue) throws {
      guard let payload = body["payload"], case .object = payload else {
        throw InterfaceError.invalidRequest("`payload` is required and must be an object")
      }
      try ScheduleInterface.validate(payload: payload)
      try ScheduleInterface.validate(schedule: body["schedule"])
      // Read as the validator's `numeric` reads it: a string of digits passes there, and
      // refusing it here as "required" contradicted the rule it had just passed.
      guard let scheduledFor = Date(epochMilliseconds: body["scheduledFor"]) else {
        throw InterfaceError.invalidRequest("`scheduledFor` is required, as epoch milliseconds")
      }
      self.init(
        type: body["type"]?.stringValue ?? "send-message",
        payload: Payload(v1: payload),
        scheduledFor: scheduledFor,
        schedule: body["schedule"].map(Recurrence.init(v1:))
      )
    }
  }

  /// What to change about a pending message. A nil field is left as it is.
  public struct Change: Sendable, Equatable {
    public var payload: Payload?
    public var scheduledFor: Date?
    /// `.some(nil)` takes the recurrence away, making the message a one-shot.
    public var schedule: Recurrence??

    public init(
      payload: Payload? = nil, scheduledFor: Date? = nil, schedule: Recurrence?? = nil
    ) {
      self.payload = payload
      self.scheduledFor = scheduledFor
      self.schedule = schedule
    }

    /// A `PUT /message/schedule/:id` body. Nothing is refused here: `update` reads the stored
    /// message first, so a change to a message that does not exist is a 404 whatever else is
    /// wrong with it.
    public init(v1 body: JSONValue) {
      self.init(
        payload: body["payload"].map(Payload.init(v1:)),
        scheduledFor: Date(epochMilliseconds: body["scheduledFor"]),
        schedule: body["schedule"].map { $0.isNull ? nil : Recurrence(v1: $0) }
      )
    }
  }

  // MARK: - Writing

  public func create(_ message: NewMessage) async throws -> ScheduledMessage {
    try Self.validate(payload: message.payload.json)
    try Self.validate(schedule: message.schedule?.value)
    let scheduledFor = message.scheduledFor
    // Rejected rather than sent immediately. A client whose clock is wrong would otherwise
    // fire off a message the user meant for next week, and there is no way to recall it.
    guard scheduledFor > Date() else {
      throw InterfaceError.invalidRequest("`scheduledFor` is in the past")
    }

    let record = ScheduledMessage(
      id: nil,
      type: message.type,
      payload: try message.payload.json.serialize(),
      scheduledFor: scheduledFor,
      schedule: try message.schedule.map { try $0.value.serialize() },
      status: Status.pending.rawValue,
      error: nil,
      sentAt: nil,
      createdAt: Date(),
      // The series counts from the date it was made for. See `firstScheduledFor`.
      firstScheduledFor: scheduledFor
    )
    let inserted = try await store.insert(record)
    // The id and the dates only: the payload carries the chat and the text.
    logger.info(
      "Scheduled message created",
      metadata: [
        "id": .stringConvertible(inserted.id ?? 0),
        "type": .string(inserted.type),
        "scheduledFor": .string("\(scheduledFor)"),
        "recurring": .stringConvertible(inserted.schedule != nil),
      ])
    auditQueued(
      .scheduledMessageCreated, inserted, "Scheduled message \(inserted.id ?? 0) was queued.")
    return inserted
  }

  public func update(id: Int64, _ change: Change) async throws -> ScheduledMessage {
    guard var record = try await store.find(id: id) else {
      throw InterfaceError.notFound("no scheduled message with id \(id)")
    }
    // Only a pending message can be rescheduled: one already sent cannot be unsent, and
    // silently accepting the edit would leave the client showing a future send that will
    // never happen.
    guard record.status == Status.pending.rawValue else {
      throw InterfaceError.invalidRequest(
        "scheduled message \(id) is \(record.status) and cannot be changed")
    }

    if let payload = change.payload {
      try Self.validate(payload: payload.json)
      record.payload = try payload.json.serialize()
    }
    if let when = change.scheduledFor {
      guard when > Date() else {
        throw InterfaceError.invalidRequest("`scheduledFor` is in the past")
      }
      record.scheduledFor = when
      // A reschedule starts the series over from the new date: "monthly from the 15th"
      // moved to the 1st should count from the 1st, not keep landing on the 15th.
      record.firstScheduledFor = when
    }
    if let schedule = change.schedule {
      try Self.validate(schedule: schedule?.value)
      record.schedule = try schedule.map { try $0.value.serialize() }
    }

    let updated = record
    try await store.update(updated)
    logger.info(
      "Scheduled message updated",
      metadata: [
        "id": .stringConvertible(id),
        "scheduledFor": .string("\(updated.scheduledFor)"),
        "recurring": .stringConvertible(updated.schedule != nil),
      ])
    auditQueued(.scheduledMessageUpdated, updated, "Scheduled message \(id) was changed.")
    return updated
  }

  // MARK: - What a schedule has to say

  /// The five intervals a recurring schedule may name.
  ///
  /// Spelled here rather than reached for from `ScheduledMessageService`, which is above
  /// this module: the list is the WIRE vocabulary either way, and
  /// `ScheduleValidationTests` asserts the two agree. A value accepted here and unknown
  /// there is precisely the failure this validation exists to prevent.
  public static let intervalTypes = ["hourly", "daily", "weekly", "monthly", "yearly"]

  /// The fields the reference requires inside `payload` (`scheduledMessageValidator.ts:31`).
  static func validate(payload: JSONValue) throws {
    let missing = ["chatGuid", "message", "method"].filter { !payload[$0].isTruthy }
    guard missing.isEmpty else {
      throw InterfaceError.invalidRequest(
        "Missing required payload fields: \(missing.joined(separator: ", "))")
    }
  }

  /// The recurrence rules, in the reference's own order and wording
  /// (`scheduledMessageValidator.ts:42-65`).
  ///
  /// **This is the half that decided whether a series ever repeated.** The declarative layer
  /// checks that `schedule` is an object and stops there, so an `intervalType` of `"dialy"`
  /// was stored, fell out of `RecurrenceInterval(rawValue:)` when the send fired,
  /// `nextOccurrence` answered nil, and the message went out ONCE while every client went on
  /// showing it as recurring. Nothing logged it: to the service, a schedule with no next
  /// occurrence is a schedule that has ended.
  ///
  /// A `type` this server does not know is deliberately NOT refused. The reference accepts
  /// any string there and only treats `recurring` specially, so refusing anything else would
  /// be stricter than the server this one is replacing — the one direction that can break a
  /// client that works today.
  static func validate(schedule: JSONValue?) throws {
    guard let schedule, !schedule.isNull else { return }
    guard schedule["type"].isTruthy else {
      throw InterfaceError.invalidRequest("Schedule Type is required")
    }

    let interval = schedule["interval"]
    let intervalType = schedule["intervalType"]

    if schedule["type"]?.stringValue == "recurring" {
      guard intervalType.isTruthy, interval.isTruthy else {
        throw InterfaceError.invalidRequest(
          "Recurring schedule requires intervalType and interval")
      }
    }

    if interval.isTruthy {
      guard let value = interval?.numberValue else {
        throw InterfaceError.invalidRequest("Schedule interval must be a number")
      }
      guard value >= 1 else {
        throw InterfaceError.invalidRequest("Schedule interval must be greater than 0")
      }
    }

    if intervalType.isTruthy {
      guard let raw = intervalType?.stringValue, intervalTypes.contains(raw) else {
        throw InterfaceError.invalidRequest(
          "Schedule intervalType must be one of: \(intervalTypes.joined(separator: ", "))")
      }
    }
  }

  public func delete(id: Int64) async throws {
    guard try await store.delete(id: id) else {
      throw InterfaceError.notFound("no scheduled message with id \(id)")
    }
    logger.info("Scheduled message deleted", metadata: ["id": .stringConvertible(id)])
    audit?.record(
      AuditEvent(
        kind: .scheduledMessageDeleted, subject: .scheduledMessage(id),
        summary: "Scheduled message \(id) was removed."))
  }

  /// Clears the history: everything sent, cancelled or failed. Returns how many went.
  ///
  /// A pending message is untouched, whichever way it is pending: a one-shot waiting for
  /// its time, or a recurring one between occurrences. Nothing here can stop a send.
  public func clearFinished() async throws -> Int {
    let removed = try await store.deleteFinished()
    logger.info(
      "Cleared finished scheduled messages", metadata: ["removed": .stringConvertible(removed)])
    if removed > 0 {
      audit?.record(
        AuditEvent(
          kind: .scheduledMessageDeleted,
          summary: "\(removed) finished scheduled messages were cleared.",
          metadata: ["count": .int(removed)]))
    }
    return removed
  }
}

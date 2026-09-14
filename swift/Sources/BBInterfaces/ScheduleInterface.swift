//  ScheduleInterface
//  Scheduled messages.
//
//  Stored rather than held in memory, and re-read on start: a message scheduled for tomorrow
//  must survive a restart tonight. The current server keeps these in a database too, and a
//  restart there loses the in-flight timers rather than the rows; this reconstructs them.
//
//  Storage and the record type live in `ScheduledMessageRepository`. What is here is this
//  layer's own job: deciding whether what a client sent is acceptable.

import BBPersistence
import BBSerialization
import Foundation
import Logging

public struct ScheduleInterface: Sendable {

  private let store: ScheduledMessageRepository
  private let logger: Logger

  public init(
    database: AppDatabase,
    logger: Logger = Logger(label: "bluebubbles.interface.schedule")
  ) {
    self.store = ScheduledMessageRepository(database: database)
    self.logger = logger
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

  public func create(_ body: JSONValue) async throws -> ScheduledMessage {
    guard let payload = body["payload"], case .object = payload else {
      throw InterfaceError.invalidRequest("`payload` is required and must be an object")
    }
    try Self.validate(payload: payload)
    try Self.validate(schedule: body["schedule"])
    guard let milliseconds = body["scheduledFor"]?.intValue else {
      throw InterfaceError.invalidRequest("`scheduledFor` is required, as epoch milliseconds")
    }
    let scheduledFor = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    // Rejected rather than sent immediately. A client whose clock is wrong would otherwise
    // fire off a message the user meant for next week, and there is no way to recall it.
    guard scheduledFor > Date() else {
      throw InterfaceError.invalidRequest("`scheduledFor` is in the past")
    }

    let record = ScheduledMessage(
      id: nil,
      type: body["type"]?.stringValue ?? "send-message",
      payload: try payload.serialize(),
      scheduledFor: scheduledFor,
      schedule: try body["schedule"].map { try $0.serialize() },
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
    return inserted
  }

  public func update(id: Int64, body: JSONValue) async throws -> ScheduledMessage {
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

    if let payload = body["payload"] {
      try Self.validate(payload: payload)
      record.payload = try payload.serialize()
    }
    if let milliseconds = body["scheduledFor"]?.intValue {
      let when = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
      guard when > Date() else {
        throw InterfaceError.invalidRequest("`scheduledFor` is in the past")
      }
      record.scheduledFor = when
      // A reschedule starts the series over from the new date: "monthly from the 15th"
      // moved to the 1st should count from the 1st, not keep landing on the 15th.
      record.firstScheduledFor = when
    }
    if let schedule = body["schedule"] {
      try Self.validate(schedule: schedule)
      record.schedule = schedule.isNull ? nil : try schedule.serialize()
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

  /// JavaScript truthiness, because that is what the reference's checks are written in.
  ///
  /// `!payload[key]`, `schedule.interval &&` and `schedule.intervalType &&` all ask this
  /// question, and the answers differ from Swift's `!= nil` in ways a client can reach: an
  /// empty `chatGuid` is missing, an `interval` of `0` is absent rather than out of range,
  /// and `false` is both. Transcribed once and named, rather than three approximations.
  private static func isTruthy(_ value: JSONValue?) -> Bool {
    switch value {
    case .none, .some(.null): false
    case .some(.bool(let flag)): flag
    case .some(.int(let number)): number != 0
    case .some(.int64(let number)): number != 0
    case .some(.double(let number)): number != 0
    case .some(.string(let text)): !text.isEmpty
    // An array or an object is truthy in JavaScript however empty it is, `[]` included.
    case .some(.array), .some(.object): true
    }
  }

  /// The numeric value, or nil for anything that is not a JSON number. `typeof x !== "number"`.
  private static func number(_ value: JSONValue?) -> Double? {
    switch value {
    case .some(.int(let number)): Double(number)
    case .some(.int64(let number)): Double(number)
    case .some(.double(let number)): number
    default: nil
    }
  }

  /// The fields the reference requires inside `payload` (`scheduledMessageValidator.ts:31`).
  static func validate(payload: JSONValue) throws {
    let missing = ["chatGuid", "message", "method"].filter { !isTruthy(payload[$0]) }
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
    guard isTruthy(schedule["type"]) else {
      throw InterfaceError.invalidRequest("Schedule Type is required")
    }

    let interval = schedule["interval"]
    let intervalType = schedule["intervalType"]

    if schedule["type"]?.stringValue == "recurring" {
      guard isTruthy(intervalType), isTruthy(interval) else {
        throw InterfaceError.invalidRequest(
          "Recurring schedule requires intervalType and interval")
      }
    }

    if isTruthy(interval) {
      guard let value = number(interval) else {
        throw InterfaceError.invalidRequest("Schedule interval must be a number")
      }
      guard value >= 1 else {
        throw InterfaceError.invalidRequest("Schedule interval must be greater than 0")
      }
    }

    if isTruthy(intervalType) {
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
  }

  /// Clears the history: everything sent, cancelled or failed. Returns how many went.
  ///
  /// A pending message is untouched, whichever way it is pending: a one-shot waiting for
  /// its time, or a recurring one between occurrences. Nothing here can stop a send.
  public func clearFinished() async throws -> Int {
    let removed = try await store.deleteFinished()
    logger.info(
      "Cleared finished scheduled messages", metadata: ["removed": .stringConvertible(removed)])
    return removed
  }
}

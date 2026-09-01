//  ScheduleInterface
//  Scheduled messages.
//
//  Stored rather than held in memory, and re-read on start: a message scheduled for tomorrow
//  must survive a restart tonight. The current server keeps these in a database too, and a
//  restart there loses the in-flight timers rather than the rows — this reconstructs them.
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

  /// The wire shape, for the HTTP routes.
  public func list(status: Status? = nil) async throws -> [JSONValue] {
    try await store.all(status: status).map(\.json)
  }

  /// The same messages as VALUES, for callers in this process. See
  /// `ServerInterface.webhookList()` for why both exist.
  public func records(status: Status? = nil) async throws -> [ScheduledMessage] {
    try await store.all(status: status)
  }

  public func find(id: Int64) async throws -> JSONValue {
    guard let record = try await store.find(id: id) else {
      throw InterfaceError.notFound("no scheduled message with id \(id)")
    }
    return record.json
  }

  public func create(_ body: JSONValue) async throws -> JSONValue {
    guard let payload = body["payload"], case .object = payload else {
      throw InterfaceError.invalidRequest("`payload` is required and must be an object")
    }
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
      createdAt: Date()
    )
    return try await store.insert(record).json
  }

  public func update(id: Int64, body: JSONValue) async throws -> JSONValue {
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

    if let payload = body["payload"] { record.payload = try payload.serialize() }
    if let milliseconds = body["scheduledFor"]?.intValue {
      let when = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
      guard when > Date() else {
        throw InterfaceError.invalidRequest("`scheduledFor` is in the past")
      }
      record.scheduledFor = when
    }
    if let schedule = body["schedule"] {
      record.schedule = schedule.isNull ? nil : try schedule.serialize()
    }

    let updated = record
    try await store.update(updated)
    return updated.json
  }

  public func delete(id: Int64) async throws {
    guard try await store.delete(id: id) else {
      throw InterfaceError.notFound("no scheduled message with id \(id)")
    }
  }
}

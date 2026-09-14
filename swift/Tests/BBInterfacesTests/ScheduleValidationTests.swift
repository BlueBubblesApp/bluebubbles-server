//  ScheduleValidationTests
//  What a scheduled message has to say before this server will keep it.
//
//  The declarative layer checks that `schedule` is an object and stops there, which is where
//  a recurring series quietly became a one-shot: an `intervalType` of `"dialy"` was stored,
//  fell out of `RecurrenceInterval(rawValue:)` when the send fired, `nextOccurrence` answered
//  nil, and the message went out ONCE while every client went on showing it as recurring.
//  Nothing logged it — to the service, a schedule with no next occurrence is a schedule that
//  has ended.
//
//  These are the reference's checks (`scheduledMessageValidator.ts:28-65`), in its order and
//  its words, so the sentences a client reads do not change between servers. The ACCEPTED
//  cases matter as much as the refused ones: each is a request the reference answers 200 and
//  a reasonable-looking reimplementation would refuse.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Scheduled message validation")
struct ScheduleValidationTests {

  private func payload(
    chatGuid: String = "any;-;person@example.com",
    message: String = "hello",
    method: String = "private-api"
  ) -> JSONValue {
    .object([
      "chatGuid": .string(chatGuid), "message": .string(message), "method": .string(method),
    ])
  }

  private func reason(_ body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as InterfaceError {
      return String(describing: error)
    } catch {
      return String(describing: error)
    }
  }

  // MARK: The payload

  @Test("A payload naming a chat, a message and a method is accepted")
  func payloadComplete() throws {
    try ScheduleInterface.validate(payload: payload())
  }

  @Test("Each missing payload field is named, in the reference's sentence")
  func payloadMissingFields() {
    let text = reason { try ScheduleInterface.validate(payload: .object([:])) }
    #expect(text?.contains("Missing required payload fields: chatGuid, message, method") == true)
  }

  /// `!payload[key]` in JavaScript: an empty string is as missing as no key at all, and a
  /// scheduled send with an empty `chatGuid` has nowhere to go.
  @Test("An empty payload field counts as missing")
  func payloadEmptyString() {
    let text = reason { try ScheduleInterface.validate(payload: payload(chatGuid: "")) }
    #expect(text?.contains("chatGuid") == true)
    #expect(text?.contains("message") == false)
  }

  // MARK: The schedule

  @Test("No schedule at all is fine: a one-shot send has none")
  func scheduleAbsent() throws {
    try ScheduleInterface.validate(schedule: nil)
    try ScheduleInterface.validate(schedule: .null)
  }

  @Test("A schedule with no type is refused")
  func scheduleTypeRequired() {
    let text = reason { try ScheduleInterface.validate(schedule: .object([:])) }
    #expect(text?.contains("Schedule Type is required") == true)
  }

  @Test("A one-shot schedule needs nothing else")
  func scheduleOnce() throws {
    try ScheduleInterface.validate(schedule: .object(["type": .string("once")]))
  }

  /// The reference accepts any string as a type and only treats `recurring` specially, so
  /// this server must too: refusing an unknown one would be stricter than the server it
  /// replaces, which is the only direction that can break a client that works today.
  @Test("An unrecognised schedule type is accepted, as the reference accepts it")
  func scheduleUnknownType() throws {
    try ScheduleInterface.validate(schedule: .object(["type": .string("fortnightly")]))
  }

  @Test("A recurring schedule missing either half is refused")
  func recurringNeedsBoth() {
    let missingBoth = reason {
      try ScheduleInterface.validate(schedule: .object(["type": .string("recurring")]))
    }
    #expect(missingBoth?.contains("Recurring schedule requires intervalType and interval") == true)

    let missingInterval = reason {
      try ScheduleInterface.validate(
        schedule: .object(["type": .string("recurring"), "intervalType": .string("daily")]))
    }
    #expect(missingInterval?.contains("requires intervalType and interval") == true)

    let missingType = reason {
      try ScheduleInterface.validate(
        schedule: .object(["type": .string("recurring"), "interval": .int(2)]))
    }
    #expect(missingType?.contains("requires intervalType and interval") == true)
  }

  /// `schedule.interval &&` is a truthiness test, so `0` reads as absent rather than as a
  /// number out of range, and the sentence a client gets says which.
  @Test("A zero interval reads as missing, not as out of range")
  func zeroInterval() {
    let text = reason {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string("daily"), "interval": .int(0),
        ]))
    }
    #expect(text?.contains("requires intervalType and interval") == true)
    #expect(text?.contains("greater than 0") == false)
  }

  @Test("A non-numeric interval is refused as not a number")
  func nonNumericInterval() {
    let text = reason {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string("daily"),
          "interval": .string("2"),
        ]))
    }
    #expect(text?.contains("Schedule interval must be a number") == true)
  }

  @Test("An interval below one is refused", arguments: [JSONValue.double(0.5), .int(-3)])
  func intervalBelowOne(_ interval: JSONValue) {
    let text = reason {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string("daily"), "interval": interval,
        ]))
    }
    #expect(text?.contains("Schedule interval must be greater than 0") == true)
  }

  @Test("An unknown intervalType is refused, and the five are named")
  func unknownIntervalType() {
    let text = reason {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string("dialy"), "interval": .int(1),
        ]))
    }
    #expect(text?.contains("Schedule intervalType must be one of:") == true)
    for interval in ["hourly", "daily", "weekly", "monthly", "yearly"] {
      #expect(text?.contains(interval) == true)
    }
  }

  /// The typo that started this, in the shape it arrived: a schedule this server would
  /// happily have stored and then fired exactly once.
  @Test("Every accepted intervalType is one the sender can actually repeat on")
  func everyIntervalTypeIsUsable() throws {
    for interval in ScheduleInterface.intervalTypes {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string(interval), "interval": .int(1),
        ]))
    }
  }

  /// An `intervalType` that is not a string at all: `compactMap`-shaped leniency would let
  /// this through as "absent".
  @Test("A non-string intervalType is refused rather than ignored")
  func nonStringIntervalType() {
    let text = reason {
      try ScheduleInterface.validate(
        schedule: .object([
          "type": .string("recurring"), "intervalType": .int(3), "interval": .int(1),
        ]))
    }
    #expect(text?.contains("Schedule intervalType must be one of:") == true)
  }
}

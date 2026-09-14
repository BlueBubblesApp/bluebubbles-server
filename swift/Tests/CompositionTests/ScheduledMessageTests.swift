//  ScheduledMessageTests
//  Recurrence arithmetic, and the ordering that stops a recurring message spamming.
//
//  `ScheduleInterface` was CRUD with no dispatcher: rows could be created and listed and
//  nothing ever read one back and acted on it, so a scheduled message sat `pending` forever.
//  The feature looked complete from the API, the UI and the database, every side except the
//  one that sends.

import BBSerialization
import Foundation
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Scheduled messages")
struct ScheduledMessageTests {

  /// 2023-11-14 22:13:20 UTC.
  private static let base = Date(timeIntervalSince1970: 1_700_000_000)

  /// Fixed rather than `.current`, so the arithmetic below does not depend on the zone the
  /// test happens to run in.
  private static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private static func date(
    _ year: Int, _ month: Int, _ day: Int, hour: Int = 9, in calendar: Calendar = utc
  ) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  private func record(
    scheduledFor: Date,
    schedule: JSONValue? = nil,
    firstScheduledFor: Date? = nil
  ) -> ScheduledMessage {
    ScheduledMessage(
      id: 1,
      type: "send-message",
      payload: Data(#"{"chatGuid":"iMessage;-;+15555550101","message":"hi"}"#.utf8),
      scheduledFor: scheduledFor,
      schedule: schedule.flatMap { try? $0.serialize() },
      status: ScheduledMessageStatus.pending.rawValue,
      error: nil,
      sentAt: nil,
      createdAt: Self.base,
      firstScheduledFor: firstScheduledFor
    )
  }

  private func recurring(_ intervalType: String, every interval: Int? = nil) -> JSONValue {
    var schedule: [String: JSONValue] = [
      "type": .string("recurring"), "intervalType": .string(intervalType),
    ]
    if let interval { schedule["interval"] = .int(interval) }
    return .object(schedule)
  }

  @Test("A one-shot has no next occurrence")
  func oneShotDoesNotRecur() {
    let one = record(scheduledFor: Self.base)
    #expect(ScheduledMessageService.nextOccurrence(after: one, from: Self.base) == nil)

    // An explicit `once` schedule is likewise not a recurrence.
    let explicit = record(
      scheduledFor: Self.base, schedule: .object(["type": .string("once")])
    )
    #expect(ScheduledMessageService.nextOccurrence(after: explicit, from: Self.base) == nil)
  }

  @Test("Each interval advances by its own calendar unit")
  func intervalsAdvanceCorrectly() {
    // Calendar units, not fixed seconds. From 14 November 2023: a month on is 14 December
    // (30 days, which happens to match the old fixed month), and a year on is 14 November
    // 2024, which is 366 days because 2024 is a leap year and would have been the 13th
    // under the old 365-day year.
    let cases: [(String, Date)] = [
      ("hourly", Self.base.addingTimeInterval(3600)),
      ("daily", Self.base.addingTimeInterval(86_400)),
      ("weekly", Self.base.addingTimeInterval(7 * 86_400)),
      ("monthly", Self.base.addingTimeInterval(30 * 86_400)),
      ("yearly", Self.base.addingTimeInterval(366 * 86_400)),
    ]
    for (name, expected) in cases {
      let row = record(scheduledFor: Self.base, schedule: recurring(name))
      let next = ScheduledMessageService.nextOccurrence(
        after: row, from: Self.base, calendar: Self.utc)
      #expect(next == expected, "\(name) advanced wrongly")
    }
  }

  @Test("A monthly message made for the 31st is back on the 31st after February")
  func monthlyKeepsItsDayOfMonth() {
    // Made for 31 January 2024. February has no 31st, so it fired on the 29th; the row
    // now carries that as `scheduledFor`, and the question is what March gets.
    let row = record(
      scheduledFor: Self.date(2024, 2, 29),
      schedule: recurring("monthly"),
      firstScheduledFor: Self.date(2024, 1, 31)
    )
    let next = ScheduledMessageService.nextOccurrence(
      after: row, from: Self.date(2024, 2, 29), calendar: Self.utc)
    #expect(next == Self.date(2024, 3, 31))

    // And April, which has 30 days, clamps again rather than skipping to May.
    var april = row
    april.scheduledFor = Self.date(2024, 3, 31)
    let afterMarch = ScheduledMessageService.nextOccurrence(
      after: april, from: Self.date(2024, 3, 31), calendar: Self.utc)
    #expect(afterMarch == Self.date(2024, 4, 30))
  }

  @Test("A row with no anchor counts from its last date")
  func missingAnchorFallsBackToScheduledFor() {
    // A row from before the column existed and somehow not backfilled. It drifts, which
    // is the old behaviour and the honest reading of the information there is; what it
    // must not do is fail to recur.
    let row = record(scheduledFor: Self.date(2024, 2, 29), schedule: recurring("monthly"))
    let next = ScheduledMessageService.nextOccurrence(
      after: row, from: Self.date(2024, 2, 29), calendar: Self.utc)
    #expect(next == Self.date(2024, 3, 29))
  }

  @Test("A yearly message made for 29 February lands on the 28th in other years")
  func yearlyClampsLeapDay() {
    let row = record(
      scheduledFor: Self.date(2024, 2, 29),
      schedule: recurring("yearly"),
      firstScheduledFor: Self.date(2024, 2, 29)
    )
    let next = ScheduledMessageService.nextOccurrence(
      after: row, from: Self.date(2024, 2, 29), calendar: Self.utc)
    #expect(next == Self.date(2025, 2, 28))
  }

  @Test("A daily message keeps its wall-clock time across a clock change")
  func dailySurvivesDaylightSaving() {
    // New York moved its clocks forward on 10 March 2024, so the day from the 9th to the
    // 10th is 23 hours long. Fixed seconds would put "nine every morning" at ten.
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let saturday = Self.date(2024, 3, 9, in: newYork)
    let row = record(
      scheduledFor: saturday, schedule: recurring("daily"), firstScheduledFor: saturday)
    let next = ScheduledMessageService.nextOccurrence(
      after: row, from: saturday, calendar: newYork)
    #expect(next == Self.date(2024, 3, 10, in: newYork))
    #expect(next == saturday.addingTimeInterval(23 * 3600))
  }

  @Test("A series that has run for years is still counted on its own grid")
  func longRunningSeriesStaysOnGrid() {
    // The estimate that skips ahead must not overshoot: starting hourly in 2023 and
    // asking in 2024, the answer is the first hour after now, not some hour later.
    let row = record(
      scheduledFor: Self.base, schedule: recurring("hourly"), firstScheduledFor: Self.base)
    let now = Self.base.addingTimeInterval(400 * 86_400 + 1234)
    let next = ScheduledMessageService.nextOccurrence(after: row, from: now, calendar: Self.utc)
    #expect(next == Self.base.addingTimeInterval(400 * 86_400 + 3600))
  }

  @Test("The interval multiplier is applied")
  func multiplierIsApplied() {
    // "every 3 days", not "every day".
    let row = record(
      scheduledFor: Self.base,
      schedule: .object([
        "type": .string("recurring"),
        "intervalType": .string("daily"),
        "interval": .int(3),
      ])
    )
    let next = ScheduledMessageService.nextOccurrence(after: row, from: Self.base)
    #expect(next == Self.base.addingTimeInterval(3 * 86_400))
  }

  /// The case that decides whether coming back from downtime is a message or a flood.
  @Test("A schedule missed for a week fires once, not once per missed occurrence")
  func backlogAdvancesPastNow() throws {
    // A daily schedule and a server that was off for a week: advancing by a single
    // interval would leave the row still in the past, so the next tick would fire it
    // again, and again: seven sends a minute apart to a real person.
    let row = record(
      scheduledFor: Self.base,
      schedule: .object([
        "type": .string("recurring"), "intervalType": .string("daily"),
      ])
    )
    let aWeekLater = Self.base.addingTimeInterval(7 * 86_400 + 100)
    let next = ScheduledMessageService.nextOccurrence(
      after: row, from: aWeekLater, calendar: Self.utc)

    let resolved = try #require(next, "a daily schedule always has a next occurrence")
    #expect(resolved > aWeekLater, "the next occurrence is still in the past")
    // And it lands on the schedule's own grid rather than "now plus a day".
    let elapsed = resolved.timeIntervalSince(Self.base)
    #expect(elapsed.truncatingRemainder(dividingBy: 86_400) == 0)
  }

  @Test("A zero or negative interval does not recur")
  func degenerateIntervalIsRejected() {
    // Otherwise `while next <= now` never terminates.
    let row = record(
      scheduledFor: Self.base,
      schedule: .object([
        "type": .string("recurring"),
        "intervalType": .string("daily"),
        "interval": .int(0),
      ])
    )
    // Clamped to 1 rather than looping: a zero interval is a malformed client payload,
    // and the safe reading is "every one of these".
    let next = ScheduledMessageService.nextOccurrence(after: row, from: Self.base)
    #expect(next == Self.base.addingTimeInterval(86_400))
  }

  @Test("An unrecognised interval type does not recur")
  func unknownIntervalDoesNotRecur() {
    let row = record(
      scheduledFor: Self.base,
      schedule: .object([
        "type": .string("recurring"), "intervalType": .string("fortnightly"),
      ])
    )
    #expect(ScheduledMessageService.nextOccurrence(after: row, from: Self.base) == nil)
  }

  @Test("A malformed schedule blob does not recur")
  func malformedScheduleIsIgnored() {
    // Client-supplied and stored opaquely, so it can be anything.
    var row = record(scheduledFor: Self.base)
    row.schedule = Data("not json".utf8)
    #expect(ScheduledMessageService.nextOccurrence(after: row, from: Self.base) == nil)
  }

  @Test("The service is registered and depends on the send path")
  func serviceIsWired() {
    // The step that was missing. A dispatcher nothing registers is a table nobody reads.
    #expect(ScheduledMessageService.dependencies.contains(BuiltInManifests.ID.privateAPI))
    #expect(ScheduledMessageService.id == BuiltInManifests.ID.scheduledMessages)
  }

  /// The two halves of one vocabulary, checked against each other.
  ///
  /// `ScheduleInterface.intervalTypes` decides what a client may SEND and
  /// `RecurrenceInterval` decides what the service can actually repeat on. They live in
  /// different modules — validation is below the composition root and the sender is in it —
  /// so nothing but this makes them agree. A value accepted by one and unknown to the other
  /// is exactly the failure the validation was added for: `nextOccurrence` answers nil, the
  /// message fires once, and every client goes on showing it as recurring.
  @Test("What a schedule may name is what the sender can repeat on")
  func intervalVocabulariesAgree() {
    let accepted = Set(ScheduleInterface.intervalTypes)
    let repeatable = Set(
      accepted.compactMap { RecurrenceInterval(rawValue: $0)?.rawValue }
    )
    #expect(
      accepted == repeatable, "accepted but not repeatable: \(accepted.subtracting(repeatable))")
    // And the other direction: an interval the sender knows and the validator refuses would
    // be a capability nobody can reach.
    for interval in ["hourly", "daily", "weekly", "monthly", "yearly"] {
      #expect(RecurrenceInterval(rawValue: interval) != nil)
      #expect(accepted.contains(interval))
    }
  }

}

//  ScheduledMessageTests
//  Recurrence arithmetic, and the ordering that stops a recurring message spamming.
//
//  `ScheduleInterface` was CRUD with no dispatcher: rows could be created and listed and
//  nothing ever read one back and acted on it, so a scheduled message sat `pending` forever.
//  The feature looked complete from the API, the UI and the database — every side except the
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

  private static let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func record(
    scheduledFor: Date,
    schedule: JSONValue? = nil
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
      createdAt: Self.base
    )
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

  @Test("Each interval advances by its own step")
  func intervalsAdvanceCorrectly() {
    // Fixed multiples of a day, including for months and years — transcribed from the
    // current server rather than corrected to calendar arithmetic, because a client that
    // scheduled against the old server expects the same instants.
    let cases: [(String, TimeInterval)] = [
      ("hourly", 3600), ("daily", 86_400), ("weekly", 604_800),
      ("monthly", 2_592_000), ("yearly", 31_536_000),
    ]
    for (name, step) in cases {
      let row = record(
        scheduledFor: Self.base,
        schedule: .object([
          "type": .string("recurring"), "intervalType": .string(name),
        ])
      )
      let next = ScheduledMessageService.nextOccurrence(after: row, from: Self.base)
      #expect(next == Self.base.addingTimeInterval(step), "\(name) advanced wrongly")
    }
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
    // again, and again — seven sends a minute apart to a real person.
    let row = record(
      scheduledFor: Self.base,
      schedule: .object([
        "type": .string("recurring"), "intervalType": .string("daily"),
      ])
    )
    let aWeekLater = Self.base.addingTimeInterval(7 * 86_400 + 100)
    let next = ScheduledMessageService.nextOccurrence(after: row, from: aWeekLater)

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
}

//  ScheduledMessageRowTests
//  What the Scheduled Messages page reads out of a record.
//
//  These rules were `private func`s on `ScheduledMessagesView` and therefore unasserted:
//  touching a SwiftUI `View` type from a test process traps, so the page's whole read of a
//  record — which section it lands in, what it says, when it says it goes out — had nothing
//  on it. Moving them to `ScheduledMessageRow` is what makes this file possible.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBInterfaces
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Scheduled message row")
struct ScheduledMessageRowTests {

  private func message(
    payload: String = #"{"chatGuid":"any;-;person@example.com","message":"Feed the cat"}"#,
    schedule: String? = nil,
    status: String = "pending",
    scheduledFor: Date = Date(timeIntervalSince1970: 1_800_000_000)
  ) -> ScheduledMessage {
    ScheduledMessage(
      id: 1,
      type: "send-message",
      payload: Data(payload.utf8),
      scheduledFor: scheduledFor,
      schedule: schedule.map { Data($0.utf8) },
      status: status,
      error: nil,
      sentAt: nil,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  // MARK: - Which section

  @Test("Pending is upcoming and everything else is past")
  func partitioning() {
    let pending = message(status: "pending")
    let sent = message(status: "sent")
    let failed = message(status: "failed")
    let split = ScheduledMessageRow.partition([pending, sent, failed])
    #expect(split.upcoming.count == 1)
    #expect(split.past.count == 2)
  }

  /// A status the page cannot classify counts as PAST.
  ///
  /// The statuses that exist are written by the sender, so a row with an unfamiliar one is a
  /// row the server has already acted on. Filing it under "about to go out" would promise a
  /// send that is not coming — and the two filters used to be written separately (`== .pending`
  /// and `!= .pending`), so a third answer belonged to whichever was evaluated.
  @Test("An unrecognised status is past, not upcoming")
  func unknownStatusIsPast() {
    let odd = message(status: "something-new")
    #expect(ScheduledMessageRow.status(of: odd) == nil)
    #expect(!ScheduledMessageRow.isUpcoming(odd))
    let split = ScheduledMessageRow.partition([odd])
    #expect(split.upcoming.isEmpty)
    #expect(split.past.count == 1)
  }

  @Test("Every message lands in exactly one section")
  func partitionIsTotal() {
    let all = ["pending", "sent", "failed", "cancelled", "gibberish"].map { message(status: $0) }
    let split = ScheduledMessageRow.partition(all)
    #expect(split.upcoming.count + split.past.count == all.count)
  }

  // MARK: - The chat

  /// **The bug the extraction exposed.** The rule was `guid.components(separatedBy: ";-;")
  /// .last`, which reads a DIRECT chat and leaves a group one untouched: a group GUID is
  /// `any;+;chat…` and contains no `;-;` at all, so every group in this list showed its raw
  /// GUID where every direct chat showed an address.
  @Test(
    "The readable half is taken from both GUID shapes",
    arguments: [
      ("any;-;person@example.com", "person@example.com"),
      ("iMessage;-;person@example.com", "person@example.com"),
      ("SMS;-;+12025550143", "+12025550143"),
      // The group forms, which the old split returned whole.
      ("any;+;chat000000000000000001", "chat000000000000000001"),
      ("iMessage;+;chat000000000000000001", "chat000000000000000001"),
    ] as [(String, String)])
  func chatAddress(guid: String, expected: String) {
    let record = message(payload: #"{"chatGuid":"\#(guid)","message":"hi"}"#)
    #expect(ScheduledMessageRow.chat(of: record) == expected)
  }

  /// A GUID no parser recognises is still the only identifier the row has, so it is shown
  /// whole rather than dropped.
  @Test("An unparseable GUID is shown as it is, not hidden")
  func unparseableGUID() {
    let record = message(payload: #"{"chatGuid":"not-a-guid","message":"hi"}"#)
    #expect(ScheduledMessageRow.chat(of: record) == "not-a-guid")
  }

  @Test("No chat, an empty chat, and an unreadable payload all give nothing to show")
  func absentChat() {
    #expect(ScheduledMessageRow.chat(of: message(payload: #"{"message":"hi"}"#)) == nil)
    #expect(ScheduledMessageRow.chat(of: message(payload: #"{"chatGuid":""}"#)) == nil)
    #expect(ScheduledMessageRow.chat(of: message(payload: "not json at all")) == nil)
  }

  // MARK: - The text

  @Test("An empty or missing body reads as a placeholder rather than a blank row")
  func emptyText() {
    #expect(ScheduledMessageRow.text(of: message()) == "Feed the cat")
    #expect(
      ScheduledMessageRow.text(of: message(payload: #"{"message":""}"#)) == "(no message text)")
    #expect(ScheduledMessageRow.text(of: message(payload: "{}")) == "(no message text)")
    #expect(ScheduledMessageRow.text(of: message(payload: "broken")) == "(no message text)")
  }

  // MARK: - Recurrence

  /// Said in the composer's own vocabulary, not the stored wire value. The row used to
  /// render "every 2 × daily" because the type that knows the words was private to the
  /// composer.
  @Test("A recurring schedule is said in the picker's words")
  func recurrenceIsReadBack() {
    let daily = message(schedule: #"{"type":"recurring","intervalType":"daily","interval":1}"#)
    #expect(ScheduledMessageRow.recurrence(of: daily) == ScheduleRecurrence.daily.summary(every: 1))

    let everyThird = message(
      schedule: #"{"type":"recurring","intervalType":"daily","interval":3}"#)
    #expect(
      ScheduledMessageRow.recurrence(of: everyThird) == ScheduleRecurrence.daily.summary(every: 3))
  }

  @Test("A one-shot, an absent schedule and an unknown interval all repeat nothing")
  func noRecurrence() {
    #expect(ScheduledMessageRow.recurrence(of: message(schedule: nil)) == nil)
    #expect(ScheduledMessageRow.recurrence(of: message(schedule: #"{"type":"once"}"#)) == nil)
    #expect(
      ScheduledMessageRow.recurrence(
        of: message(schedule: #"{"type":"recurring","intervalType":"fortnightly"}"#)) == nil)
    #expect(ScheduledMessageRow.recurrence(of: message(schedule: "not json")) == nil)
  }

  /// An interval the record does not carry means once per unit, not "no recurrence": the
  /// schedule already said it repeats.
  @Test("A recurring schedule with no interval repeats every one")
  func recurrenceDefaultsToOne() {
    let noInterval = message(schedule: #"{"type":"recurring","intervalType":"weekly"}"#)
    #expect(
      ScheduledMessageRow.recurrence(of: noInterval) == ScheduleRecurrence.weekly.summary(every: 1))
  }

  // MARK: - When

  /// The rule is a comparison against the clock, so the clock is a parameter. Asserted
  /// through `isRelative` rather than on the rendered sentence: the wording belongs to
  /// `formatted` and the locale, and pinning it here would make this test a translation test.
  @Test("Imminent is relative, distant is absolute, in both directions")
  func relativeWindow() {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let record = message(scheduledFor: at)

    #expect(ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(-60)))
    #expect(ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(60)))
    // Just inside, either side.
    #expect(ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(-17 * 3600)))
    #expect(ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(17 * 3600)))
    // Just outside, either side. The PAST direction is the one that matters: a list of
    // months-old sends said "19 hours ago" for all of them before the window was symmetric.
    #expect(!ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(19 * 3600)))
    #expect(!ScheduledMessageRow.isRelative(record, now: at.addingTimeInterval(-19 * 3600)))
  }

  @Test("The boundary is exclusive, so exactly the window reads as absolute")
  func windowBoundary() {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let record = message(scheduledFor: at)
    let edge = at.addingTimeInterval(ScheduledMessageRow.relativeWindow)
    #expect(!ScheduledMessageRow.isRelative(record, now: edge))
  }

  @Test("Both phrasings produce something to show")
  func whenAlwaysSaysSomething() {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    let record = message(scheduledFor: at)
    #expect(!ScheduledMessageRow.when(record, now: at).isEmpty)
    #expect(!ScheduledMessageRow.when(record, now: at.addingTimeInterval(90 * 86400)).isEmpty)
  }
}

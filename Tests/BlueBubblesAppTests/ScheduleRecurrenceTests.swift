//  ScheduleRecurrenceTests
//  The wire vocabulary is frozen, and a stored schedule reads back as the case that wrote it.

import Testing

@testable import BlueBubblesApp

@Suite("Schedule recurrence")
struct ScheduleRecurrenceTests {

  @Test("The wire spellings are the v1 ones")
  func wireVocabulary() {
    // Shipped clients and the reference server match on these exact strings. Renaming a
    // case must not change them, which is why they are declared rather than derived.
    #expect(ScheduleRecurrence.never.intervalType == nil)
    #expect(ScheduleRecurrence.hourly.intervalType == "hourly")
    #expect(ScheduleRecurrence.daily.intervalType == "daily")
    #expect(ScheduleRecurrence.weekly.intervalType == "weekly")
    #expect(ScheduleRecurrence.monthly.intervalType == "monthly")
    #expect(ScheduleRecurrence.yearly.intervalType == "yearly")
  }

  @Test("Every wire spelling reads back as the case that writes it")
  func roundTrip() {
    for recurrence in ScheduleRecurrence.allCases {
      guard let wire = recurrence.intervalType else { continue }
      #expect(ScheduleRecurrence(intervalType: wire) == recurrence)
    }
  }

  @Test("An unknown spelling is nil, not a guess")
  func unknownSpelling() {
    // A schedule written by a newer server, or by a client with its own vocabulary. The
    // row shows nothing rather than claiming the wrong period.
    #expect(ScheduleRecurrence(intervalType: "fortnightly") == nil)
    #expect(ScheduleRecurrence(intervalType: "") == nil)
  }

  @Test("One interval keeps the adverb; more than one counts periods")
  func summaries() {
    #expect(ScheduleRecurrence.daily.summary(every: 1) == "daily")
    // "every 1 day" is not how anyone says it, and the picker that set it said "Daily".
    #expect(ScheduleRecurrence.daily.summary(every: 0) == "daily")
    #expect(ScheduleRecurrence.daily.summary(every: 3) == "every 3 days")
    #expect(ScheduleRecurrence.weekly.summary(every: 2) == "every 2 weeks")
    #expect(ScheduleRecurrence.never.summary(every: 2) == nil)
  }
}

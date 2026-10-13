//  MessageFlowTests
//  Where a day starts and ends, and how the repository's counts fold into a chart.

import BBIMessage
import BBInterfaces
import Foundation
import Testing

@Suite("Message flow")
struct MessageFlowTests {

  private static func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  @Test("Days run oldest first and end with the one now falls in")
  func daysEndToday() throws {
    let utc = Self.calendar("UTC")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-01-10T15:00:00Z"))
    let days = MessageFlow.days(endingAt: now, count: 3, calendar: utc)
    #expect(days.count == 3)
    #expect(days.last?.start == ISO8601DateFormatter().date(from: "2026-01-10T00:00:00Z"))
    #expect(days.first?.start == ISO8601DateFormatter().date(from: "2026-01-08T00:00:00Z"))
    // Contiguous: each day ends where the next begins, so nothing falls between them.
    for (earlier, later) in zip(days, days.dropFirst()) {
      #expect(earlier.end == later.start)
    }
  }

  @Test("A day with a clock change is 23 hours long, and carries its own offset")
  func daylightSavingDay() throws {
    // New York springs forward on 8 March 2026.
    let newYork = Self.calendar("America/New_York")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-09T17:00:00Z"))
    let days = MessageFlow.days(endingAt: now, count: 2, calendar: newYork)
    let change = try #require(days.first)
    #expect(change.end.timeIntervalSince(change.start) == 23 * 3_600)
    #expect(change.utcOffset == -5 * 3_600)
    #expect(days.last?.utcOffset == -4 * 3_600)
  }

  @Test("Cells fold into sent, received, service and the weekday heatmap")
  func aggregates() throws {
    let utc = Self.calendar("UTC")
    // 2026-01-10 is a Saturday: weekday 6 counting Sunday as 0.
    let now = try #require(ISO8601DateFormatter().date(from: "2026-01-10T15:00:00Z"))
    let days = MessageFlow.days(endingAt: now, count: 2, calendar: utc)
    let flow = MessageFlow.aggregate(
      [
        .init(day: 1, hour: 9, isFromMe: true, service: "iMessage", count: 4),
        .init(day: 1, hour: 9, isFromMe: false, service: "SMS", count: 2),
        .init(day: 0, hour: 23, isFromMe: false, service: "", count: 1),
        // Out of range: a stray index must not trap or land anywhere.
        .init(day: 7, hour: 1, isFromMe: false, service: "iMessage", count: 50),
      ],
      days: days, calendar: utc)

    #expect(flow.days.map(\.total) == [1, 6])
    #expect(flow.sent == 4)
    #expect(flow.received == 3)
    #expect(flow.byService == ["iMessage": 4, "SMS": 2, "": 1])
    #expect(flow.heatmap[6][9] == 6)
    #expect(flow.heatmap[5][23] == 1)
    #expect(flow.heatmap.joined().reduce(0, +) == 7)
  }

  @Test("A day nothing happened on is still a day")
  func emptyDaysArePresent() throws {
    let utc = Self.calendar("UTC")
    let days = MessageFlow.days(endingAt: .now, count: 7, calendar: utc)
    let flow = MessageFlow.aggregate([], days: days, calendar: utc)
    #expect(flow.days.count == 7)
    #expect(flow.total == 0)
  }
}

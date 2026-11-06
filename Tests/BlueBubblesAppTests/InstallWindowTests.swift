//  InstallWindowTests
//  When an automatic update may relaunch the app.
//
//  The arithmetic is the whole feature: the wrong day means an update that waits a week,
//  the wrong quiet test means a scheduled message lost in a relaunch. Both are checked on a
//  pinned calendar so the machine's time zone and the hour the test runs at play no part.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Install window")
struct InstallWindowTests {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
  }

  @Test("Before the hour today, the opening is today at the top of that hour")
  func laterToday() {
    let opening = InstallWindow.nextOpening(hour: 3, after: date(11, 1, 30), calendar: calendar)
    #expect(opening == date(11, 3))
  }

  @Test("After the hour today, the opening is tomorrow")
  func tomorrow() {
    let opening = InstallWindow.nextOpening(hour: 3, after: date(11, 14, 0), calendar: calendar)
    #expect(opening == date(12, 3))
  }

  @Test("Inside the hour already, the opening is now: a 03:20 download does not wait a day")
  func insideTheHourIsNow() {
    let now = date(11, 3, 20)
    #expect(InstallWindow.nextOpening(hour: 3, after: now, calendar: calendar) == now)
  }

  @Test("An out-of-range hour is clamped rather than trusted")
  func clamped() {
    let opening = InstallWindow.nextOpening(hour: 99, after: date(11, 1), calendar: calendar)
    #expect(calendar.component(.hour, from: opening) == 23)
    let negative = InstallWindow.nextOpening(hour: -5, after: date(11, 1), calendar: calendar)
    #expect(calendar.component(.hour, from: negative) == 0)
  }

  @Test("Quiet means nothing due within the margin, and overdue counts as due")
  func quiet() {
    let now = date(11, 3)
    #expect(InstallWindow.isQuiet(scheduled: [], now: now))
    #expect(InstallWindow.isQuiet(scheduled: [date(11, 9)], now: now))
    #expect(!InstallWindow.isQuiet(scheduled: [date(11, 3, 10)], now: now))
    // Overdue: the dispatcher's next tick would send it, and a relaunch would sit on top.
    #expect(!InstallWindow.isQuiet(scheduled: [date(11, 2, 50)], now: now))
    // Exactly on the margin is still too close.
    #expect(!InstallWindow.isQuiet(scheduled: [date(11, 3, 15)], now: now))
    #expect(InstallWindow.isQuiet(scheduled: [date(11, 3, 16)], now: now))
  }
}

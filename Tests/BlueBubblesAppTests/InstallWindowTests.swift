//  InstallWindowTests
//  Whether a scheduled update may relaunch the app at this moment.
//
//  The wrong quiet test means a scheduled message lost in a relaunch. Checked on a pinned
//  calendar so the machine's time zone and the hour the test runs at play no part. Which
//  window the relaunch waits for is `InstallScheduleTests`, in `BBUpdatesTests`.

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

//  InstallScheduleTests
//  When a downloaded update may relaunch the server.
//
//  The arithmetic is the whole feature: the wrong day means an update that waits a week, a
//  window that ignores midnight means an overnight install that happens at noon. Checked on
//  a pinned calendar so the machine's time zone and the hour the test runs at play no part.

import BBCore
import Foundation
import Testing

@testable import BBUpdates

@Suite("Install schedule")
struct InstallScheduleTests {

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
  }

  private func span(_ start: Date, _ end: Date) -> DateInterval {
    DateInterval(start: start, end: end)
  }

  private func window(_ hours: DailyInstallHours, at now: Date) -> DateInterval {
    hours.window(containingOrAfter: now, calendar: calendar)
  }

  // MARK: Daily hours

  @Test("Before the window today, the next one opens today")
  func laterToday() {
    let hours = DailyInstallHours(startHour: 3, endHour: 6)
    #expect(window(hours, at: date(11, 1, 30)) == span(date(11, 3), date(11, 6)))
  }

  @Test("After the window today, the next one opens tomorrow")
  func tomorrow() {
    let hours = DailyInstallHours(startHour: 3, endHour: 6)
    #expect(window(hours, at: date(11, 14)) == span(date(12, 3), date(12, 6)))
    // The end is exclusive: at 06:00 the window has closed.
    #expect(window(hours, at: date(11, 6)) == span(date(12, 3), date(12, 6)))
  }

  @Test("Inside the window already, it is this window: a 04:20 download does not wait a day")
  func insideIsThisWindow() {
    let hours = DailyInstallHours(startHour: 3, endHour: 6)
    #expect(window(hours, at: date(11, 4, 20)) == span(date(11, 3), date(11, 6)))
  }

  @Test("A window that runs past midnight is found from either side of it")
  func overnight() {
    let hours = DailyInstallHours(startHour: 22, endHour: 5)
    #expect(hours.lengthInHours == 7)
    // 01:00 is inside the window that opened at 22:00 the evening before.
    #expect(window(hours, at: date(11, 1)) == span(date(10, 22), date(11, 5)))
    // 23:00 is inside tonight's.
    #expect(window(hours, at: date(11, 23)) == span(date(11, 22), date(12, 5)))
    // Noon waits for tonight.
    #expect(window(hours, at: date(11, 12)) == span(date(11, 22), date(12, 5)))
  }

  @Test("Equal hours are the single hour starting there, which is what one hour meant")
  func equalHoursAreOneHour() {
    let hours = DailyInstallHours(startHour: 3, endHour: 3)
    #expect(hours.lengthInHours == 1)
    #expect(window(hours, at: date(11, 3, 20)) == span(date(11, 3), date(11, 4)))
  }

  @Test("Out-of-range hours are clamped rather than trusted")
  func clamped() {
    let hours = DailyInstallHours(startHour: 99, endHour: -5)
    #expect(hours.startHour == 23)
    #expect(hours.endHour == 0)
    #expect(hours.lengthInHours == 1)
  }

  // MARK: A requested window

  @Test("A requested window is itself until it closes")
  func requestedWindowHolds() {
    let asked = span(date(12, 2), date(12, 4, 30))
    let schedule = InstallSchedule.requested(asked)
    #expect(schedule.window(containingOrAfter: date(11, 15), calendar: calendar) == asked)
    #expect(schedule.window(containingOrAfter: date(12, 3), calendar: calendar) == asked)
    #expect(schedule.origin == .requested)
  }

  /// The Mac slept through the window, or a scheduled message held the relaunch to its end.
  /// The next night at the same times, not at once: the hours were chosen to be off-hours.
  @Test("A requested window that closed comes round again the next day at the same times")
  func requestedWindowRolls() {
    let asked = span(date(12, 2), date(12, 4, 30))
    let schedule = InstallSchedule.requested(asked)
    #expect(
      schedule.window(containingOrAfter: date(12, 9), calendar: calendar)
        == span(date(13, 2), date(13, 4, 30)))
    #expect(
      schedule.window(containingOrAfter: date(15, 9), calendar: calendar)
        == span(date(16, 2), date(16, 4, 30)))
  }

  @Test("The automatic schedule reports itself as automatic")
  func dailyOrigin() {
    #expect(InstallSchedule.daily(.init(startHour: 3, endHour: 6)).origin == .automatic)
  }

  // MARK: What a client is shown

  @Test("A scheduled install carries its window and who asked, in epoch milliseconds")
  func scheduledJSON() {
    let window = DateInterval(
      start: Date(timeIntervalSince1970: 1_800_000_000),
      end: Date(timeIntervalSince1970: 1_800_010_800))
    let state = UpdateInstallState.scheduled(version: "1.4.0", window: window, origin: .requested)
    let object = state.json
    #expect(object["state"] == .string("scheduled"))
    #expect(object["version"] == .string("1.4.0"))
    #expect(object["scheduled_for"] == .int64(1_800_000_000_000))
    #expect(object["scheduled_until"] == .int64(1_800_010_800_000))
    #expect(object["scheduled_by"] == .string("client"))

    let automatic = UpdateInstallState.scheduled(
      version: "1.4.0", window: window, origin: .automatic)
    #expect(automatic.json["scheduled_by"] == .string("automatic"))
  }
}

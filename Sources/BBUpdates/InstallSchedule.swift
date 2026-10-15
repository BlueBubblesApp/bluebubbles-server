//  InstallSchedule
//  When a downloaded update may relaunch the server: inside the hours Install Updates
//  Automatically names, every day, or inside one window a client asked for.
//
//  Here rather than in the app because two sides need the same answer. The app waits for the
//  window and relaunches in it; the API tells a client when that will be. Computed in two
//  places, the client is shown one window and the relaunch happens in another.
//
//  Pure, and parameterised on the calendar and `now`, so the arithmetic can be checked
//  without Sparkle, a bundle, or waiting until 3am.

import Foundation

/// A span of wall-clock hours, every day, in this Mac's time zone.
///
/// The end is exclusive and may be earlier than the start: 22 to 5 is an overnight window
/// of seven hours. Equal hours mean the single hour starting there, which is what the one
/// hour setting meant before the window had an end.
public struct DailyInstallHours: Sendable, Equatable {
  public let startHour: Int
  public let endHour: Int

  /// Hours outside 0 to 23 are clamped rather than trusted: the setting's range is enforced
  /// on writes, and this is the last line between a bad value and a relaunch at noon.
  public init(startHour: Int, endHour: Int) {
    self.startHour = Self.clamped(startHour)
    self.endHour = Self.clamped(endHour)
  }

  /// How many hours each window lasts, 1 to 23.
  public var lengthInHours: Int {
    let span = (endHour - startHour + 24) % 24
    return span == 0 ? 1 : span
  }

  /// The window `now` is inside, or the next one to open.
  ///
  /// "Inside" rather than "at the top of it": a download that lands at 03:20 inside a 3 to
  /// 6 window installs now, not tomorrow. And the window that opened YESTERDAY counts when it
  /// runs past midnight, so 01:00 is inside 22 to 5.
  public func window(containingOrAfter now: Date, calendar: Calendar = .current) -> DateInterval {
    let today =
      calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: now) ?? now
    let latestOpening = today <= now ? today : Self.day(-1, from: today, calendar: calendar)
    let latest = window(openingAt: latestOpening, calendar: calendar)
    if now < latest.end { return latest }
    let nextOpening = today > now ? today : Self.day(1, from: today, calendar: calendar)
    return window(openingAt: nextOpening, calendar: calendar)
  }

  private func window(openingAt opening: Date, calendar: Calendar) -> DateInterval {
    let end =
      calendar.date(byAdding: .hour, value: lengthInHours, to: opening)
      ?? opening.addingTimeInterval(TimeInterval(lengthInHours) * 3_600)
    return DateInterval(start: opening, end: end)
  }

  private static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: offset, to: date)
      ?? date.addingTimeInterval(TimeInterval(offset) * 86_400)
  }

  private static func clamped(_ hour: Int) -> Int { min(max(hour, 0), 23) }
}

/// Who decided when a downloaded update relaunches the server.
///
/// Reported to clients, because the two are withdrawn differently: a client's request is
/// cancelled through the API, and the automatic schedule is a setting on the Mac.
public enum InstallScheduleOrigin: Sendable, Equatable {
  /// Install Updates Automatically, inside its daily hours.
  case automatic
  /// A client asked for this update to install inside a window it chose.
  case requested

  /// The wire value, `scheduled_by` on the install state. A contract from the day a client
  /// reads it, so it does not follow a rename of the case.
  public var wireValue: String {
    switch self {
    case .automatic: "automatic"
    case .requested: "client"
    }
  }
}

/// Which window holds a downloaded update's relaunch.
public enum InstallSchedule: Sendable, Equatable {
  case daily(DailyInstallHours)
  case requested(DateInterval)

  public var origin: InstallScheduleOrigin {
    switch self {
    case .daily: .automatic
    case .requested: .requested
    }
  }

  /// The window `now` is inside, or the next one to open.
  ///
  /// A requested window that closed without the install (the Mac slept through it, or a
  /// scheduled message held the relaunch to its end) comes round again the next day at the
  /// same times, the way an operating system's "Install Tonight" tries the next night. Not
  /// "install at once": somebody chose those hours because the server is in use outside
  /// them.
  public func window(containingOrAfter now: Date, calendar: Calendar = .current) -> DateInterval {
    switch self {
    case .daily(let hours):
      return hours.window(containingOrAfter: now, calendar: calendar)
    case .requested(let window):
      var current = window
      var days = 0
      // Bounded: a Mac switched off for a year is not worth an unbounded loop, and a window
      // still in the past after it simply opens at once.
      while current.end <= now, days < 366 {
        days += 1
        let start = Self.day(days, from: window.start, calendar: calendar)
        let end = Self.day(days, from: window.end, calendar: calendar)
        current = DateInterval(start: start, duration: max(0, end.timeIntervalSince(start)))
      }
      return current
    }
  }

  private static func day(_ offset: Int, from date: Date, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: offset, to: date)
      ?? date.addingTimeInterval(TimeInterval(offset) * 86_400)
  }
}

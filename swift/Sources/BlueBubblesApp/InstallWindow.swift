//  InstallWindow
//  When an automatically downloaded update may relaunch the app.
//
//  Sparkle installs a background download when the app quits, or nags after about a week.
//  A server that runs all day never quits, so "install automatically" would mean "install
//  next week" and a nag window on a Mac nobody is looking at. Instead `SparkleUpdater`
//  takes the install handler and calls it at the hour `auto_install_hour` names, provided
//  nothing is about to go out.
//
//  Pure functions, off the updater, so the calendar arithmetic and the quiet test can be
//  checked without Sparkle, a bundle, or waiting until 3am.

import Foundation

enum InstallWindow {

  /// How close a scheduled message may be before the relaunch waits. A relaunch takes
  /// seconds, but a scheduled message that lands in those seconds is lost until the next
  /// tick, and the person who scheduled it does not know why it was late.
  static let quietMargin: TimeInterval = 15 * 60

  /// How long to wait before looking again when the window arrived and it was not quiet.
  static let retryInterval: TimeInterval = 15 * 60

  /// The next moment the wall clock is inside the hour, or `now` if it already is.
  ///
  /// "Inside the hour" rather than "at the top of it": a download that finishes at 03:20
  /// with the hour set to 3 should install now, not tomorrow, and the difference between
  /// installing at 03:00 and at 03:20 is nothing to anyone.
  static func nextOpening(hour: Int, after now: Date, calendar: Calendar = .current) -> Date {
    let clamped = min(max(hour, 0), 23)
    if calendar.component(.hour, from: now) == clamped { return now }
    return calendar.nextDate(
      after: now,
      matching: DateComponents(hour: clamped, minute: 0, second: 0),
      matchingPolicy: .nextTime
    ) ?? now.addingTimeInterval(24 * 60 * 60)
  }

  /// Whether nothing is due soon enough to be disturbed by a relaunch.
  ///
  /// A message already overdue counts as due: the dispatcher will pick it up on its next
  /// tick, and a relaunch in between is exactly the disturbance this avoids.
  static func isQuiet(scheduled: [Date], now: Date, margin: TimeInterval = quietMargin) -> Bool {
    !scheduled.contains { $0 <= now.addingTimeInterval(margin) }
  }
}

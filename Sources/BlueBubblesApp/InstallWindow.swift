//  InstallWindow
//  Whether a scheduled update may relaunch the app right now.
//
//  Sparkle installs a background download when the app quits, or nags after about a week.
//  A server that runs all day never quits, so "install automatically" would mean "install
//  next week" and a nag window on a Mac nobody is looking at. Instead `SparkleUpdater`
//  takes the install handler and calls it inside a window (the automatic hours, or one a
//  client chose), provided nothing is about to go out. Which window is
//  `InstallSchedule`'s decision, in `BBUpdates`, because the API reports it too; whether
//  this moment inside it is quiet is this file's.
//
//  Pure functions, off the updater, so the quiet test can be checked without Sparkle, a
//  bundle, or a scheduled message.

import Foundation

enum InstallWindow {

  /// How close a scheduled message may be before the relaunch waits. A relaunch takes
  /// seconds, but a scheduled message that lands in those seconds is lost until the next
  /// tick, and the person who scheduled it does not know why it was late.
  static let quietMargin: TimeInterval = 15 * 60

  /// How long to wait before looking again when the window arrived and it was not quiet.
  /// Never past the window's end: `SparkleUpdater` wakes at the close instead, and the next
  /// window takes over.
  static let retryInterval: TimeInterval = 15 * 60

  /// Whether nothing is due soon enough to be disturbed by a relaunch.
  ///
  /// A message already overdue counts as due: the dispatcher will pick it up on its next
  /// tick, and a relaunch in between is exactly the disturbance this avoids.
  static func isQuiet(scheduled: [Date], now: Date, margin: TimeInterval = quietMargin) -> Bool {
    !scheduled.contains { $0 <= now.addingTimeInterval(margin) }
  }
}

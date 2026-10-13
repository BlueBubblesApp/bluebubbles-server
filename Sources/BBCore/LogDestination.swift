//  LogDestination
//  Where the server's log file lives.
//
//  In BBCore rather than beside the logging stack because two processes need the path and only
//  one of them has a logger. `BlueBubblesLauncher` depends on BBCore alone — deliberately, it
//  is an AppKit shim with no logging stack — and it has exactly one line to write: the notice
//  saying it has stopped relaunching a server that keeps dying. That line used to go to
//  `NSLog`, which reaches the unified system log and NOT this file, so the log bundle a user
//  emails in ended abruptly with no explanation of why the server never came back.
//
//  A second copy of the path in the launcher would have been the obvious way to do it, and
//  would drift the first time either moved.

import Foundation

public enum LogDestination: Sendable {
  /// The path the Electron server writes to. Unchanged deliberately.
  public static var fileURL: URL {
    URL(fileURLWithPath: ApplicationSupport.realHomeDirectory)
      .appendingPathComponent("Library/Logs/bluebubbles-server/main.log")
  }
}

/// How one line of that file is written:
///
///     [2026-08-27 06:45:32.123][info][HTTPService] Listening on port 1234
///
/// Here for the same reason the path is: two processes write the file and only one has a
/// logging stack. A second copy of the format in the launcher drifts the same way a second
/// copy of the path would, and the copy that existed had: it rendered the timestamp in the
/// user's locale and calendar, so on a Mac set to a Buddhist or Japanese calendar its one
/// line carried a different year from every line around it.
public enum LogLineFormat {

  /// One line, without its newline. `level` and `label` are written as given.
  public static func line(
    level: String, label: String, message: String, at date: Date = Date()
  ) -> String {
    "[\(formatter.string(from: date))][\(level)][\(label)] \(message)"
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    // POSIX locale, pinned calendar, and the local time zone stated rather than inherited.
    //
    // A `dateFormat` with the user's locale left in place is not the fixed format it looks
    // like: `yyyy` renders the era year under a Japanese or Buddhist calendar region, and
    // `HH` can follow a twelve-hour preference. A log line is the artefact people paste
    // into an issue and the format is documented as stable, so it has to be stable
    // everywhere rather than on the machines that happen to be in `en_US`.
    //
    // The time zone stays LOCAL on purpose: somebody reading their own log is matching it
    // against when they saw the problem, not against UTC.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()
}

//  LogDestination
//  Where the server's log file lives, and how one line of it is written.
//
//  In BBCore rather than beside the logging stack so that anything which has to write a line
//  without that stack (a process with no logger bootstrapped yet, a tool) writes it to the
//  same file in the same format. A second copy of either drifts the first time one moves.

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
/// Here for the same reason the path is. The timestamp is fixed to the Gregorian calendar and
/// a POSIX locale: rendered in the user's, a line written on a Mac set to a Buddhist or
/// Japanese calendar carries a different year from every line around it.
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

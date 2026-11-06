//  ISO8601Timestamp
//  `2026-08-30T16:24:00.000Z`: UTC, milliseconds, `Z`, in one place.
//
//  The format `JSON.stringify(new Date())` writes, which v1 responses carry for entity dates
//  (`WireDate`) and audit records carry for every timestamp (`AuditTimestamp`). Two copies of
//  the formatter existed; this is the one.
//
//  Built per call rather than held in a `static let`: `ISO8601DateFormatter` is not
//  `Sendable`, and a shared mutable one is the classic date-formatting data race. UTC and the
//  option set are explicit: a formatter that takes its timezone from the host writes a
//  different string on a Mac set to another region.

import Foundation

public enum ISO8601Timestamp {

  public static func string(from date: Date) -> String {
    formatter(fractional: true).string(from: date)
  }

  /// Reads one back, with or without the fractional seconds: a date stored at second
  /// granularity is written without them by some producers.
  public static func date(from string: String) -> Date? {
    formatter(fractional: true).date(from: string)
      ?? formatter(fractional: false).date(from: string)
  }

  private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }
}

//  AuditRetention
//  How long records are kept, and when the sweep runs.
//
//  A number of days, where zero means forever. Forever is a real policy rather than an
//  oversight: a site that forwards every record to a SIEM may want the local copy bounded,
//  and a site with no SIEM may be keeping the local copy BECAUSE it is the record, so the
//  choice is the operator's. The default is ninety days, which holds a quarter's worth on a
//  busy server without the table becoming the largest thing in `app.db`.
//
//  The sweep runs when the audit log starts and once a day after that. A record is kept for
//  at least its full retention: the cutoff is computed from the day count exactly, and the
//  sweep can only ever run late.

import Foundation

public struct AuditRetentionPolicy: Sendable, Hashable {

  public static let defaultDays = 90
  /// Ten years. A number field needs a ceiling, and beyond this "forever" is the honest
  /// answer.
  public static let maximumDays = 3650
  /// Daily. The window is measured in days, so anything finer buys nothing.
  public static let sweepInterval: Duration = .seconds(24 * 60 * 60)

  /// Days to keep a record. Zero keeps every record.
  public let days: Int

  public init(days: Int) {
    self.days = min(max(days, 0), Self.maximumDays)
  }

  public static let `default` = AuditRetentionPolicy(days: defaultDays)

  /// The policy a stored field value names. Empty or unreadable is the default, so an install
  /// that never touched the field keeps ninety days rather than nothing or everything.
  public static func parse(_ stored: String?) -> AuditRetentionPolicy {
    guard let stored, let days = Int(stored.trimmingCharacters(in: .whitespaces)) else {
      return .default
    }
    return AuditRetentionPolicy(days: days)
  }

  public var keepsForever: Bool { days == 0 }

  /// Records that occurred before this are removed. Nil when nothing is ever removed.
  public func cutoff(now: Date) -> Date? {
    guard !keepsForever else { return nil }
    return now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
  }

  /// One line for a settings row or a summary.
  public var summary: String {
    keepsForever ? "kept forever" : "kept for \(days) days"
  }
}

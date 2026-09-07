//  AppleTimestamp
//  Apple's 2001 epoch, with the unit carried in the type.
//
//  This exists because the unit is genuinely inconsistent across the databases we read, and
//  a wrong answer looks like a plausible date rather than an error:
//
//    chat.db, High Sierra and later : nanoseconds since 2001-01-01 UTC
//    chat.db, before High Sierra    : SECONDS since 2001-01-01 UTC
//    Notification Center            : Cocoa seconds since 2001-01-01 UTC
//
//  The current server needs two separate TypeORM transformers for exactly this. Making the
//  unit part of the type means a bare Int never crosses a boundary and the conversion cannot
//  be applied at the wrong scale.
//
//  See `.claude/docs/database.md`.

import Foundation

/// Seconds between the Unix epoch and Apple's 2001 epoch.
public let appleEpochOffset: TimeInterval = 978_307_200

public struct AppleTimestamp: Hashable, Sendable, Comparable {

  public enum Unit: Sendable, Hashable {
    /// chat.db on High Sierra (10.13) and later.
    case nanoseconds
    /// chat.db before High Sierra, and every Cocoa `NSDate`-derived column.
    case seconds

    var perSecond: Double {
      switch self {
      case .nanoseconds: 1_000_000_000
      case .seconds: 1
      }
    }
  }

  /// The value exactly as stored, un-scaled. Kept so a value can be written back or
  /// compared against the database without a lossy round trip.
  public let rawValue: Int64
  public let unit: Unit

  public init(rawValue: Int64, unit: Unit) {
    self.rawValue = rawValue
    self.unit = unit
  }

  /// Zero means "never" in this schema, not 2001-01-01 — an unset `date_read` is 0, and
  /// treating it as a date produces messages apparently read a quarter-century ago.
  public var isUnset: Bool { rawValue == 0 }

  public var date: Date? {
    guard !isUnset else { return nil }
    return Date(timeIntervalSince1970: appleEpochOffset + Double(rawValue) / unit.perSecond)
  }

  /// Epoch milliseconds, the only date representation the client wire format uses.
  /// `nil` when unset, which serializes as JSON null — matching the legacy contract.
  public var epochMilliseconds: Int64? {
    guard let date else { return nil }
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  public static func from(_ date: Date, unit: Unit) -> AppleTimestamp {
    let seconds = date.timeIntervalSince1970 - appleEpochOffset
    return AppleTimestamp(rawValue: Int64(seconds * unit.perSecond), unit: unit)
  }

  /// Comparison is only meaningful within one unit; mixing them is a bug, so it traps in
  /// debug rather than silently comparing a nanosecond count to a second count.
  public static func < (lhs: AppleTimestamp, rhs: AppleTimestamp) -> Bool {
    assert(lhs.unit == rhs.unit, "Comparing AppleTimestamps with different units")
    return lhs.rawValue < rhs.rawValue
  }
}

extension AppleTimestamp {
  /// Decodes a column value, mapping SQL NULL and 0 to the same "unset" state.
  public static func column(_ value: Int64?, unit: Unit) -> AppleTimestamp? {
    guard let value, value != 0 else { return nil }
    return AppleTimestamp(rawValue: value, unit: unit)
  }
}

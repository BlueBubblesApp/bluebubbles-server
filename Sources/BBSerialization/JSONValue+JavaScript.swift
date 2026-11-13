//  JSONValue+JavaScript
//  The two questions the reference asks of a request value in JavaScript's own terms.
//
//  The reference's checks are written as `!payload[key]`, `typeof x === "number"` and
//  `Number.parseInt(x, 10)`, and their answers differ from Swift's `!= nil` and from
//  `intValue` in ways a client can reach: an empty `chatGuid` is missing, an `interval` of
//  `0` is absent rather than out of range, `3600.0` is as much a number as `3600`, and a
//  `limit` of `"25"` is 25. Each was transcribed separately where
//  it was needed, and two transcriptions of the same rule disagree the first time one is
//  corrected.

import BBCore
import Foundation

extension JSONValue {

  /// JavaScript truthiness. `false`, `0`, `NaN`, `""` and `null` are falsy; everything else
  /// is truthy, an empty array or object included.
  public var isTruthy: Bool {
    switch self {
    case .null: false
    case .bool(let value): value
    case .int(let value): value != 0
    case .int64(let value): value != 0
    case .double(let value): value != 0 && !value.isNaN
    case .string(let value): !value.isEmpty
    case .array, .object: true
    }
  }

  /// The value as a `Double` if it is a JSON number, whichever case it was decoded into;
  /// nil for anything else, a numeric STRING included. `typeof x === "number"`.
  ///
  /// `JSONValue` keeps `.int`, `.int64` and `.double` apart, and a client sending `3600`
  /// and one sending `3600.0` mean the same thing: reading only one case is how a valid
  /// request becomes a 400.
  public var numberValue: Double? {
    switch self {
    case .int(let value): Double(value)
    case .int64(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }

  /// `Number.parseInt(x, 10)`: the value as the integer the reference reads out of it, or
  /// nil where that is `NaN` or does not fit an `Int`.
  ///
  /// The reference reads its paging parameters this way, on the message, chat and handle
  /// routes, behind a validator whose `numeric` rule is `Number()` coercion. So `"25"`,
  /// `25.0` and `"25.7"` all pass validation and are read as 25. Reading only an
  /// integer-typed value instead made each of them fall back to the route's default, a 200
  /// with the wrong page on it.
  ///
  /// `parseInt` prints its argument and takes the leading digits, so a fraction is
  /// truncated, a string is a PREFIX parse after leading whitespace and an optional sign
  /// (`"12abc"` is 12), and a number JavaScript prints with an exponent (below 1e-6 or from
  /// 1e21) yields its first digit. A boolean, null or object is `NaN` there and nil here.
  /// An array is nil too, which is the one departure: `parseInt([5], 10)` is 5, through
  /// `String([5])`. A list sent for a number is a client bug, not a spelling of one, and
  /// it falls back to the route's default.
  public var parsedInteger: Int? {
    switch self {
    case .int(let value): return value
    case .int64(let value): return Int(exactly: value)
    case .double(let value):
      guard value.isFinite else { return nil }
      let magnitude = value.magnitude
      if value == 0 || (magnitude >= 1e-6 && magnitude < 1e21) {
        return Int(exactly: value.rounded(.towardZero))
      }
      // JavaScript and Swift both print the shortest round-trip digits in exponent form
      // here (`1e-07`, `2.5e+22`), so the prefix parse sees what `parseInt` sees.
      return Self.parseIntPrefix(value.description)
    case .string(let text): return Self.parseIntPrefix(text)
    case .null, .bool, .array, .object: return nil
    }
  }

  /// `parseInt`'s string rule, radix 10: skip leading whitespace, take one optional sign,
  /// then as many ASCII digits as follow. Nil when there are none.
  private static func parseIntPrefix(_ text: String) -> Int? {
    var rest = Substring(text).drop { $0.isWhitespace || $0 == "\u{FEFF}" }
    var negative = false
    if let sign = rest.first, sign == "-" || sign == "+" {
      negative = sign == "-"
      rest = rest.dropFirst()
    }
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
    return negative ? -magnitude : magnitude
  }
}

extension Optional where Wrapped == JSONValue {

  /// An absent key is `undefined`, which is falsy.
  public var isTruthy: Bool { self?.isTruthy ?? false }
}

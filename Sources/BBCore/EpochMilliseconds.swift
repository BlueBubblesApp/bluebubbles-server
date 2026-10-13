//  EpochMilliseconds
//  A `Date` as the integer milliseconds every date on the wire is sent as.
//
//  `Date` holds a `Double` of seconds, so turning it into whole milliseconds needs a
//  rounding rule, and the rule is visible: a client comparing two timestamps for equality
//  sees a one-millisecond difference as two different moments. So the rule is named at
//  every site rather than implied by which of `Int(…)`, `.rounded()` or `.rounded(.down)`
//  somebody happened to write.
//
//  **The default truncates toward zero**, because that is what the reference does with the
//  dates it serves: `dateUtil.ts` (`electron/packages/server/src/server/databases/imessage/
//  helpers/dateUtil.ts`) builds `new Date(fractionalMilliseconds)`, and the `Date`
//  constructor applies `ToIntegerOrInfinity`, which discards the fraction toward zero.
//  `AppleTimestamp.epochMilliseconds` relies on this.
//
//  **Some routes round to nearest instead, and say so.** That is what those routes have
//  sent, so it is their contract: changing a site's rule changes what a client receives.
//  It is also the right rule for a value that arrived as whole milliseconds and was divided
//  into seconds on the way in (a client's `mutedUntil`, say), which can come back out as
//  1234.9999… and truncate to 1233. Those sites pass `.toNearestOrAwayFromZero`.

import Foundation

extension Date {

  /// Milliseconds since 1970, truncated toward zero, as the reference's dates are.
  public var epochMilliseconds: Int64 {
    epochMilliseconds(rounded: .towardZero)
  }

  /// Milliseconds since 1970 under an explicit rounding rule. See the file header for
  /// which rule a site wants.
  public func epochMilliseconds(rounded rule: FloatingPointRoundingRule) -> Int64 {
    Int64((timeIntervalSince1970 * 1000).rounded(rule))
  }

  /// The moment `milliseconds` after 1970: the other direction, and the one door for it.
  public init(epochMilliseconds milliseconds: Double) {
    self.init(timeIntervalSince1970: milliseconds / 1000)
  }

  /// Epoch milliseconds from a request value, read the way the reference's `numeric` rule
  /// reads one: a number, or a string that parses as one (`Number("1700000000000")`).
  ///
  /// Nil for anything else, and for a value that is not finite. Reading numbers only let
  /// `"after": "1700000000000"` pass validation and then mean nothing: the filter was not
  /// applied and the answer was the newest messages, with a 200.
  public init?(epochMilliseconds value: JSONValue?) {
    let milliseconds: Double?
    switch value {
    case .int(let number)?: milliseconds = Double(number)
    case .int64(let number)?: milliseconds = Double(number)
    case .double(let number)?: milliseconds = number
    case .string(let text)?:
      milliseconds = Double(text.trimmingCharacters(in: .whitespaces))
    default: milliseconds = nil
    }
    guard let milliseconds, milliseconds.isFinite else { return nil }
    self.init(epochMilliseconds: milliseconds)
  }
}

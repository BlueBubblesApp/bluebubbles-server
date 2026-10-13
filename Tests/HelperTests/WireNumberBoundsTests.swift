//  WireNumberBoundsTests
//  Nothing a client can put on the helper wire may trap inside Messages.app.
//
//  This boundary is not like the others. The code on the far side of it runs INSIDE the
//  user's Messages: a trap there is not a 500, it is Messages disappearing, and the crash
//  report names Messages with nothing in it that points at BlueBubbles. So the rule is that
//  a malformed number is `nil` here and an error the server can report, never a conversion
//  that aborts the host.
//
//  `Int(_ :Double)` is a TRAPPING conversion, and this wire carries doubles: the encoder
//  only shortens whole numbers below 2^53, so a large integer in a request body arrives as a
//  `Double` past `Int.max` and used to take the process with it.

import Foundation
import Testing

@testable import BBPrivateAPIContract

@Suite("Wire number bounds")
struct WireNumberBoundsTests {

  // MARK: - intValue

  @Test(
    "A number beyond Int is nil, not a trap",
    arguments: [
      9_223_372_036_854_775_807.0,  // Int.max, which as a Double rounds to Int.max + 1
      1e300,
      -1e300,
      Double.greatestFiniteMagnitude,
    ]
  )
  func outOfRangeIsNil(value: Double) {
    #expect(WireJSON.number(value).intValue == nil)
  }

  @Test("Infinity and NaN are nil, not a trap")
  func nonFiniteIsNil() {
    #expect(WireJSON.number(.infinity).intValue == nil)
    #expect(WireJSON.number(-.infinity).intValue == nil)
    #expect(WireJSON.number(.nan).intValue == nil)
  }

  @Test("An ordinary whole number still reads")
  func wholeNumbersRead() {
    #expect(WireJSON.number(0).intValue == 0)
    #expect(WireJSON.number(42).intValue == 42)
    #expect(WireJSON.number(-7).intValue == -7)
  }

  @Test("A fractional number truncates toward zero, as it always has")
  func fractionsTruncate() {
    // Unchanged behaviour, pinned because the guard is new: a part index of 2.7 was 2
    // before and has to stay 2, or a client that has been rounding its own way sees a
    // different part.
    #expect(WireJSON.number(2.7).intValue == 2)
    #expect(WireJSON.number(-2.7).intValue == -2)
  }

  @Test("The largest exactly-representable values still read")
  func boundaryValues() {
    #expect(WireJSON.number(9_007_199_254_740_991).intValue == 9_007_199_254_740_991)
    #expect(WireJSON.number(-9_007_199_254_740_991).intValue == -9_007_199_254_740_991)
  }

  // MARK: - Formatting ranges

  @Test("A range whose start and length overflow is refused, not a trap")
  func formattingRangeOverflow() {
    // Both guards above it pass: the start is non-negative and the length is positive. It
    // is their SUM that overflows, on a line that used plain addition.
    let ranges = [FormattedRange(start: Int.max, length: 1, styles: [.bold])]
    #expect(throws: TextFormattingError.self) {
      try FormattedRange.validate(ranges, utf16Length: 10)
    }
  }

  @Test("A range past the end is still refused")
  func formattingRangePastEnd() {
    #expect(throws: TextFormattingError.self) {
      try FormattedRange.validate(
        [FormattedRange(start: 5, length: 20, styles: [.bold])], utf16Length: 10
      )
    }
  }

  @Test("A range inside the message is accepted")
  func formattingRangeValid() throws {
    try FormattedRange.validate(
      [FormattedRange(start: 0, length: 5, styles: [.bold])], utf16Length: 10
    )
    try FormattedRange.validate(
      [FormattedRange(start: 5, length: 5, styles: [.bold])], utf16Length: 10
    )
  }
}

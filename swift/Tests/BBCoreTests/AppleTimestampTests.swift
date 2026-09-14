//  AppleTimestampTests
//  Dates out of `chat.db`, where the epoch is Apple's and the unit is not constant.
//
//  Two traps, and both produce a plausible-looking date rather than an error.
//
//  The epoch is 2001-01-01 UTC, not 1970. And the UNIT changed at High Sierra: seconds
//  before, nanoseconds from 10.13 on (`AppleTimestamp.swift`, and `.claude/docs/database.md`
//  § schema profiles, where `SchemaProfile.dateUnit` selects it). Decode a seconds value as
//  nanoseconds and you land near 1970; decode the reverse and you land in the far future.
//  Neither throws, both render, and the number is decades off. That is why the unit is
//  carried in the type instead of inferred at the call site.
//
//  Zero is the schema's "never", not the epoch. Reading it as a date makes every unread
//  message claim it was read on 2001-01-01, and SQL NULL has to decode the same way.
//
//  `epochMilliseconds` is the wire format: a number, never an ISO string, because that is
//  what shipped clients parse. It is part of the compatibility contract.

import Foundation
import Testing

@testable import BBCore

@Suite("AppleTimestamp")
struct AppleTimestampTests {

  /// 2024-06-01 12:00:00 UTC, matching the value the chat.db fixtures are seeded with.
  let referenceDate = Date(timeIntervalSince1970: 1_717_243_200)

  @Test("Nanoseconds round-trip through the 2001 epoch")
  func nanosecondRoundTrip() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    #expect(stamp.rawValue == 738_936_000 * 1_000_000_000)
    let recovered = try! #require(stamp.date)
    #expect(abs(recovered.timeIntervalSince1970 - referenceDate.timeIntervalSince1970) < 0.001)
  }

  /// The pre-High-Sierra scale. Decoding a seconds value as nanoseconds yields 1970-ish;
  /// the reverse yields the far future. Both look like dates, which is why this is typed.
  @Test("Seconds round-trip through the 2001 epoch")
  func secondRoundTrip() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .seconds)
    #expect(stamp.rawValue == 738_936_000)
    let recovered = try! #require(stamp.date)
    #expect(abs(recovered.timeIntervalSince1970 - referenceDate.timeIntervalSince1970) < 0.001)
  }

  @Test("The same instant differs by 10^9 between units")
  func unitsAreNotInterchangeable() {
    let nanos = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    let seconds = AppleTimestamp.from(referenceDate, unit: .seconds)
    #expect(nanos.rawValue == seconds.rawValue * 1_000_000_000)
  }

  /// Zero means "never" in this schema. Reading it as a date makes every unread message
  /// look like it was read on 2001-01-01.
  @Test("Zero is unset, not the epoch")
  func zeroIsUnset() {
    let stamp = AppleTimestamp(rawValue: 0, unit: .nanoseconds)
    #expect(stamp.isUnset)
    #expect(stamp.date == nil)
    #expect(stamp.epochMilliseconds == nil)
  }

  @Test("SQL NULL and 0 both decode to nil")
  func nullAndZeroAgree() {
    #expect(AppleTimestamp.column(nil, unit: .nanoseconds) == nil)
    #expect(AppleTimestamp.column(0, unit: .nanoseconds) == nil)
    #expect(AppleTimestamp.column(1, unit: .nanoseconds) != nil)
  }

  /// The wire format is epoch milliseconds, never ISO strings. Clients parse it as a
  /// number, so this is part of the compatibility contract.
  @Test("Serializes to epoch milliseconds")
  func epochMilliseconds() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    #expect(stamp.epochMilliseconds == 1_717_243_200_000)
  }

  /// The reference truncates; rounding put roughly half of all rows a millisecond ahead of
  /// the same row served by the reference, across all seven date fields. Invisible to the
  /// parity diff, which compares keys and types.
  ///
  /// `dateUtil.ts` builds `new Date(appleEpochMs + raw / multiplier)` and `new Date(number)`
  /// applies `ToIntegerOrInfinity`. Confirmed against node:
  /// `new Date(1788105123.7).getTime()` is `1788105123`.
  @Test("A fractional millisecond is truncated, matching the reference")
  func fractionalMillisecondsTruncate() {
    // Nanoseconds since 2001 that land half a millisecond past a whole one.
    let stamp = AppleTimestamp(rawValue: 787_000_000_700_000, unit: .nanoseconds)
    let milliseconds = stamp.epochMilliseconds
    #expect(
      milliseconds == 979_094_200_000,
      """
      got \(milliseconds.map(String.init) ?? "nil"); rounding gives 979094200001, which is \
      one millisecond later than the reference serves for the same row.
      """)
  }

  @Test("Truncation goes toward zero, so a pre-1970 date agrees too")
  func truncationDirection() {
    // Far enough before 2001 that the epoch milliseconds themselves are NEGATIVE, which is
    // the only place the two modes disagree: a value merely before 2001 still lands after
    // 1970, where truncating toward zero and flooring are the same thing. No such row
    // exists in a chat.db; matching JavaScript exactly costs nothing and removes the
    // question.
    let stamp = AppleTimestamp(rawValue: -978_400_000_000_700_000, unit: .nanoseconds)
    // Measured. `.down` gives -92800001, one lower, because flooring a negative fraction
    // moves away from zero and `ToIntegerOrInfinity` does not.
    #expect(stamp.epochMilliseconds == -92_800_000)
  }
}

//  AuthClockPolicyTests
//  BBAuth reads the time from the clock it was given.
//
//  Lockouts, token lifetimes and enrolment-code expiry are all decisions about time, and each
//  is tested by moving a `ManualClock`. A `Date()` read anywhere in the module is a decision
//  that clock does not reach: the test passes against the clock it moved while the code
//  under it consults the wall. `now: Date = Date()` defaults that no production caller passed
//  were exactly that, beside an injected `BBClock` in the same module. The source tree is
//  scanned, and a hit fails the build.

import BBTestSupport
import Testing

@Suite("BBAuth takes the time from its injected clock")
struct AuthClockPolicyTests {

  @Test("No source file in BBAuth reads the wall clock")
  func noWallClockReads() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources/BBAuth", minimum: 11)
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains("Date()") || line.code.contains("Date.now")
    }
    #expect(
      offences.isEmpty,
      Comment(rawValue: "read `clock.now` from an injected `BBClock` instead:\n" + offences.report))
  }
}

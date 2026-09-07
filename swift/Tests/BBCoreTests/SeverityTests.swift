//  SeverityTests
//  The ordering that decides what the dock badge counts.
//
//  `Severity` is `Comparable`, and the comparison is load-bearing rather than decorative:
//  the badge counts warning and above, so an ordering that put `info` on the wrong side of
//  the threshold would badge the app for every routine notice — the fastest way to teach a
//  user to ignore the badge entirely.
//
//  `allCases.filter { $0 >= .warning }` is asserted against the literal set rather than
//  against a count, so adding a case forces a decision about which side of the threshold it
//  falls on instead of silently landing above it.

import Testing

@testable import BBCore

@Suite("Severity")
struct SeverityTests {
  @Test("Orders from info through critical")
  func ordering() {
    #expect(Severity.info < Severity.warning)
    #expect(Severity.warning < Severity.error)
    #expect(Severity.error < Severity.critical)
  }

  /// The dock badge counts warning and above, not every info alert.
  @Test("Warning is the badge threshold")
  func badgeThreshold() {
    let badged = Severity.allCases.filter { $0 >= .warning }
    #expect(badged == [.warning, .error, .critical])
  }
}

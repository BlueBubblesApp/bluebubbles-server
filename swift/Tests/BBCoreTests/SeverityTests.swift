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

@Suite("DiagnosticValue redaction")
struct DiagnosticValueTests {
  /// Redaction is structural: a secret cannot be printed by forgetting to handle it,
  /// because there is no payload to print.
  @Test("Secrets never render their value")
  func secretsAreRedacted() {
    #expect(DiagnosticValue.secret.redactedDescription == "••••")
    #expect(DiagnosticValue.string("hunter2").redactedDescription == "hunter2")
  }
}

@Suite("Retry backoff")
struct RetryBackoffTests {

  @Test("A sub-second base delay is not truncated to zero")
  func subSecondBaseSurvives() {
    // `components.seconds` is an integer count, so reading the base through it turned
    // `.milliseconds(500)` into a ZERO delay — a supervised service with a sub-second
    // policy retried in a tight loop instead of backing off, which is the exact failure
    // backoff exists to prevent, and it burned CPU while looking like it was working.
    let policy = RetryPolicy(initialDelay: .milliseconds(500), maxDelay: .seconds(60))
    #expect(policy.delay(forAttempt: 2) == .milliseconds(500))
    #expect(policy.delay(forAttempt: 3) == .seconds(1))
    #expect(policy.delay(forAttempt: 4) == .seconds(2))
  }

  @Test("Fractional bounds keep their fractional part")
  func fractionalDelaysAreExact() {
    let policy = RetryPolicy(initialDelay: .milliseconds(1500), maxDelay: .milliseconds(2500))
    #expect(policy.delay(forAttempt: 2) == .milliseconds(1500))
    // Capped at the fractional maximum, not at a truncated 2 seconds.
    #expect(policy.delay(forAttempt: 3) == .milliseconds(2500))
  }

  @Test("The first attempt never waits")
  func firstAttemptIsImmediate() {
    #expect(RetryPolicy(initialDelay: .seconds(30)).delay(forAttempt: 1) == .zero)
  }

  @Test("Growth is exponential and capped")
  func growthIsCapped() {
    let policy = RetryPolicy(
      initialDelay: .seconds(1), maxDelay: .seconds(8), multiplier: 2
    )
    #expect(policy.delay(forAttempt: 2) == .seconds(1))
    #expect(policy.delay(forAttempt: 4) == .seconds(4))
    #expect(policy.delay(forAttempt: 5) == .seconds(8))
    #expect(policy.delay(forAttempt: 20) == .seconds(8))
  }
}

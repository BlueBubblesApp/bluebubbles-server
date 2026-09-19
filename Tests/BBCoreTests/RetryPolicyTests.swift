//  RetryPolicyTests
//  Backoff arithmetic and the retry loop over it.
//
//  These were split across two files (the growth-and-cap cases in `AppleTimestampTests.swift`
//  and the sub-second cases in `SeverityTests.swift`) because neither filename mentioned
//  `RetryPolicy`, so it got tested twice without anyone noticing. Two of the duplicated cases
//  are folded into `backoffGrowsAndCaps` here; nothing was dropped.
//
//  The case that is not obvious from the assertions: `delay(forAttempt:)` used to read its
//  bounds through `Duration.components.seconds`, an INTEGER count, so a `.milliseconds(500)`
//  base truncated to a ZERO delay. A supervised service with a sub-second policy then retried
//  in a tight loop (the exact failure backoff exists to prevent) while its health reported
//  fine and it burned a core. Any change to this arithmetic has to keep the fractional cases,
//  because a `Duration` that reads correctly in whole seconds can still be zero.
//
//  `shouldRetry` returning false gives up at once rather than spending the attempt budget:
//  bad credentials do not become good on the third try.

import Foundation
import Testing

@testable import BBCore

@Suite("RetryPolicy")
struct RetryPolicyTests {

  @Test("Backs off exponentially, capped, and the first attempt never waits")
  func backoffGrowsAndCaps() {
    let policy = RetryPolicy(
      maxAttempts: 10, initialDelay: .seconds(1), maxDelay: .seconds(8), multiplier: 2
    )
    // Attempt 1 is the original call, not a retry, so it waits for nothing.
    #expect(policy.delay(forAttempt: 1) == .zero)
    #expect(policy.delay(forAttempt: 2) == .seconds(1))
    #expect(policy.delay(forAttempt: 3) == .seconds(2))
    #expect(policy.delay(forAttempt: 4) == .seconds(4))
    #expect(policy.delay(forAttempt: 5) == .seconds(8))
    #expect(policy.delay(forAttempt: 9) == .seconds(8))
    // Far past the cap, and past maxAttempts: the delay is pure arithmetic over the
    // bounds and does not consult the attempt budget, so it stays pinned at maxDelay.
    #expect(policy.delay(forAttempt: 20) == .seconds(8))
  }

  @Test("Retries until success")
  func retriesUntilSuccess() async throws {
    actor Counter {
      var value = 0
      func increment() -> Int {
        value += 1
        return value
      }
    }
    let counter = Counter()
    let policy = RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1))

    let result = try await withRetry(policy) {
      let attempt = await counter.increment()
      if attempt < 3 { throw TestError.transient }
      return attempt
    }
    #expect(result == 3)
  }

  /// A non-retryable failure should not burn the attempt budget: bad credentials will
  /// not become good on the third try.
  @Test("shouldRetry false gives up immediately")
  func nonRetryableStopsAtOnce() async {
    actor Counter {
      var value = 0
      func increment() { value += 1 }
      func get() -> Int { value }
    }
    let counter = Counter()
    let policy = RetryPolicy(
      maxAttempts: 5, initialDelay: .milliseconds(1), shouldRetry: { _ in false }
    )

    _ = try? await withRetry(policy) {
      await counter.increment()
      throw TestError.permanent
    }
    #expect(await counter.get() == 1)
  }

  @Test("A sub-second base delay is not truncated to zero")
  func subSecondBaseSurvives() {
    // `components.seconds` is an integer count, so reading the base through it turned
    // `.milliseconds(500)` into a ZERO delay: a supervised service with a sub-second
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
}

/// Raised by the loop tests above to separate a failure worth retrying from one that is not.
enum TestError: Error { case transient, permanent }

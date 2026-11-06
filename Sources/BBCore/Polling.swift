//  Polling
//  Trying something again on a schedule until it produces an answer, or until the schedule or
//  a deadline says to stop.
//
//  `withRetry` covers an operation that THROWS when it fails. Most of what this server retries
//  does not: an FCM delivery returns an outcome to classify, a provisioning poll gets a
//  well-formed "not yet", a write reports `false`. Each of those was a hand-written loop with
//  its own idea of when to check for cancellation, whether the deadline is checked before or
//  after the sleep, and how the delay grows, and none of them could be driven by a test clock.
//  These two functions are that loop, once.

import Foundation

/// The wait before each retry, by how many attempts have failed so far.
public struct RetrySchedule: Sendable {

  private let delayAfter: @Sendable (_ failures: Int) -> Duration?

  /// `delayAfter(n)` is the wait after the `n`th failed attempt (from 1), or nil to give up.
  public init(_ delayAfter: @escaping @Sendable (_ failures: Int) -> Duration?) {
    self.delayAfter = delayAfter
  }

  /// The wait after `failures` failed attempts, or nil when the schedule is spent.
  public func delay(afterFailures failures: Int) -> Duration? {
    delayAfter(failures)
  }

  /// The listed waits in order, then `steady` for ever, or nothing more if it is nil.
  public static func delays(_ delays: [Duration], thenEvery steady: Duration? = nil)
    -> RetrySchedule
  {
    RetrySchedule { failures in
      failures - 1 < delays.count ? delays[failures - 1] : steady
    }
  }

  /// The same wait every time, for at most `attempts` attempts in all when given.
  public static func every(_ interval: Duration, attempts: Int? = nil) -> RetrySchedule {
    RetrySchedule { failures in
      if let attempts, failures >= attempts { return nil }
      return interval
    }
  }

  /// `step` after the first failure, twice that after the second, and so on up to `cap`.
  ///
  /// For a poll whose answer usually comes within a second or two but can take minutes: a
  /// fixed interval long enough for the slow case spends that long on every fast one.
  public static func escalating(by step: Duration, upTo cap: Duration) -> RetrySchedule {
    RetrySchedule { failures in min(cap, step * failures) }
  }

  /// `initial`, then each wait `factor` times the one before, for as long as the waits taken
  /// so far add up to less than `budget`.
  ///
  /// The budget counts waiting, not the attempts between: a caller that wants wall-clock time
  /// passes `within:` as well.
  public static func exponential(from initial: Duration, by factor: Double, budget: Duration)
    -> RetrySchedule
  {
    RetrySchedule { failures in
      var waited = Duration.zero
      var delay = initial
      for _ in 1..<failures {
        waited += delay
        delay = delay * factor
      }
      return waited < budget ? delay : nil
    }
  }
}

/// Calls `attempt` until `isDone` accepts what it returns, waiting per `schedule` between
/// attempts, and returns the last result whether or not it was accepted.
///
/// Stops when `isDone` accepts a result, when the schedule is spent, or when a wait ends past
/// `timeout`. The deadline is checked after each wait, never part-way through an attempt.
///
/// Runs on the caller's actor, so `attempt` may read and write the caller's own state.
///
/// - Parameter previousFailures: Attempts that already failed before this call. The first
///   attempt here then WAITS first, as a retry does, and is numbered `previousFailures + 1`.
/// - Throws: What `attempt` throws, and `CancellationError` if cancelled during a wait.
public func retrying<T, C: Clock<Duration>>(
  _ schedule: RetrySchedule,
  within timeout: Duration? = nil,
  previousFailures: Int = 0,
  clock: C = ContinuousClock(),
  isolation: isolated (any Actor)? = #isolation,
  _ attempt: (_ number: Int) async throws -> T,
  until isDone: (T) -> Bool
) async throws -> T {
  let deadline = timeout.map { clock.now.advanced(by: $0) }
  var failures = previousFailures
  if failures > 0, let delay = schedule.delay(afterFailures: failures) {
    try await clock.sleep(for: delay)
  }
  while true {
    let result = try await attempt(failures + 1)
    if isDone(result) { return result }
    failures += 1
    guard let delay = schedule.delay(afterFailures: failures) else { return result }
    try await clock.sleep(for: delay)
    if let deadline, clock.now >= deadline { return result }
  }
}

/// Calls `attempt` until it returns a value, waiting per `schedule` between attempts.
///
/// Nil when the schedule is spent or `timeout` passes first; the caller says what that means.
///
/// - Throws: What `attempt` throws, and `CancellationError` if cancelled during a wait.
public func poll<T, C: Clock<Duration>>(
  _ schedule: RetrySchedule,
  within timeout: Duration? = nil,
  clock: C = ContinuousClock(),
  isolation: isolated (any Actor)? = #isolation,
  _ attempt: (_ number: Int) async throws -> T?
) async throws -> T? {
  try await retrying(
    schedule, within: timeout, clock: clock, isolation: isolation, attempt, until: { $0 != nil })
}

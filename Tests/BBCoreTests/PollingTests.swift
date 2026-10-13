//  PollingTests
//  The schedule shapes the server's retry loops were rewritten onto, and the loop itself.
//
//  The clock here never waits: a sleep moves its time straight to the deadline and records
//  how long it was asked to wait. So each test asserts the exact sequence of waits a loop
//  would have taken, in no wall-clock time, which is the property the hand-written loops
//  never had.

import BBTestSupport
import Foundation
import Testing

@testable import BBCore

@Suite("Retry schedules")
struct RetryScheduleTests {

  @Test("Listed delays run out, or continue at the steady interval")
  func delays() {
    let finite = RetrySchedule.delays([.seconds(1), .seconds(5)])
    #expect(finite.delay(afterFailures: 1) == .seconds(1))
    #expect(finite.delay(afterFailures: 2) == .seconds(5))
    #expect(finite.delay(afterFailures: 3) == nil)

    let steady = RetrySchedule.delays([.seconds(1)], thenEvery: .seconds(300))
    #expect(steady.delay(afterFailures: 2) == .seconds(300))
    #expect(steady.delay(afterFailures: 50) == .seconds(300))
  }

  @Test("A fixed interval stops after the stated number of attempts")
  func everyWithAttempts() {
    let schedule = RetrySchedule.every(.seconds(5), attempts: 3)
    #expect(schedule.delay(afterFailures: 1) == .seconds(5))
    #expect(schedule.delay(afterFailures: 2) == .seconds(5))
    #expect(schedule.delay(afterFailures: 3) == nil)
    #expect(RetrySchedule.every(.seconds(5)).delay(afterFailures: 1000) == .seconds(5))
  }

  @Test("An exponential schedule grows by its factor until the waits reach the budget")
  func exponential() {
    let schedule = RetrySchedule.exponential(
      from: .milliseconds(250), by: 2, budget: .seconds(1))
    #expect(schedule.delay(afterFailures: 1) == .milliseconds(250))
    #expect(schedule.delay(afterFailures: 2) == .milliseconds(500))
    // 250 + 500 = 750 waited, still under the second.
    #expect(schedule.delay(afterFailures: 3) == .seconds(1))
    // 1750 waited: spent.
    #expect(schedule.delay(afterFailures: 4) == nil)
  }

  @Test("An escalating schedule grows by its step and stops at its cap")
  func escalating() {
    let schedule = RetrySchedule.escalating(by: .milliseconds(500), upTo: .seconds(3))
    #expect(schedule.delay(afterFailures: 1) == .milliseconds(500))
    #expect(schedule.delay(afterFailures: 4) == .seconds(2))
    #expect(schedule.delay(afterFailures: 6) == .seconds(3))
    #expect(schedule.delay(afterFailures: 60) == .seconds(3))
  }
}

@Suite("Polling")
struct PollingTests {

  @Test("A poll returns the first value, having waited per the schedule between attempts")
  func returnsFirstValue() async throws {
    let clock = TestClock(skipsSleeps: true)
    var attempts: [Int] = []
    let value = try await poll(.delays([.seconds(1), .seconds(2), .seconds(4)]), clock: clock) {
      number -> String? in
      attempts.append(number)
      return number == 3 ? "ready" : nil
    }

    #expect(value == "ready")
    #expect(attempts == [1, 2, 3])
    #expect(clock.waits == [.seconds(1), .seconds(2)])
  }

  @Test("A poll whose schedule runs out returns nil after the last attempt")
  func spentScheduleIsNil() async throws {
    let clock = TestClock(skipsSleeps: true)
    var attempts = 0
    let value: Int? = try await poll(.every(.seconds(5), attempts: 3), clock: clock) { _ in
      attempts += 1
      return nil
    }

    #expect(value == nil)
    #expect(attempts == 3)
    #expect(clock.waits == [.seconds(5), .seconds(5)])
  }

  @Test("A poll stops at its deadline, checked after each wait")
  func deadlineStops() async throws {
    let clock = TestClock(skipsSleeps: true)
    var attempts = 0
    let value: Int? = try await poll(.every(.seconds(5)), within: .seconds(12), clock: clock) {
      _ in
      attempts += 1
      return nil
    }

    // Attempts at 0, 5 and 10 seconds; the wait to 15 ends past the deadline.
    #expect(value == nil)
    #expect(attempts == 3)
  }

  @Test("An attempt's error ends the poll at once")
  func errorPropagates() async {
    struct Refused: Error {}
    let clock = TestClock(skipsSleeps: true)
    await #expect(throws: Refused.self) {
      _ = try await poll(.every(.seconds(1)), clock: clock) { _ -> Int? in throw Refused() }
    }
    #expect(clock.waits.isEmpty)
  }

  @Test("A retry after an earlier failure waits before its first attempt")
  func previousFailuresWaitFirst() async throws {
    let clock = TestClock(skipsSleeps: true)
    var numbers: [Int] = []
    let landed = try await retrying(
      .delays([.seconds(5), .seconds(15)], thenEvery: .seconds(300)), previousFailures: 1,
      clock: clock
    ) { number in
      numbers.append(number)
      return number == 3
    } until: {
      $0
    }

    #expect(landed)
    #expect(numbers == [2, 3])
    #expect(clock.waits == [.seconds(5), .seconds(15)])
  }

  @Test("retrying returns the last result when nothing was accepted")
  func lastResultWhenSpent() async throws {
    let clock = TestClock(skipsSleeps: true)
    let result = try await retrying(.delays([.seconds(1)]), clock: clock) { number in
      number
    } until: {
      $0 > 10
    }
    #expect(result == 2)
  }

  @Test("Cancellation during a wait throws")
  func cancellationThrows() async {
    let clock = TestClock(skipsSleeps: true)
    let task = Task {
      try await poll(.every(.seconds(1)), clock: clock) { _ -> Int? in
        withUnsafeCurrentTask { $0?.cancel() }
        return nil
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

//  OwnedTaskTests
//  What a service relies on when it holds its loop in an `OwnedTask`.
//
//  The property that matters most is the one a bare `Task?` cannot give: a body that returns
//  on its own clears the handle, so `isRunning` (which every `isAlive` reads) turns false and
//  the registry revives the service. The rest pins the two lines it replaced at every holder:
//  cancel on replace, and cancel on stop. Every wait is bounded, so a regression fails with a
//  name on it instead of hanging the run.

import BBTestSupport
import Foundation
import Testing

@testable import BBCore

@Suite("OwnedTask")
struct OwnedTaskTests {

  @Test("A body that returns on its own clears the handle and reports it")
  func endingOnItsOwnIsReported() async throws {
    let owned = OwnedTask()
    let (ended, endedSignal) = AsyncStream<Void>.makeStream()
    owned.run {
      // Returns at once, as a pump whose stream finished does.
    } ifItEndsOnItsOwn: {
      endedSignal.yield()
    }

    try await withTimeout(.seconds(5)) {
      for await _ in ended { return }
    }
    #expect(!owned.isRunning)
  }

  @Test("A cancelled body is not reported as having ended on its own")
  func cancellingIsNotReported() async throws {
    let owned = OwnedTask()
    let reported = Flag()
    let (finished, finishedSignal) = AsyncStream<Void>.makeStream()
    owned.run {
      await sleepUntilCancelled()
      finishedSignal.yield()
    } ifItEndsOnItsOwn: {
      reported.set()
    }
    #expect(owned.isRunning)

    owned.cancel()
    #expect(!owned.isRunning)
    try await withTimeout(.seconds(5)) {
      for await _ in finished { return }
    }
    // The report would run after the body returned; give it the chance to.
    await Task.yield()
    #expect(!reported.value)
  }

  @Test("Running again cancels the body that was running")
  func replacingCancelsThePrevious() async throws {
    let owned = OwnedTask()
    let (first, firstSignal) = AsyncStream<Void>.makeStream()
    owned.run {
      await sleepUntilCancelled()
      firstSignal.yield()
    }
    owned.run { await sleepUntilCancelled() }

    try await withTimeout(.seconds(5)) {
      for await _ in first { return }
    }
    // The replacement is unaffected by the first body returning.
    #expect(owned.isRunning)
    owned.cancel()
  }

  @Test("Releasing the owner cancels the body")
  func releasingCancels() async throws {
    let (cancelled, cancelledSignal) = AsyncStream<Void>.makeStream()
    do {
      let owned = OwnedTask()
      owned.run {
        await sleepUntilCancelled()
        cancelledSignal.yield()
      }
    }

    try await withTimeout(.seconds(5)) {
      for await _ in cancelled { return }
    }
  }

  @Test("stop returns only after the body has")
  func stopWaits() async {
    let owned = OwnedTask()
    let finished = Flag()
    owned.run {
      await sleepUntilCancelled()
      finished.set()
    }

    await owned.stop()
    #expect(finished.value)
    #expect(!owned.isRunning)
  }

  @Test("A periodic body runs at once, then once per interval, until cancelled")
  func periodicFollowsTheClock() async throws {
    let clock = TestClock()
    let runs = Counter()
    let loop = Task {
      await runPeriodically(every: .seconds(10), after: .zero, clock: clock) { runs.increment() }
    }

    try await clock.waitForSleepers(1)
    #expect(runs.value == 1)

    clock.advance(by: .seconds(9))
    #expect(runs.value == 1)
    clock.advance(by: .seconds(1))
    try await clock.waitForSleepers(1)
    #expect(runs.value == 2)

    loop.cancel()
    try await withTimeout(.seconds(5)) { await loop.value }
    #expect(runs.value == 2)
  }

  @Test("A periodic body with an initial delay waits for it first")
  func periodicHonoursTheInitialDelay() async throws {
    let clock = TestClock()
    let runs = Counter()
    let loop = Task {
      await runPeriodically(every: .seconds(10), after: .seconds(30), clock: clock) {
        runs.increment()
      }
    }

    try await clock.waitForSleepers(1)
    #expect(runs.value == 0)
    clock.advance(by: .seconds(30))
    try await clock.waitForSleepers(1)
    #expect(runs.value == 1)

    loop.cancel()
    try await withTimeout(.seconds(5)) { await loop.value }
  }
}

// MARK: - Support

private func sleepUntilCancelled() async {
  while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(60))
  }
}

private final class Flag: Sendable {
  private let state = LockedValue(false)
  var value: Bool { state.read() }
  func set() { state.write(true) }
}

private final class Counter: Sendable {
  private let state = LockedValue(0)
  var value: Int { state.read() }
  func increment() { state.update { $0 += 1 } }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func read() -> Value { lock.withLock { value } }
  func write(_ newValue: Value) { lock.withLock { value = newValue } }
  func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

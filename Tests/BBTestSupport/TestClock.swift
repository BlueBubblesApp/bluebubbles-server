//  TestClock
//  A `Clock<Duration>` a test moves by hand, for code that takes `clock:` and sleeps on it.
//
//  Code under test that sleeps on the wall clock makes its test sleep too: a cadence test
//  waits out the cadence, and a margin generous enough for a loaded machine is wasted on an
//  idle one. Production types that sleep take a `clock:` defaulting to `ContinuousClock()`,
//  as `poll` and `retrying` do, and a test hands them one of these instead.
//
//  Two behaviours, chosen at construction:
//
//  - **Stepped** (the default). A sleep parks until `advance(by:)` moves time past its
//    deadline. `waitForSleepers(_:)` returns once the code under test has reached its next
//    sleep, so an `advance` never races the work it is meant to follow.
//  - **Skipping**. A sleep moves time straight to its deadline and returns at once. For code
//    whose waits are incidental to what the test asserts, such as a retry schedule.
//
//  Either way every requested wait is recorded in `waits`, so a test can assert the schedule
//  a loop actually followed.

import BBCore
import Foundation

/// A clock that moves only when the test says so, or that skips every sleep.
public final class TestClock: Clock, Sendable {

  public struct Instant: InstantProtocol {
    public var offset: Duration
    public init(offset: Duration) { self.offset = offset }
    public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    public func duration(to other: Instant) -> Duration { other.offset - offset }
    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper: Sendable {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State: Sendable {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
    var waits: [Duration] = []
  }

  private let state = Locked(State())
  private let skipsSleeps: Bool

  /// - Parameter skipsSleeps: When true, a sleep returns at once having moved time to its
  ///   deadline. When false, it waits for `advance(by:)`.
  public init(skipsSleeps: Bool = false) {
    self.skipsSleeps = skipsSleeps
  }

  public var now: Instant { state.value.now }
  public var minimumResolution: Duration { .zero }

  /// Every wait asked of this clock, in order, measured from the time it was asked.
  public var waits: [Duration] { state.value.waits }

  /// How many sleeps are parked waiting for time to move.
  public var sleeperCount: Int { state.value.sleepers.count }

  public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    if skipsSleeps {
      state.withLock { state in
        state.waits.append(state.now.duration(to: deadline))
        state.now = max(state.now, deadline)
      }
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        enqueue(Sleeper(id: id, deadline: deadline, continuation: continuation))
      }
    } onCancel: {
      let sleeper = state.withLock { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return state.sleepers.remove(at: index)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  private enum Admission { case parked, due, cancelled }

  private func enqueue(_ sleeper: Sleeper) {
    // Cancellation is read UNDER the lock the cancellation handler also takes: a handler that
    // ran before this sleeper was parked found nothing to cancel, and this read is what
    // catches it. Read before the lock, a cancel landing in between would be lost.
    let admission = state.withLock { state -> Admission in
      state.waits.append(state.now.duration(to: sleeper.deadline))
      if Task.isCancelled { return .cancelled }
      if sleeper.deadline <= state.now { return .due }
      state.sleepers.append(sleeper)
      return .parked
    }
    switch admission {
    case .parked: break
    case .due: sleeper.continuation.resume()
    case .cancelled: sleeper.continuation.resume(throwing: CancellationError())
    }
  }

  /// Moves time forward, waking every sleep whose deadline it reaches.
  public func advance(by duration: Duration) {
    let due = state.withLock { state -> [Sleeper] in
      state.now = state.now.advanced(by: duration)
      let now = state.now
      let due = state.sleepers.filter { $0.deadline <= now }
      state.sleepers.removeAll { $0.deadline <= now }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
  }

  /// Returns once at least `count` sleeps are parked, which is how a test knows the code
  /// under test has finished its work and reached its next wait.
  public func waitForSleepers(
    _ count: Int, timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation
  ) async throws {
    try await waitUntil(
      "\(count) sleeper(s) on the test clock", timeout: timeout, interval: .milliseconds(1),
      isolation: isolation
    ) { sleeperCount >= count }
  }
}

//  Timeout
//  Racing a piece of work against a deadline, once.
//
//  One task group: the work in one child, a sleep in the other, first one wins. A throwing
//  task-group body cancels and awaits the remaining children on its way out, so the losing
//  sleep never outlives the call even without `cancelAll()`; that is measured rather than
//  assumed, because the opposite is the obvious guess. The `defer` below states the intent
//  locally instead of relying on it.
//
//  Two shapes are genuinely different and stay at their call sites: the permission probe
//  races a `Thread` and answers `.unknown` rather than throwing, and the readiness waits
//  resume a stored continuation that a cancellation handler also has to reach.

import Foundation

/// The work did not finish inside its deadline.
public struct TimedOut: Error, Equatable, Sendable, CustomStringConvertible {
  /// The deadline that passed, when the caller knows it. Absent when a caller throws this
  /// after observing a timeout it measured some other way.
  public let duration: Duration?

  public init(after duration: Duration? = nil) {
    self.duration = duration
  }

  public var description: String {
    guard let duration else { return "the operation timed out" }
    return "the operation did not finish within \(duration.seconds)s"
  }
}

/// Runs `operation`, giving up after `duration`.
///
/// The loser is always cancelled, so nothing outlives the call. Cancellation of the caller
/// propagates into `operation` the way it would without the wrapper.
///
/// **The deadline bounds the WAIT only as far as `operation` observes cancellation.** A task
/// group cancels and then AWAITS its remaining children on the way out, so an operation that
/// ignores cancellation is still waited for in full and the deadline decides only which error
/// comes back. That is the right trade for every caller here: sink delivery and request-body
/// collection are network I/O, which aborts when cancelled, and nothing is left running behind
/// them. It is the wrong one wherever the deadline exists to bound WALL-CLOCK time: an app
/// shutdown deliberately does not abort half-done, and `AppDelegate.stopWithHardDeadline`
/// therefore races its own deadline and abandons the loser rather than using this.
///
/// - Throws: `TimedOut` if the deadline passes first, or whatever `operation` throws.
public func withTimeout<T: Sendable>(
  _ duration: Duration,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimedOut(after: duration)
    }
    defer { group.cancelAll() }
    guard let first = try await group.next() else { throw TimedOut(after: duration) }
    return first
  }
}

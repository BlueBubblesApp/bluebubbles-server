//  Timeout
//  Racing a piece of work against a deadline, once.
//
//  Six places had written this out: the event bus, the HTTP dispatcher, the Private API
//  runtime and its transaction store, the tunnel daemon's readiness wait, and the permission
//  probe. Every copy is the same task group — the work in one child, a sleep in the other,
//  first one wins — differing only in which error came out.
//
//  They were all CORRECT, including the ones that call `cancelAll()` only on the success
//  path: a throwing task-group body cancels and awaits the remaining children on its way
//  out, so the losing sleep never outlives the call. That was measured rather than assumed,
//  because the opposite is the obvious guess. Consolidating is therefore about having one
//  implementation with one test, not about fixing a leak. The `defer` below says the
//  intent locally instead of relying on that group behaviour.
//
//  Two of those six shapes are genuinely different and stay where they are: the permission
//  probe races a `Thread` and answers `.unknown` rather than throwing, and the readiness
//  waits resume a stored continuation that a cancellation handler also has to reach. Both
//  are documented at their call sites.

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

//  Timeout
//  Racing a piece of work against a deadline, once.
//
//  One task group: the work in one child, a sleep in the other, first one wins. A throwing
//  task-group body cancels and awaits the remaining children on its way out, so the losing
//  sleep never outlives the call even without `cancelAll()`; that is measured rather than
//  assumed, because the opposite is the obvious guess. The `defer` below states the intent
//  locally instead of relying on it.
//
//  A wait for something ANOTHER party will resume (a reply, a readiness line, a browser
//  callback) is a second shape, `awaitContinuation`, because cancelling a task suspended on
//  a continuation does not resume it: a task group racing one against a sleep can never
//  finish when the sleep wins. `OnceContinuation` closes that, and the window where the
//  wait is cancelled before the owner has stored it, in one place.
//
//  The permission probe races a `Thread` and answers `.unknown` rather than throwing, which
//  is genuinely different and stays at its call site.

import Foundation
import os

/// The work did not finish inside its deadline.
///
/// **Inside a request this IS the route's 504.** `HTTPServer` answers `catch is TimedOut` with
/// the documented gateway-timeout body, whoever threw it. So a backend that times out on its
/// own (a helper that did not reply, a child process that was killed, a sign-in window left
/// open) keeps a case of its own: thrown as this, a helper timeout would reach a client as a
/// 504 instead of the 500 `iMessage Error` it has always been, and the case's subject (the
/// method, the executable, the tool) would be lost from the sentence a person reads.
public struct TimedOut: BBError, Equatable, CustomStringConvertible {
  /// The deadline that passed, when the caller knows it. Absent when a caller throws this
  /// after observing a timeout it measured some other way.
  public let duration: Duration?

  public init(after duration: Duration? = nil) {
    self.duration = duration
  }

  public var code: String { "timeout" }
  public var domain: String { "Core" }
  public var title: String { "That took too long" }

  public var body: String {
    guard let duration else { return "The operation timed out." }
    return "The operation did not finish within \(Self.spell(duration))."
  }

  public var description: String { body }

  /// "5 seconds", "1 second", "0.25 seconds": whole seconds counted, a fraction as it is.
  static func spell(_ duration: Duration) -> String {
    let seconds = duration.seconds
    guard seconds == seconds.rounded(), seconds < Double(Int.max) else {
      return "\(seconds) seconds"
    }
    return Int(seconds).counted("second")
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

/// A result that is delivered at most once, from any thread, before or after anybody waits.
///
/// The handle an `awaitContinuation` owner stores in place of a raw `CheckedContinuation`.
/// Resuming it twice is ignored rather than a trap, and resuming it before the waiter has
/// attached is held and delivered on attach, so neither ordering can strand a task.
public final class OnceContinuation<Value: Sendable>: Sendable {
  private enum State: Sendable {
    case waiting(CheckedContinuation<Value, any Error>?)
    case resolved(Result<Value, any Error>)
  }

  private let state = OSAllocatedUnfairLock<State>(initialState: .waiting(nil))

  public init() {}

  /// Whether a value or an error has already been delivered. An owner checks this before
  /// storing a handle, so one that timed out on the way in is not kept.
  public var isResolved: Bool {
    state.withLock {
      if case .resolved = $0 { return true }
      return false
    }
  }

  @discardableResult
  public func resume(returning value: Value) -> Bool { resume(with: .success(value)) }

  @discardableResult
  public func resume(throwing error: any Error) -> Bool { resume(with: .failure(error)) }

  /// Delivers `result`. The first call wins; later ones are ignored.
  ///
  /// Returns whether THIS call was the one delivered, so two racers (an answer and a
  /// deadline) can each tell whether they won.
  @discardableResult
  public func resume(with result: Result<Value, any Error>) -> Bool {
    let (won, waiter): (Bool, CheckedContinuation<Value, any Error>?) = state.withLock { state in
      guard case .waiting(let waiter) = state else { return (false, nil) }
      state = .resolved(result)
      return (true, waiter)
    }
    // Resumed outside the lock: a continuation runs the awaiting task, and holding a lock
    // across that invites a deadlock against anything that calls back in here.
    waiter?.resume(with: result)
    return won
  }

  /// Waits for the delivered result, at once if it has already arrived.
  ///
  /// For an owner that is its own waiter, as `awaitContinuation` is not: one waiter only. A
  /// second would replace the first, which would then never be resumed.
  public func value() async throws -> Value {
    try await withCheckedThrowingContinuation { attach($0) }
  }

  fileprivate func attach(_ continuation: CheckedContinuation<Value, any Error>) {
    let delivered: Result<Value, any Error>? = state.withLock { state in
      switch state {
      case .waiting:
        state = .waiting(continuation)
        return nil
      case .resolved(let result):
        return result
      }
    }
    if let delivered { continuation.resume(with: delivered) }
  }
}

/// Suspends until the handle `register` stores is resumed, `timeout` passes, or the caller
/// is cancelled, whichever is first.
///
/// `register` runs in its own task, so a slow registration (one that also writes a frame,
/// say) never stretches the deadline. When the wait ends without the owner resuming it
/// (timed out or cancelled), `abandon` is called with the same handle so the owner can drop
/// it. A `register` that arrives after that point finds `isResolved` already true.
///
/// - Throws: `timeoutError()` if the deadline passes, `CancellationError` if the caller is
///   cancelled, or whatever the owner resumes the handle with.
public func awaitContinuation<Value: Sendable>(
  timeout: Duration,
  timeoutError: @escaping @Sendable () -> any Error,
  register: @escaping @Sendable (OnceContinuation<Value>) async -> Void,
  abandon: @escaping @Sendable (OnceContinuation<Value>) async -> Void
) async throws -> Value {
  let handle = OnceContinuation<Value>()
  let watchdog = Task {
    try? await Task.sleep(for: timeout)
    guard !Task.isCancelled else { return }
    handle.resume(throwing: timeoutError())
  }
  defer { watchdog.cancel() }
  do {
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        handle.attach(continuation)
        Task { await register(handle) }
      }
    } onCancel: {
      handle.resume(throwing: CancellationError())
    }
  } catch {
    await abandon(handle)
    throw error
  }
}

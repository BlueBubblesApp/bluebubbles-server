//  ResumeOnce
//  A one-shot latch between an Objective-C completion block and `await`.
//
//  Every IMCore and TelephonyUtilities call that takes a completion has the same three
//  problems, and each call site had solved them by hand with a lock and a flag:
//
//    1. **The completion may fire more than once.** IMCore has been observed calling a block
//       twice for one query. `CheckedContinuation` traps on a second resume, so the first
//       caller has to win and the rest have to be ignored.
//    2. **It may fire before anyone is waiting.** A call that fails synchronously — a moved
//       selector, an argument the callee refused — has no completion coming, and the caller
//       must be released now rather than after a timeout.
//    3. **It may never fire.** Apple's services can simply not answer. The wait is bounded,
//       and a timeout is reported as a value rather than as a crash or a hang.
//
//  One type, so the lock-and-flag is written once and the seven sites that carried a private
//  copy cannot drift. Built on `OSAllocatedUnfairLock`, which is `Sendable` on its own — no
//  `@unchecked`, no `nonisolated(unsafe)`.

import Foundation
import os

public final class ResumeOnce<Value: Sendable>: Sendable {

  private enum Phase {
    case waiting(CheckedContinuation<Value, Never>?)
    case finished(Value)
  }

  private let phase = OSAllocatedUnfairLock<Phase>(initialState: .waiting(nil))

  public init() {}

  /// Whether `finish` has been called.
  public var isFinished: Bool {
    phase.withLock {
      if case .finished = $0 { return true }
      return false
    }
  }

  /// Delivers the value. The first call wins; later ones are ignored.
  ///
  /// Safe from any thread: completions arrive on whatever queue the daemon chose.
  public func finish(_ value: Value) {
    let pending: CheckedContinuation<Value, Never>? = phase.withLock { state in
      guard case .waiting(let continuation) = state else { return nil }
      state = .finished(value)
      return continuation
    }
    // Resumed OUTSIDE the lock: the continuation runs caller code, and holding a lock
    // across it invites a deadlock against anything that calls back in here.
    pending?.resume(returning: value)
  }

  /// Suspends until `finish` is called, or returns at once if it already has been.
  public func wait() async -> Value {
    await withCheckedContinuation { continuation in
      let already: Value? = phase.withLock { state in
        switch state {
        case .finished(let value):
          return value
        case .waiting:
          state = .waiting(continuation)
          return nil
        }
      }
      if let already { continuation.resume(returning: already) }
    }
  }

  /// Bounded wait. Delivers `timeoutValue` if nothing else has by then.
  ///
  /// The watchdog is a child task that is cancelled the moment the value arrives, so a
  /// completion that answers in a second does not leave a twenty-second sleep behind it.
  public func wait(timeout: Duration, onTimeout timeoutValue: Value) async -> Value {
    let watchdog = Task { [self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      finish(timeoutValue)
    }
    let value = await wait()
    watchdog.cancel()
    return value
  }
}

extension ResumeOnce where Value == Void {
  public func finish() { finish(()) }

  public func wait(timeout: Duration) async {
    await wait(timeout: timeout, onTimeout: ())
  }
}

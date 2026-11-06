//  OwnThread
//  Synchronous work that holds its thread for seconds, run on a thread of its own.
//
//  The cooperative pool has one thread per core. A synchronous call that runs for seconds on
//  it (a framework enumeration, a blocking XPC round trip) holds one of those threads the
//  whole time, and on a two-core Mac that is half of everything the server can do at once:
//  HTTP handlers, service starts and socket heartbeats all queue behind it. A whole
//  address-book index pass is such a call, and takes tens of seconds on a slow disk.
//
//  This waits for the work to FINISH, cancellation included. A cancelled caller sets the
//  flag the body is handed and goes on waiting, because the body is what owns the clean-up
//  (discarding a half-built rebuild, say), and a caller that returned first would leave it
//  running unseen. So the body has to check the flag at whatever granularity it can stop
//  at. Work that cannot be interrupted at all, such as one blocked XPC call, wants the
//  opposite trade, and `LaunchAtLogin` makes it for itself.

import Foundation

/// Runs `body` on a newly started thread and returns what it returns.
///
/// - Parameter body: handed a check that turns true once the calling task is cancelled. It
///   should stop soon after, by throwing `CancellationError` or returning what it has.
/// - Throws: whatever `body` throws.
public func onOwnThread<T: Sendable>(
  _ body: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
) async throws -> T {
  let cancelled = Locked(false)
  let answer = OnceContinuation<T>()
  Thread {
    answer.resume(with: Result { try body { cancelled.value } })
  }.start()
  return try await withTaskCancellationHandler {
    try await answer.value()
  } onCancel: {
    cancelled.withLock { $0 = true }
  }
}

/// Runs operations one at a time, in the order they arrive.
///
/// For work that is correct when overlapped but costs twice as much, such as two passes
/// over the same address book reading one spinning disk. A caller cancelled while waiting
/// leaves without running, and the next waiter takes its place.
public actor OneAtATime {
  private var busy = false
  private var waiting: [OnceContinuation<Void>] = []

  public init() {}

  public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try await claim()
    defer { release() }
    return try await operation()
  }

  private func claim() async throws {
    guard busy else {
      busy = true
      return
    }
    let turn = OnceContinuation<Void>()
    waiting.append(turn)
    try await withTaskCancellationHandler {
      try await turn.value()
    } onCancel: {
      turn.resume(throwing: CancellationError())
    }
  }

  /// Hands the turn to the oldest waiter still waiting, or frees it. A handle whose waiter
  /// was cancelled refuses the resume, and is skipped.
  private func release() {
    while !waiting.isEmpty {
      if waiting.removeFirst().resume(returning: ()) { return }
    }
    busy = false
  }
}

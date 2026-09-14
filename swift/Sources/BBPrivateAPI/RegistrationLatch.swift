//  RegistrationLatch
//  Waiting for an injected helper to call back, and answering honestly when it does not.
//
//  A helper's `ping` is the only positive proof an injection worked. Everything else (the
//  app relaunched, the dylib is on disk, dyld printed nothing) is consistent with an
//  injection that silently did nothing. So an injection ends by waiting here.
//
//  Its own type rather than four fields on `PrivateAPIRuntime`, for the reason the rest of
//  this project extracts collaborators: this is state with rules, and rules want testing
//  without the thing that owns them. Driving this through the runtime means quitting and
//  relaunching Messages; driving it here is four lines. `TransactionStore` was split out of
//  `SocketTransport` on the same argument.
//
//  Two rules.
//
//    - **A COUNT, not a flag.** "Is it connected?" cannot answer "did the injection I just
//      performed work?". Re-injecting an app that is already connected would short-circuit
//      on the existing registration and report success with Messages' pid unchanged, having
//      done nothing. A caller snapshots the count first and waits for one NEWER than that.
//    - **One waiter, released by whoever gets there first, and the answer read from the
//      count afterwards.** Not from whatever woke it: a wake proves something happened, not
//      that it was the thing this caller wanted.

import Foundation

/// Records helper registrations and lets a caller wait for a new one.
actor RegistrationLatch {

  /// How many times each helper has registered.
  private var counts: [String: Int] = [:]
  /// Keyed by waiter, so a timeout releases ITS OWN waiter and nobody else's.
  private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

  /// The current count, for a caller about to take a baseline.
  func count(of process: String) -> Int { counts[process, default: 0] }

  /// Records a registration and releases everyone waiting on that process.
  func observe(_ process: String) {
    counts[process, default: 0] += 1
    for waiter in (waiters.removeValue(forKey: process) ?? [:]).values {
      waiter.resume()
    }
  }

  /// Waits for a registration of `process` newer than `after`.
  ///
  /// ONE named helper, never "any registration at all". Short-circuiting on whatever happens
  /// to be connected is wrong in both directions once there are two helpers: injecting
  /// FaceTime would report instant success because Messages was already registered, and a
  /// genuine FaceTime failure would look like a success.
  ///
  /// **The continuation is stored synchronously.** This method is actor-isolated and
  /// `withCheckedContinuation`'s body is not async, so nothing suspends between the check
  /// above and the waiter becoming visible to `observe`. Handing the store to a `Task`
  /// instead opens a window where a registration arriving mid-hop resumes a list this waiter
  /// is not on yet, leaving it parked for something that has already happened, and
  /// injection then reports a helper that never registered when it had.
  ///
  /// It is deliberately NOT a task group racing a sleeper. A group whose child parks on a
  /// `withCheckedContinuation` cannot be ended by `cancelAll()`, because cancellation does
  /// not resume a continuation, so the group awaits that child forever and the timeout buys
  /// nothing. A private timer that releases this one waiter has no such child.
  func wait(for process: String, after baseline: Int, timeout: Duration) async -> Bool {
    if counts[process, default: 0] > baseline { return true }

    let id = UUID()
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      await self?.expire(waiter: id, for: process)
    }
    defer { expiry.cancel() }

    await withCheckedContinuation { continuation in
      waiters[process, default: [:]][id] = continuation
    }
    // Read from the count, not inferred from the wake: correct whether this was released
    // by the registration, by the timer, or by `releaseAll`.
    return counts[process, default: 0] > baseline
  }

  /// Releases everything still waiting. For shutdown: those registrations are not coming,
  /// and a caller parked on one would otherwise outlive the runtime.
  func releaseAll() {
    for processWaiters in waiters.values {
      for waiter in processWaiters.values { waiter.resume() }
    }
    waiters.removeAll()
  }

  /// Releases one waiter that has run out of time. A no-op if it was already resumed.
  private func expire(waiter id: UUID, for process: String) {
    guard let continuation = waiters[process]?.removeValue(forKey: id) else { return }
    continuation.resume()
  }
}

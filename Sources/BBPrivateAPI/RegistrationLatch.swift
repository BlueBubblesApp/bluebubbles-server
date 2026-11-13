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

import BBCore
import Foundation

/// Records helper registrations and lets a caller wait for a new one.
actor RegistrationLatch {

  /// How many times each helper has registered.
  private var counts: [String: Int] = [:]
  /// Per process, so a registration releases only the callers waiting for THAT helper, and a
  /// timeout or a cancellation drops only its own waiter.
  private var waiters: [String: [OnceContinuation<Void>]] = [:]

  /// The current count, for a caller about to take a baseline.
  func count(of process: String) -> Int { counts[process, default: 0] }

  /// Records a registration and releases everyone waiting on that process.
  func observe(_ process: String) {
    counts[process, default: 0] += 1
    for waiter in waiters.removeValue(forKey: process) ?? [] {
      waiter.resume(returning: ())
    }
  }

  /// Waits for a registration of `process` newer than `after`.
  ///
  /// ONE named helper, never "any registration at all". Short-circuiting on whatever happens
  /// to be connected is wrong in both directions once there are two helpers: injecting
  /// FaceTime would report instant success because Messages was already registered, and a
  /// genuine FaceTime failure would look like a success.
  ///
  /// Ends at the deadline, at a registration, at `releaseAll`, or when the caller is
  /// cancelled, which is what lets the runtime's start deadline actually end an injection
  /// still waiting here: a task group cancels its children and then waits for them, and a
  /// waiter that ignored cancellation held the group until its own timeout.
  ///
  /// `awaitContinuation` registers from a task of its own, so a registration can land
  /// between the check above and `park`. `park` checks the count again for exactly that
  /// case; a waiter parked for something that had already happened is how injection once
  /// reported a helper that never registered when it had.
  func wait(for process: String, after baseline: Int, timeout: Duration) async -> Bool {
    if counts[process, default: 0] > baseline { return true }

    // `try?` because the answer is never the error: it is read from the count below, which
    // is right whether the wait was ended by the registration, the deadline, `releaseAll` or
    // a cancellation.
    _ = try? await awaitContinuation(
      timeout: timeout,
      timeoutError: { TimedOut(after: timeout) },
      register: { [weak self] handle in
        await self?.park(handle, for: process, after: baseline)
      },
      abandon: { [weak self] handle in await self?.release(handle, for: process) }
    )
    return counts[process, default: 0] > baseline
  }

  /// Releases everything still waiting. For shutdown: those registrations are not coming,
  /// and a caller parked on one would otherwise outlive the runtime.
  func releaseAll() {
    for processWaiters in waiters.values {
      for waiter in processWaiters { waiter.resume(returning: ()) }
    }
    waiters.removeAll()
  }

  private func park(_ handle: OnceContinuation<Void>, for process: String, after baseline: Int) {
    guard counts[process, default: 0] <= baseline else {
      handle.resume(returning: ())
      return
    }
    guard !handle.isResolved else { return }
    waiters[process, default: []].append(handle)
  }

  private func release(_ handle: OnceContinuation<Void>, for process: String) {
    waiters[process]?.removeAll { $0 === handle }
  }
}

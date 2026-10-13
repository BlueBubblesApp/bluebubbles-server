//  Locked
//  A value that several threads read and write, behind one lock.
//
//  The alternative is a `final class … : @unchecked Sendable` holding an `NSLock` beside the
//  `var`s it guards. That compiles whether or not every access takes the lock, and the
//  `@unchecked` tells the compiler to stop looking, so a read added later without
//  `lock.withLock` is a data race nothing reports. Here the state is reachable only through
//  `withLock`, so an unguarded access does not compile, and the type is `Sendable` without
//  the `unchecked`.
//
//  Built on `OSAllocatedUnfairLock`, the lock Apple provides for exactly this from macOS 13.
//  `Synchronization.Mutex` is the standard library's equivalent and needs macOS 15, above
//  the floor.
//
//  **A copy shares its state.** The lock owns a heap allocation, so a `Locked` held by a
//  `Sendable` struct (a repository built once and copied into every caller) is one cache for
//  every copy, which is what each of those caches is for.
//
//  The body runs with the lock held: keep it to bookkeeping. Never `await`, never call back
//  into code that might take the same lock; an unfair lock is not recursive and a re-entry
//  deadlocks.

import os

/// A value guarded by an unfair lock, reachable only while holding it.
public struct Locked<State: Sendable>: Sendable {

  private let lock: OSAllocatedUnfairLock<State>

  public init(_ initialState: State) {
    lock = OSAllocatedUnfairLock(initialState: initialState)
  }

  /// Runs `body` with exclusive access to the state.
  ///
  /// The body is not required to be `Sendable`: it runs synchronously, on the caller's
  /// thread, and cannot outlive the call, so a non-`Sendable` capture (a builder closure, a
  /// local) never crosses an isolation boundary. That is the contract `withLockUnchecked`
  /// documents, and it is what lets a cache build its value under the lock.
  public func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
    try lock.withLockUnchecked(body)
  }

  /// A copy of the state, for a reader that only looks.
  public var value: State { withLock { $0 } }
}

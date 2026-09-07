//  AsyncPrimitives
//  Replacements for the decorator trio in lib/decorators: AsyncSingleton, AsyncRetryer and
//  DebounceSubsequentWithWait.
//
//  Note one behavioural fix carried over deliberately. The existing AsyncSingleton keys its
//  in-flight map by a GLOBAL STRING, so two instances of the same class share a lock and one
//  instance's call silently returns the other's result. `AsyncCoalescer` here is an instance
//  the caller owns, so scope is whatever the owner's scope is.

import Foundation

// MARK: - Coalescing

/// Collapses concurrent calls for the same key onto one in-flight operation.
///
/// Unlike the decorator it replaces, scope is per-instance: hold one on the service that
/// owns the work, and two services doing similar work cannot collide.
public actor AsyncCoalescer<Key: Hashable & Sendable, Value: Sendable> {

  private var inFlight: [Key: Task<Value, any Error>] = [:]

  public init() {}

  /// Runs `operation`, or joins the call already running for this key.
  public func run(
    _ key: Key,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    if let existing = inFlight[key] {
      return try await existing.value
    }

    let task = Task { try await operation() }
    inFlight[key] = task

    defer { inFlight[key] = nil }
    return try await task.value
  }

  public func cancelAll() {
    for task in inFlight.values { task.cancel() }
    inFlight.removeAll()
  }
}

// MARK: - Retry

public struct RetryPolicy: Sendable {
  public let maxAttempts: Int
  public let initialDelay: Duration
  public let maxDelay: Duration
  /// Exponential growth factor between attempts.
  public let multiplier: Double
  /// Consulted before each retry. Returning false gives up immediately, which is how a
  /// non-retryable failure (bad credentials, malformed request) avoids burning attempts.
  public let shouldRetry: @Sendable (any Error) -> Bool

  public init(
    maxAttempts: Int = 3,
    initialDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(60),
    multiplier: Double = 2,
    shouldRetry: @escaping @Sendable (any Error) -> Bool = { _ in true }
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
    self.multiplier = multiplier
    self.shouldRetry = shouldRetry
  }

  public static let none = RetryPolicy(maxAttempts: 1)

  /// Delay before the attempt at `attempt` (1-based), capped at `maxDelay`.
  ///
  /// Both bounds are read through `Duration.seconds`, which keeps the fractional part.
  /// Reading `components.seconds` instead truncates: a `.milliseconds(500)` base becomes a
  /// ZERO delay, so a supervised service with a sub-second policy retries in a tight loop
  /// instead of backing off — the failure mode backoff exists to prevent.
  public func delay(forAttempt attempt: Int) -> Duration {
    guard attempt > 1 else { return .zero }
    let factor = pow(multiplier, Double(attempt - 2))
    let seconds = initialDelay.seconds * factor
    let capped = min(seconds, maxDelay.seconds)
    return .seconds(max(0, capped))
  }
}

/// Runs `operation`, retrying per `policy`. Cancellation is respected between attempts.
public func withRetry<T: Sendable>(
  _ policy: RetryPolicy,
  operation: @Sendable () async throws -> T
) async throws -> T {
  var lastError: (any Error)?

  for attempt in 1...max(1, policy.maxAttempts) {
    if attempt > 1 {
      try await Task.sleep(for: policy.delay(forAttempt: attempt))
    }
    try Task.checkCancellation()

    do {
      return try await operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      lastError = error
      if !policy.shouldRetry(error) { throw error }
    }
  }

  throw lastError ?? CancellationError()
}

// MARK: - Debounce

extension AsyncSequence where Element: Sendable, Self: Sendable {
  /// Emits an element only once `interval` has passed without a newer one.
  ///
  /// Used for chat.db change events: a single message write produces several filesystem
  /// notifications, and polling on each one is wasted work.
  public func debounce(for interval: Duration) -> AsyncStream<Element> {
    AsyncStream { continuation in
      let task = Task {
        var pending: Task<Void, Never>?
        do {
          for try await element in self {
            pending?.cancel()
            pending = Task {
              do {
                try await Task.sleep(for: interval)
                continuation.yield(element)
              } catch {
                // Superseded by a newer element; drop this one.
              }
            }
          }
        } catch {
          // Upstream failed; close the debounced stream.
        }
        // Let a final pending element through rather than dropping it on close —
        // unless we are being torn down, in which case the pending timer is dropped.
        // Awaiting it there would hold the stream open for a whole `interval` after
        // cancellation, and leave a sleeping task behind if nobody ever awaited.
        if Task.isCancelled {
          pending?.cancel()
        } else {
          await pending?.value
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

// MARK: - Bounded cache

/// A size-capped, TTL-aware cache.
///
/// Every cache in the server uses this rather than an unbounded dictionary or an array
/// trimmed only by age. The current EventCache is a linear-scanned array with no size
/// bound, which is a large part of why the memory budget exists.
public struct BoundedCache<Key: Hashable, Value>: Sendable where Key: Sendable, Value: Sendable {

  private struct Entry {
    let value: Value
    let insertedAt: ContinuousClock.Instant
    /// The `order` slot that owns this entry. A slot whose sequence no longer matches the
    /// stored entry is a tombstone left behind by `remove`, and eviction skips it.
    let sequence: UInt64
  }

  private var storage: [Key: Entry] = [:]
  /// Insertion order, as a queue. `head` advances instead of shifting the array, and a
  /// removed key leaves its slot behind rather than being searched for. Both used to be
  /// O(n), and the change detector evicts thousands of entries in one reconcile pass —
  /// which made every eviction past capacity a full scan of the order array.
  private var order: [(sequence: UInt64, key: Key)] = []
  private var head = 0
  private var nextSequence: UInt64 = 0

  public let capacity: Int
  public let ttl: Duration?

  public init(capacity: Int, ttl: Duration? = nil) {
    self.capacity = max(1, capacity)
    self.ttl = ttl
  }

  public var count: Int { storage.count }

  public subscript(key: Key) -> Value? {
    mutating get {
      guard let entry = storage[key] else { return nil }
      if let ttl, ContinuousClock.now - entry.insertedAt > ttl {
        remove(key)
        return nil
      }
      return entry.value
    }
    set {
      if let newValue {
        insert(newValue, for: key)
      } else {
        remove(key)
      }
    }
  }

  public mutating func insert(_ value: Value, for key: Key) {
    let sequence: UInt64
    if let existing = storage[key] {
      // Keeps its place: this is insertion order, not access order.
      sequence = existing.sequence
    } else {
      sequence = nextSequence
      nextSequence += 1
      order.append((sequence: sequence, key: key))
    }
    storage[key] = Entry(value: value, insertedAt: ContinuousClock.now, sequence: sequence)
    evictIfNeeded()
    compactIfNeeded()
  }

  /// O(1). The order slot becomes a tombstone that eviction steps over.
  public mutating func remove(_ key: Key) {
    storage.removeValue(forKey: key)
  }

  public mutating func removeAll() {
    storage.removeAll()
    order.removeAll()
    head = 0
  }

  /// Drops entries past their TTL. Cheap enough to call on a timer.
  public mutating func trim() {
    guard let ttl else { return }
    let now = ContinuousClock.now
    let expired = storage.filter { now - $0.value.insertedAt > ttl }.map(\.key)
    for key in expired { storage.removeValue(forKey: key) }
    compactIfNeeded()
  }

  private mutating func evictIfNeeded() {
    while storage.count > capacity, head < order.count {
      let slot = order[head]
      head += 1
      if let entry = storage[slot.key], entry.sequence == slot.sequence {
        storage.removeValue(forKey: slot.key)
      }
    }
  }

  /// Rebuilds `order` from the live entries once consumed slots and tombstones outnumber
  /// them, so it cannot grow without bound under churn. Amortised O(1) per insert.
  private mutating func compactIfNeeded() {
    let dead = order.count - storage.count
    guard dead > max(64, storage.count) else { return }
    order = order[head...].filter { slot in storage[slot.key]?.sequence == slot.sequence }
    head = 0
  }
}

// MARK: - Duration

extension Duration {
  /// Seconds as a `Double`, for comparison against `TimeInterval`.
  ///
  /// `Duration` is exact and `TimeInterval` is not, so this is a deliberate narrowing at
  /// the boundary where the two meet — dates, timeouts read from settings, and anything
  /// that came from Foundation. Defined once here because three modules independently
  /// needed it and had started to disagree about what to call it.
  public var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}

//  AsyncPrimitives
//  Backoff arithmetic, a debounce, a bounded cache and `Duration` helpers.
//
//  A loop that retries on a schedule is not here: it is `retrying` / `poll` over a
//  `RetrySchedule` (`Polling.swift`), whose clock a test can drive. `RetryPolicy` below is
//  the arithmetic for the callers that compute a delay and wait on their own terms.

import Foundation

// MARK: - Retry

public struct RetryPolicy: Sendable {
  public let maxAttempts: Int
  public let initialDelay: Duration
  public let maxDelay: Duration
  /// Exponential growth factor between attempts.
  public let multiplier: Double

  public init(
    maxAttempts: Int = 3,
    initialDelay: Duration = .seconds(1),
    maxDelay: Duration = .seconds(60),
    multiplier: Double = 2
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
    self.multiplier = multiplier
  }

  public static let none = RetryPolicy(maxAttempts: 1)

  /// Delay before the attempt at `attempt` (1-based), capped at `maxDelay`.
  ///
  /// Both bounds are read through `Duration.seconds`, which keeps the fractional part.
  /// Reading `components.seconds` instead truncates: a `.milliseconds(500)` base becomes a
  /// ZERO delay, so a supervised service with a sub-second policy retries in a tight loop
  /// instead of backing off: the failure mode backoff exists to prevent.
  public func delay(forAttempt attempt: Int) -> Duration {
    guard attempt > 1 else { return .zero }
    let factor = pow(multiplier, Double(attempt - 2))
    let seconds = initialDelay.seconds * factor
    let capped = min(seconds, maxDelay.seconds)
    return .seconds(max(0, capped))
  }
}

// MARK: - Debounce

extension AsyncSequence where Element: Sendable, Self: Sendable {
  /// Emits an element only once `interval` has passed without a newer one.
  ///
  /// Used for chat.db change events: a single message write produces several filesystem
  /// notifications, and polling on each one is wasted work.
  public func debounce(for interval: Duration) -> AsyncStream<Element> {
    debounce(for: interval, bufferingPolicy: .unbounded)
  }

  /// The same, keeping only what `bufferingPolicy` allows while the consumer is busy.
  ///
  /// `.bufferingNewest(1)` coalesces everything that settled during one piece of work into a
  /// single follow-up, which is what a consumer that re-reads everything wants: two passes
  /// queued behind a long one would do the same work twice.
  ///
  /// An overload rather than a defaulted parameter: AsyncAlgorithms' `debounce(for:tolerance:)`
  /// is visible beside this one wherever both modules are, and two defaulted signatures make
  /// every `debounce(for:)` call ambiguous.
  public func debounce(
    for interval: Duration,
    bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
  ) -> AsyncStream<Element> {
    AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
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
        // Let a final pending element through rather than dropping it on close,
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
  /// removed key leaves its slot behind rather than being searched for. Both would
  /// otherwise be O(n), and the change detector evicts thousands of entries in one
  /// reconcile pass.
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
  /// the boundary where the two meet: dates, timeouts read from settings, and anything
  /// that came from Foundation. Defined once here because three modules independently
  /// needed it and had started to disagree about what to call it.
  public var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  /// Whole milliseconds, for a log line's `ms`. Truncated, not rounded: a reader wants
  /// "how long", and 0 for a sub-millisecond call reads better than 1.
  public var milliseconds: Int {
    Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}

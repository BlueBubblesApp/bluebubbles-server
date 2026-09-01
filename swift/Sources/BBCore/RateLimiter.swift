//  RateLimiter
//  Spacing a burst out without losing any of it.
//
//  The distinction this exists to make is between THROTTLING and DROPPING, which are easy to
//  conflate and are not the same thing:
//
//    - Dropping keeps the FIRST item in a window and discards the rest. Correct for a
//      counter, wrong for state — the last value is the current one, and discarding it
//      leaves every observer holding something stale until the next update happens to fall
//      outside a window.
//    - Coalescing keeps the LAST item and delays it to the interval boundary. Nothing is
//      lost; the intermediate values are simply superseded, which for a position, a typing
//      state or a call status is exactly right.
//
//  FindMy is the case that motivated it. Location updates arrive in bursts — a batch for
//  every device at once — and the current server sleeps 250ms between them inside the
//  handler, which blocks the whole handler and stalls FindMy processing for ten seconds on a
//  forty-device batch. Expressing it as a drop instead loses thirty-nine devices' positions.
//  Coalescing per device delivers every device's latest position, spaced.
//
//  See `docs/EVENTS.md`.

import Foundation

/// Per-key coalescing: emit immediately if the key is idle, otherwise hold the newest value
/// until the interval has elapsed.
///
/// Generic over the value so the same limiter serves events, positions, or anything else
/// where "the latest one wins" is the right reading.
public actor CoalescingRateLimiter<Key: Hashable & Sendable, Value: Sendable> {

  /// Minimum gap between deliveries for one key.
  public let interval: Duration
  /// Upper bound on keys tracked at once. A key can be a chat GUID or a device id and
  /// there is no natural limit on either, so there has to be an artificial one.
  public let capacity: Int

  private struct Pending {
    var value: Value
    var task: Task<Void, Never>?
  }

  private var lastEmitted: [Key: ContinuousClock.Instant] = [:]
  private var pending: [Key: Pending] = [:]
  private let emit: @Sendable (Key, Value) async -> Void

  /// - Parameter emit: Called with each value that survives coalescing. Called at most
  ///   once per `interval` per key, and always with the newest value seen for that key.
  public init(
    interval: Duration,
    capacity: Int = 512,
    emit: @escaping @Sendable (Key, Value) async -> Void
  ) {
    self.interval = interval
    self.capacity = max(1, capacity)
    self.emit = emit
  }

  /// Offers a value.
  ///
  /// Returns once the value has either been emitted or accepted for later emission — it
  /// never blocks for the interval, so a caller in a delivery path is not held up by its
  /// own rate limit.
  public func submit(_ value: Value, for key: Key, now: ContinuousClock.Instant = .now) async {
    // Superseding an already-pending value rather than queueing behind it: the point is
    // that the newest wins, and a queue would deliver stale positions in order.
    if pending[key] != nil {
      pending[key]?.value = value
      return
    }

    if let last = lastEmitted[key], now - last < interval {
      let delay = interval - (now - last)
      var entry = Pending(value: value, task: nil)
      entry.task = Task { [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        await self?.flush(key)
      }
      pending[key] = entry
      return
    }

    lastEmitted[key] = now
    evictIfNeeded()
    await emit(key, value)
  }

  /// Emits whatever is pending for a key, if anything.
  public func flush(_ key: Key) async {
    guard let entry = pending.removeValue(forKey: key) else { return }
    entry.task?.cancel()
    lastEmitted[key] = .now
    evictIfNeeded()
    await emit(key, entry.value)
  }

  /// Emits everything pending. Used on shutdown so a held value is not simply lost.
  public func flushAll() async {
    for key in pending.keys { await flush(key) }
  }

  public func cancelAll() {
    for entry in pending.values { entry.task?.cancel() }
    pending.removeAll()
    lastEmitted.removeAll()
  }

  public var pendingCount: Int { pending.count }
  public var trackedKeys: Int { lastEmitted.count }

  /// Forgets the least recently emitted keys.
  ///
  /// Only keys with nothing pending are evicted: dropping one that is holding a value
  /// would lose it, which is the behaviour this whole type exists to avoid.
  private func evictIfNeeded() {
    guard lastEmitted.count > capacity else { return }
    let evictable =
      lastEmitted
      .filter { pending[$0.key] == nil }
      .sorted { $0.value < $1.value }
      .map(\.key)
    for key in evictable.prefix(lastEmitted.count - capacity) {
      lastEmitted.removeValue(forKey: key)
    }
  }
}

/// A plain "may I do this again yet?" gate, shared across every caller.
///
/// Distinct from `CoalescingRateLimiter`, which spaces a stream of values we are producing.
/// This guards an ACTION we are about to take against something outside this server — where
/// the answer has to be no for everyone at once, not once per caller.
///
/// The FindMy friends refresh is the case. It reaches Apple through the helper, the server
/// is an ordinary FindMy client as far as Apple is concerned, and any connected client can
/// ask for it. Per-client limiting would multiply the request rate by the number of clients,
/// which is precisely the pressure that gets a client throttled at the far end.
public actor IntervalGate {

  public let interval: Duration
  private let clock: any BBClock
  private var lastPassed: Date?

  public init(interval: Duration, clock: any BBClock = SystemClock()) {
    self.interval = interval
    self.clock = clock
  }

  public enum Decision: Sendable, Equatable {
    case allowed
    /// Refused, with how long until the next attempt would be allowed.
    case tooSoon(retryAfter: Duration)
  }

  /// Consumes the gate if it is open.
  ///
  /// Records the attempt only when it is ALLOWED. Recording refused attempts too would let
  /// a client that polls faster than the interval hold the gate shut forever, which turns
  /// a rate limit into an outage.
  public func attempt() -> Decision {
    let now = clock.now
    guard let last = lastPassed else {
      lastPassed = now
      return .allowed
    }

    let elapsed = now.timeIntervalSince(last)
    guard elapsed >= interval.seconds else {
      return .tooSoon(retryAfter: .seconds(interval.seconds - elapsed))
    }
    lastPassed = now
    return .allowed
  }

  /// When the gate last opened, for reporting how stale an answer is.
  public var lastPassedAt: Date? { lastPassed }
}

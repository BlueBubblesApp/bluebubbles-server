import Foundation
import Testing

@testable import BBCore

@Suite("AppleTimestamp")
struct AppleTimestampTests {

  /// 2024-06-01 12:00:00 UTC, matching the value the chat.db fixtures are seeded with.
  let referenceDate = Date(timeIntervalSince1970: 1_717_243_200)

  @Test("Nanoseconds round-trip through the 2001 epoch")
  func nanosecondRoundTrip() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    #expect(stamp.rawValue == 738_936_000 * 1_000_000_000)
    let recovered = try! #require(stamp.date)
    #expect(abs(recovered.timeIntervalSince1970 - referenceDate.timeIntervalSince1970) < 0.001)
  }

  /// The pre-High-Sierra scale. Decoding a seconds value as nanoseconds yields 1970-ish;
  /// the reverse yields the far future. Both look like dates, which is why this is typed.
  @Test("Seconds round-trip through the 2001 epoch")
  func secondRoundTrip() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .seconds)
    #expect(stamp.rawValue == 738_936_000)
    let recovered = try! #require(stamp.date)
    #expect(abs(recovered.timeIntervalSince1970 - referenceDate.timeIntervalSince1970) < 0.001)
  }

  @Test("The same instant differs by 10^9 between units")
  func unitsAreNotInterchangeable() {
    let nanos = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    let seconds = AppleTimestamp.from(referenceDate, unit: .seconds)
    #expect(nanos.rawValue == seconds.rawValue * 1_000_000_000)
  }

  /// Zero means "never" in this schema. Reading it as a date makes every unread message
  /// look like it was read on 2001-01-01.
  @Test("Zero is unset, not the epoch")
  func zeroIsUnset() {
    let stamp = AppleTimestamp(rawValue: 0, unit: .nanoseconds)
    #expect(stamp.isUnset)
    #expect(stamp.date == nil)
    #expect(stamp.epochMilliseconds == nil)
  }

  @Test("SQL NULL and 0 both decode to nil")
  func nullAndZeroAgree() {
    #expect(AppleTimestamp.column(nil, unit: .nanoseconds) == nil)
    #expect(AppleTimestamp.column(0, unit: .nanoseconds) == nil)
    #expect(AppleTimestamp.column(1, unit: .nanoseconds) != nil)
  }

  /// The wire format is epoch milliseconds, never ISO strings. Clients parse it as a
  /// number, so this is part of the compatibility contract.
  @Test("Serializes to epoch milliseconds")
  func epochMilliseconds() {
    let stamp = AppleTimestamp.from(referenceDate, unit: .nanoseconds)
    #expect(stamp.epochMilliseconds == 1_717_243_200_000)
  }
}

@Suite("BoundedCache")
struct BoundedCacheTests {

  @Test("Evicts oldest past capacity")
  func evictsOldest() {
    var cache = BoundedCache<String, Int>(capacity: 3)
    for (index, key) in ["a", "b", "c", "d"].enumerated() {
      cache.insert(index, for: key)
    }
    #expect(cache.count == 3)
    #expect(cache["a"] == nil)
    #expect(cache["d"] == 3)
  }

  /// The property that matters for the memory budget: the current EventCache is an
  /// unbounded array trimmed only by age, so a burst grows it without limit.
  @Test("Never exceeds capacity under a burst")
  func capacityHoldsUnderLoad() {
    var cache = BoundedCache<Int, Int>(capacity: 10)
    for index in 0..<10_000 { cache.insert(index, for: index) }
    #expect(cache.count == 10)
  }

  @Test("Overwriting a key does not grow the cache")
  func overwriteDoesNotGrow() {
    var cache = BoundedCache<String, Int>(capacity: 5)
    for value in 0..<100 { cache.insert(value, for: "same") }
    #expect(cache.count == 1)
    #expect(cache["same"] == 99)
  }

  @Test("Removal clears both storage and ordering")
  func removalIsComplete() {
    var cache = BoundedCache<String, Int>(capacity: 3)
    cache.insert(1, for: "a")
    cache.remove("a")
    #expect(cache.count == 0)
    cache.insert(2, for: "b")
    cache.insert(3, for: "c")
    cache.insert(4, for: "d")
    #expect(cache.count == 3)
  }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {

  @Test("Backs off exponentially, capped")
  func backoffGrowsAndCaps() {
    let policy = RetryPolicy(
      maxAttempts: 10, initialDelay: .seconds(1), maxDelay: .seconds(8), multiplier: 2
    )
    #expect(policy.delay(forAttempt: 1) == .zero)
    #expect(policy.delay(forAttempt: 2) == .seconds(1))
    #expect(policy.delay(forAttempt: 3) == .seconds(2))
    #expect(policy.delay(forAttempt: 4) == .seconds(4))
    #expect(policy.delay(forAttempt: 5) == .seconds(8))
    #expect(policy.delay(forAttempt: 9) == .seconds(8))
  }

  @Test("Retries until success")
  func retriesUntilSuccess() async throws {
    actor Counter {
      var value = 0
      func increment() -> Int {
        value += 1
        return value
      }
    }
    let counter = Counter()
    let policy = RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1))

    let result = try await withRetry(policy) {
      let attempt = await counter.increment()
      if attempt < 3 { throw TestError.transient }
      return attempt
    }
    #expect(result == 3)
  }

  /// A non-retryable failure should not burn the attempt budget — bad credentials will
  /// not become good on the third try.
  @Test("shouldRetry false gives up immediately")
  func nonRetryableStopsAtOnce() async {
    actor Counter {
      var value = 0
      func increment() { value += 1 }
      func get() -> Int { value }
    }
    let counter = Counter()
    let policy = RetryPolicy(
      maxAttempts: 5, initialDelay: .milliseconds(1), shouldRetry: { _ in false }
    )

    _ = try? await withRetry(policy) {
      await counter.increment()
      throw TestError.permanent
    }
    #expect(await counter.get() == 1)
  }
}

@Suite("AsyncCoalescer")
struct AsyncCoalescerTests {

  /// Concurrent callers for one key share a single execution.
  @Test("Collapses concurrent calls for the same key")
  func collapsesSameKey() async throws {
    actor Counter {
      var value = 0
      func increment() { value += 1 }
      func get() -> Int { value }
    }
    let counter = Counter()
    let coalescer = AsyncCoalescer<String, Int>()

    async let first = coalescer.run("key") {
      await counter.increment()
      try await Task.sleep(for: .milliseconds(50))
      return 1
    }
    async let second = coalescer.run("key") {
      await counter.increment()
      try await Task.sleep(for: .milliseconds(50))
      return 1
    }
    _ = try await (first, second)
    #expect(await counter.get() == 1)
  }

  /// Different keys must not share. The decorator this replaces keys by a global string,
  /// so two instances of the same class collide and one silently gets the other's result.
  @Test("Different keys run independently")
  func differentKeysDoNotCollide() async throws {
    actor Counter {
      var value = 0
      func increment() { value += 1 }
      func get() -> Int { value }
    }
    let counter = Counter()
    let coalescer = AsyncCoalescer<String, Int>()

    async let first = coalescer.run("a") {
      await counter.increment()
      return 1
    }
    async let second = coalescer.run("b") {
      await counter.increment()
      return 2
    }
    _ = try await (first, second)
    #expect(await counter.get() == 2)
  }
}

enum TestError: Error { case transient, permanent }

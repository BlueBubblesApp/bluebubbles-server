//  BoundedCacheTests
//  The fixed-capacity cache the memory budget depends on.
//
//  It replaces an `EventCache` that was an unbounded array trimmed only by age, so a burst of
//  traffic grew it without limit: the shape of leak that looks like nothing at all until a
//  long-running server is holding hundreds of megabytes. → `.claude/docs/performance.md`
//
//  Most of the file is eviction ordering, because that is where it has actually been wrong.
//  `remove` leaves a tombstone in the order queue, and eviction has to step OVER the ghost to
//  reach the oldest live entry rather than stopping at it; a key removed and re-inserted is
//  young again, while a key merely overwritten keeps its original place. Getting any of those
//  backwards still evicts something, still keeps the count under capacity, and quietly drops
//  the wrong entry.
//
//  `churnStaysBounded` is the change detector's access pattern rather than a synthetic one: a
//  window larger than the cache, re-fingerprinted every pass. The linear eviction this
//  replaced made that quadratic.

import Foundation
import Testing

@testable import BBCore

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

  /// The property that matters for the memory budget. The reference's `EventCache`
  /// (`server/eventCache/index.ts`) is a plain array with `trim(msOld)` as its only
  /// eviction, so a burst inside the age window grows it without limit.
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

  @Test("A removed key does not hold a slot against eviction")
  func removedKeyDoesNotBlockEviction() {
    // `remove` leaves a tombstone in the order queue. Eviction has to step over it and
    // evict the oldest LIVE entry, not stop at the ghost.
    var cache = BoundedCache<String, Int>(capacity: 2)
    cache.insert(1, for: "a")
    cache.insert(2, for: "b")
    cache.remove("a")
    cache.insert(3, for: "c")
    cache.insert(4, for: "d")
    #expect(cache.count == 2)
    #expect(cache["b"] == nil, "b was the oldest live entry")
    #expect(cache["c"] == 3)
    #expect(cache["d"] == 4)
  }

  @Test("A key removed and re-inserted is young again")
  func reinsertedKeyIsYoung() {
    var cache = BoundedCache<String, Int>(capacity: 2)
    cache.insert(1, for: "a")
    cache.insert(2, for: "b")
    cache.remove("a")
    cache.insert(3, for: "a")
    cache.insert(4, for: "c")
    #expect(cache["b"] == nil, "b is now the oldest")
    #expect(cache["a"] == 3)
  }

  @Test("Overwriting keeps a key's original place in the order")
  func overwriteKeepsPosition() {
    var cache = BoundedCache<String, Int>(capacity: 2)
    cache.insert(1, for: "a")
    cache.insert(2, for: "b")
    cache.insert(10, for: "a")
    cache.insert(3, for: "c")
    #expect(cache["a"] == nil, "refreshing a value is not re-inserting it")
    #expect(cache["b"] == 2)
  }

  @Test("Churn well past capacity stays bounded and correct")
  func churnStaysBounded() {
    // The change detector's shape: a window larger than the cache, re-fingerprinted
    // every pass. The old linear eviction made this quadratic.
    var cache = BoundedCache<Int, Int>(capacity: 1_000)
    for pass in 0..<5 {
      for index in 0..<20_000 { cache.insert(pass, for: index) }
      for index in stride(from: 0, to: 20_000, by: 7) { cache.remove(index) }
    }
    #expect(cache.count <= 1_000)
    #expect(cache[19_998] == 4, "19,998 is not a multiple of 7 and was in the last pass")
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

//  AsyncCoalescerTests
//  Concurrent callers asking for the same thing share one execution.
//
//  The point of the two tests is the KEY. The decorator this replaces keyed by a single
//  global string, so two instances of the same class collided: one caller silently received
//  the other's result, which is indistinguishable from a correct answer until the two
//  instances are configured differently. Keying per call site makes "different keys run
//  independently" a property that can be asserted, and it is asserted here.

import Foundation
import Testing

@testable import BBCore

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

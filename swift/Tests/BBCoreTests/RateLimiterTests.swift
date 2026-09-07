//  RateLimiterTests
//  Coalescing versus dropping, and why the FindMy gate is global.
//
//  The distinction these pin is easy to get wrong in both directions. Dropping keeps the
//  FIRST value in a window, which is right for counting attempts and wrong for state: a
//  position, a typing flag or a call status is only useful as its LATEST value, and keeping
//  the oldest one leaves every observer stale. Coalescing keeps the newest and delays it.

import Foundation
import Testing

@testable import BBCore

@Suite("Coalescing rate limiter")
struct CoalescingRateLimiterTests {

  private actor Received {
    private(set) var values: [(key: String, value: Int)] = []
    func record(_ key: String, _ value: Int) { values.append((key, value)) }
    var count: Int { values.count }
    var latest: Int? { values.last?.value }
    func valuesFor(_ key: String) -> [Int] {
      values.filter { $0.key == key }.map(\.value)
    }
  }

  @Test("The first value for a key goes straight through")
  func firstValueIsImmediate() async {
    let received = Received()
    let limiter = CoalescingRateLimiter<String, Int>(interval: .seconds(10)) { key, value in
      await received.record(key, value)
    }
    await limiter.submit(1, for: "a")
    #expect(await received.count == 1)
  }

  @Test("A burst is coalesced to its newest value, not its oldest")
  func burstKeepsTheNewest() async {
    // The whole point. Dropping would deliver 1 and discard 2 through 9, leaving every
    // observer holding the oldest position in the batch.
    let received = Received()
    let limiter = CoalescingRateLimiter<String, Int>(interval: .seconds(10)) { key, value in
      await received.record(key, value)
    }

    let instant = ContinuousClock.now
    for value in 1...10 {
      await limiter.submit(value, for: "a", now: instant)
    }
    // One delivered immediately, the rest collapsed into one pending value.
    #expect(await received.count == 1)
    #expect(await limiter.pendingCount == 1)

    await limiter.flushAll()
    #expect(await received.valuesFor("a") == [1, 10], "the newest value was not kept")
  }

  @Test("Nothing in a burst is lost when it is flushed")
  func nothingIsLost() async {
    // "Coalesced" must not become "dropped on shutdown". The held value is the newest
    // there is, so losing it is worse than losing an intermediate one.
    let received = Received()
    let limiter = CoalescingRateLimiter<String, Int>(interval: .seconds(60)) { key, value in
      await received.record(key, value)
    }
    let instant = ContinuousClock.now
    await limiter.submit(1, for: "a", now: instant)
    await limiter.submit(2, for: "a", now: instant)

    await limiter.flushAll()
    #expect(await received.latest == 2)
    #expect(await limiter.pendingCount == 0)
  }

  @Test("Separate keys do not share a window")
  func keysAreIndependent() async {
    let received = Received()
    let limiter = CoalescingRateLimiter<String, Int>(interval: .seconds(10)) { key, value in
      await received.record(key, value)
    }
    let instant = ContinuousClock.now
    await limiter.submit(1, for: "a", now: instant)
    await limiter.submit(2, for: "b", now: instant)
    await limiter.submit(3, for: "c", now: instant)
    #expect(await received.count == 3)
  }

  @Test("Tracked keys are bounded")
  func keysAreBounded() async {
    // A key can be a chat GUID or a device id, and there is no natural limit on either.
    let received = Received()
    let limiter = CoalescingRateLimiter<String, Int>(
      interval: .milliseconds(1), capacity: 8
    ) { key, value in
      await received.record(key, value)
    }
    for index in 0..<100 {
      await limiter.submit(index, for: "key-\(index)")
    }
    #expect(await limiter.trackedKeys <= 8)
  }
}

@Suite("Interval gate")
struct IntervalGateTests {

  @Test("The first attempt passes and the next is refused")
  func firstPassesThenRefuses() async {
    let clock = ManualClock()
    let gate = IntervalGate(interval: .seconds(15), clock: clock)

    #expect(await gate.attempt() == .allowed)
    guard case .tooSoon = await gate.attempt() else {
      Issue.record("a second attempt inside the interval was allowed")
      return
    }
  }

  @Test("The gate opens again once the interval elapses")
  func gateReopens() async {
    let clock = ManualClock()
    let gate = IntervalGate(interval: .seconds(15), clock: clock)
    #expect(await gate.attempt() == .allowed)

    clock.advance(by: 15)
    #expect(await gate.attempt() == .allowed)
  }

  @Test("A refused attempt does not extend the window")
  func refusalDoesNotExtend() async {
    // Recording refused attempts would let a client polling faster than the interval
    // hold the gate shut forever — every retry pushing the opening further out — which
    // turns a rate limit into an outage for anyone with an eager client.
    let clock = ManualClock()
    let gate = IntervalGate(interval: .seconds(10), clock: clock)
    #expect(await gate.attempt() == .allowed)

    // Hammered every second for nine seconds, all inside the window.
    for _ in 0..<9 {
      clock.advance(by: 1)
      guard case .tooSoon = await gate.attempt() else {
        Issue.record("the gate opened early")
        return
      }
    }

    // The tenth second is the boundary, and it opens exactly there — not ten seconds
    // after the last refusal.
    clock.advance(by: 1)
    #expect(await gate.attempt() == .allowed)
  }

  @Test("The gate is shared, so more clients do not mean more requests")
  func gateIsGlobal() async {
    // The FindMy case. Several clients are connected by design; the server is one FindMy
    // client as far as Apple is concerned, and the request rate must not scale with the
    // number of people looking at it.
    let clock = ManualClock()
    let gate = IntervalGate(interval: .seconds(15), clock: clock)

    var allowed = 0
    for _ in 0..<10 {
      if case .allowed = await gate.attempt() { allowed += 1 }
    }
    #expect(allowed == 1, "ten concurrent clients produced \(allowed) upstream requests")
  }

  @Test("The refusal says how long to wait")
  func refusalReportsRetryAfter() async {
    let clock = ManualClock()
    let gate = IntervalGate(interval: .seconds(15), clock: clock)
    _ = await gate.attempt()

    clock.advance(by: 5)
    guard case .tooSoon(let retryAfter) = await gate.attempt() else {
      Issue.record("expected a refusal")
      return
    }
    // Roughly ten seconds left. Reported so a client can back off intelligently rather
    // than retrying blind.
    #expect(abs(retryAfter.seconds - 10) < 0.01)
  }
}

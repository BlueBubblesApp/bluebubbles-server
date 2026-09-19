//  NetworkPathObserverTests
//  That a burst of path changes becomes one transition, and that it is the SETTLED one.
//
//  This is the behaviour the wake case depends on. A Mac coming back does not report one
//  change: loopback, then Wi-Fi associating, then a lease, then a VPN, each its own callback.
//  Publishing the first of those is worse than publishing nothing — it is the instant the
//  system believes a route exists, which is before DNS resolves and before anything works.
//
//  A short debounce is used here rather than the two-second default, so the suite stays fast.
//  The window is a parameter for exactly this reason; the default is calibrated by watching a
//  real machine, not by a test.
//
//  ## What used to be flaky here, and why a bigger margin was the wrong fix
//
//  This suite failed intermittently under the full parallel run and passed every time on its
//  own. Both of its sleeps were guesses about SCHEDULING dressed up as guesses about time, and
//  a saturated cooperative pool does not honour either:
//
//  1. The baseline was FED and then slept on. A sleep does not make the pump run, so when it
//     had not, the baseline and the burst after it landed in one debounce window, the whole lot
//     evaluated as the FIRST observation, and the first observation is never a transition —
//     zero published, which is exactly the failure that was seen. It is stated now
//     (`startingFrom:`) instead of raced for.
//  2. The transition was slept on and then `stop()` was called. `stop()` finishes every
//     subscriber, so an evaluation that had not been scheduled yet published into nothing. The
//     arrival is WAITED for now, with a deadline generous enough to be a real failure.
//
//  A quiet window is still slept, and that one is sound: "nothing more arrived" is a claim
//  about elapsed time and there is no signal that can stand in for it. Widening a margin makes
//  a test slower and no more correct; the two above needed a signal, not a bigger number.

import Foundation
import Testing

@testable import BBSystem

@Suite("Network path observer", .serialized)
struct NetworkPathObserverTests {

  static let window = Duration.milliseconds(50)
  /// How long to keep listening after the expected transitions have arrived, to catch one that
  /// should not have. Twenty times the window: an extra would be produced by the same debounce
  /// that produced the real one, so it has long since been due.
  static let quiet = Duration.milliseconds(1000)
  /// The ceiling on waiting for something that SHOULD arrive. Nothing here takes a second; a
  /// wait that reaches this is a hang, not a slow machine.
  static let deadline = Duration.seconds(20)

  // Only two tests here, and that is the design rather than thin coverage. What a sequence of
  // settled paths MEANS is asserted without a clock in `NetworkTransitionCoalescerTests`;
  // what is left for this suite is the one claim only real time can support — that a burst
  // becomes a single settled evaluation.

  static func path(_ satisfied: Bool, interfaces: [String] = ["en0"]) -> NetworkPath {
    NetworkPath(
      isSatisfied: satisfied, interfaces: interfaces,
      localAddresses: satisfied ? ["192.168.1.50"] : [])
  }

  /// Everything the collector has been handed so far, readable while it is still running.
  private actor Collected {
    private(set) var transitions: [NetworkTransition] = []
    func append(_ transition: NetworkTransition) { transitions.append(transition) }
    var count: Int { transitions.count }
  }

  /// An observer fed by hand, plus the continuation to feed it with.
  ///
  /// - Parameter startingFrom: the settled state the burst is measured against. Stated rather
  ///   than fed; see the file header.
  static func observer(
    startingFrom baseline: NetworkPath?
  ) -> (NetworkPathObserver, AsyncStream<NetworkPath>.Continuation) {
    let (stream, continuation) = AsyncStream<NetworkPath>.makeStream()
    let observer = NetworkPathObserver(debounce: window, startingFrom: baseline) { stream }
    return (observer, continuation)
  }

  /// Runs `body`, waits for `expecting` transitions to arrive, then listens a while longer for
  /// any that should not have.
  static func collect(
    from observer: NetworkPathObserver,
    expecting expected: Int,
    while body: @Sendable () async throws -> Void
  ) async throws -> [NetworkTransition] {
    let transitions = await observer.transitions()
    let collected = Collected()
    let collector = Task {
      for await transition in transitions { await collected.append(transition) }
    }
    await observer.start()
    try await body()

    if expected > 0 {
      try await waitUntil("\(expected) transition(s)") { await collected.count >= expected }
    }
    // The quiet window, in both cases: after the expected arrivals it catches an extra, and
    // with none expected it IS the assertion.
    try await Task.sleep(for: quiet)

    await observer.stop()
    _ = await collector.value
    return await collected.transitions
  }

  /// Polls until `condition` holds, or fails the test naming what never happened.
  ///
  /// Polling rather than a second stream: what is being waited on is state inside an actor, and
  /// a 5 ms poll against a 20-second ceiling costs nothing while making the failure a sentence
  /// rather than a hung suite.
  static func waitUntil(
    _ what: String,
    _ condition: @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(
      "waited \(deadline) for \(what) and it never arrived", sourceLocation: sourceLocation)
  }

  /// The wake case, which is the whole reason the debounce exists.
  @Test("A burst of changes becomes one transition, carrying the settled state")
  func burstCollapses() async throws {
    // The baseline is "no network", so the burst is a transition to having one.
    let (observer, feed) = Self.observer(startingFrom: Self.path(false))
    let seen = try await Self.collect(from: observer, expecting: 1) {
      // The wake: five callbacks in quick succession, ending on the real state.
      feed.yield(Self.path(true, interfaces: ["lo0"]))
      feed.yield(Self.path(true, interfaces: ["lo0", "en0"]))
      feed.yield(Self.path(true, interfaces: ["en0"]))
      feed.yield(Self.path(true, interfaces: ["en0", "utun3"]))
      feed.yield(Self.path(true, interfaces: ["en0", "utun4"]))
    }

    #expect(seen.count == 1, "a burst must not produce a transition each")
    #expect(seen.first?.permitsRetry == true)
    // The SETTLED state, not the first one seen. Publishing `lo0` would tell a consumer the
    // network came back on loopback.
    #expect(seen.first?.path.interfaces == ["en0", "utun4"])
  }

  /// The first observation is never a transition: there is nothing for it to have changed from,
  /// and announcing one would report "the network arrived" every time the observer started.
  @Test("With no baseline, the first settled path announces nothing")
  func firstObservationIsNotATransition() async throws {
    let (observer, feed) = Self.observer(startingFrom: nil)
    let seen = try await Self.collect(from: observer, expecting: 0) {
      feed.yield(Self.path(true))
      // Waits for the debounce to have FIRED, rather than assuming it did: the claim is that
      // an evaluation happened and published nothing, which is not the same as no evaluation.
      try await Self.waitUntil("the first evaluation") {
        await observer.settledEvaluations >= 1
      }
    }
    #expect(seen.isEmpty)
  }

  @Test("Stopping ends the stream without inventing a transition")
  func stopIsClean() async throws {
    let (observer, feed) = Self.observer(startingFrom: Self.path(true))
    let seen = try await Self.collect(from: observer, expecting: 0) {
      // The same path again: settled, evaluated, and no change to announce.
      feed.yield(Self.path(true))
      try await Self.waitUntil("the evaluation") { await observer.settledEvaluations >= 1 }
    }
    #expect(seen.isEmpty)
    // The stream finished, which is what let `collect` return at all.
    await observer.stop()
  }
}

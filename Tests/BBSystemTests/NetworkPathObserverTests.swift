//  NetworkPathObserverTests
//  That a burst of path changes becomes one transition, and that it is the SETTLED one.
//
//  This is the behaviour the wake case depends on. A Mac coming back does not report one
//  change: loopback, then Wi-Fi associating, then a lease, then a VPN, each its own callback.
//  Publishing the first of those is worse than publishing nothing — it is the instant the
//  system believes a route exists, which is before DNS resolves and before anything works.
//
//  The debounce runs on a `TestClock`, so no test here waits on real time. That is what makes
//  every claim exact rather than probable:
//
//  - **A burst** is several paths fed with no clock time between them. Each is fed only once
//    the previous one's window is parked on the clock, so the pump has consumed it; a burst
//    fed all at once would leave how far the pump got to the scheduler.
//  - **"Nothing more arrives"** is shown by moving the clock past every window that could
//    still be pending. On the wall clock it could only be a quiet interval, which proves
//    nothing arrived within that interval and costs it in full on every run.
//  - **The baseline is stated** (`startingFrom:`), never fed: a fed baseline races the burst
//    after it into one window, and the first observation is never a transition.

import BBTestSupport
import Foundation
import Testing

@testable import BBSystem

@Suite("Network path observer")
struct NetworkPathObserverTests {

  static let window = Duration.seconds(2)

  // What a sequence of settled paths MEANS is asserted in `NetworkTransitionCoalescerTests`;
  // this suite is about the timing: a burst becomes a single settled evaluation.

  static func path(_ satisfied: Bool, interfaces: [String] = ["en0"]) -> NetworkPath {
    NetworkPath(
      isSatisfied: satisfied, interfaces: interfaces,
      localAddresses: satisfied ? ["192.168.1.50"] : [])
  }

  /// What a run saw: the transitions published, and how many settled evaluations ran.
  struct Outcome {
    let transitions: [NetworkTransition]
    let evaluations: Int
  }

  /// Feeds `paths` as one burst against `baseline`, lets the window close, and reports.
  static func run(
    startingFrom baseline: NetworkPath?, feeding paths: [NetworkPath]
  ) async throws -> Outcome {
    let clock = TestClock()
    let (stream, feed) = AsyncStream<NetworkPath>.makeStream()
    let observer = NetworkPathObserver(
      debounce: window, clock: clock, startingFrom: baseline
    ) { stream }

    let transitions = await observer.transitions()
    let collector = Task {
      var seen: [NetworkTransition] = []
      for await transition in transitions { seen.append(transition) }
      return seen
    }
    await observer.start()

    for (index, path) in paths.enumerated() {
      feed.yield(path)
      // This path's window has asked the clock for its debounce, so the pump has consumed it.
      try await waitUntil("the window for path \(index + 1)") { clock.waits.count > index }
    }
    #expect(clock.sleeperCount == 1, "each change should restart the window, not open another")

    clock.advance(by: window)
    try await waitUntil("the settled evaluation") { await observer.settledEvaluations >= 1 }
    // Every window that could still fire is now past due. Only the last one was not
    // cancelled, so nothing else can evaluate.
    clock.advance(by: window * 10)
    #expect(clock.sleeperCount == 0, "a debounce window is still waiting")

    let evaluations = await observer.settledEvaluations
    await observer.stop()
    return Outcome(transitions: await collector.value, evaluations: evaluations)
  }

  /// The wake case, which is the whole reason the debounce exists.
  @Test("A burst of changes becomes one transition, carrying the settled state")
  func burstCollapses() async throws {
    // The baseline is "no network", so the burst is a transition to having one. The wake:
    // five callbacks inside one window, ending on the real state.
    let outcome = try await Self.run(
      startingFrom: Self.path(false),
      feeding: [
        Self.path(true, interfaces: ["lo0"]),
        Self.path(true, interfaces: ["lo0", "en0"]),
        Self.path(true, interfaces: ["en0"]),
        Self.path(true, interfaces: ["en0", "utun3"]),
        Self.path(true, interfaces: ["en0", "utun4"]),
      ])

    #expect(outcome.evaluations == 1, "a burst must settle once, not once per change")
    #expect(outcome.transitions.count == 1, "a burst must not produce a transition each")
    #expect(outcome.transitions.first?.permitsRetry == true)
    // The SETTLED state, not the first one seen. Publishing `lo0` would tell a consumer the
    // network came back on loopback.
    #expect(outcome.transitions.first?.path.interfaces == ["en0", "utun4"])
  }

  /// The first observation is never a transition: there is nothing for it to have changed from,
  /// and announcing one would report "the network arrived" every time the observer started.
  @Test("With no baseline, the first settled path announces nothing")
  func firstObservationIsNotATransition() async throws {
    let outcome = try await Self.run(startingFrom: nil, feeding: [Self.path(true)])
    // An evaluation happened and published nothing, which is not the same as no evaluation.
    #expect(outcome.evaluations == 1)
    #expect(outcome.transitions.isEmpty)
  }

  @Test("Stopping ends the stream without inventing a transition")
  func stopIsClean() async throws {
    // The same path again: settled, evaluated, and no change to announce. The stream
    // finishing on `stop()` is what let `run` collect at all.
    let outcome = try await Self.run(startingFrom: Self.path(true), feeding: [Self.path(true)])
    #expect(outcome.evaluations == 1)
    #expect(outcome.transitions.isEmpty)
  }
}

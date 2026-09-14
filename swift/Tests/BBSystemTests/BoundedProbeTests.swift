//  BoundedProbeTests
//  The permission probe's deadline actually bounds it.
//
//  It did not, and the way it failed is worth stating because it hid itself. The probe ran in
//  one task-group child and the sleep in another, taking whichever answered first, which reads
//  as a race and is not one: `withCheckedContinuation` ignores cancellation, so the probe child
//  stayed blocked, and **a task group awaits its remaining children before it returns**.
//
//  So the old shape returned the RIGHT ANSWER at the WRONG TIME. Measured against a 200ms
//  deadline with a probe released after 3s: it answered `unknown`, as designed, after
//  3.006 seconds. Every test of the return value passed and the bound did nothing.
//
//  That matters more than a slow start. `AEDeterminePermissionToAutomateTarget` is reached
//  during startup, and a wedged `tccd` meant the HTTP listener bound (NIO runs its own
//  threads) while every async task behind it starved: a port that accepts connections it
//  never serves, with nothing logged as wrong. `tccd` stalls most readily for a process it
//  cannot attribute to a bundle, which is exactly an unbundled `swift run`.
//
//  The timing assertions here are deliberately loose. The property is "returns without
//  waiting for the probe", not "returns in exactly N milliseconds", and a tight bound on a
//  loaded CI machine is a flaky test rather than a stronger one.

import Foundation
import Testing

@testable import BBSystem

@Suite("Bounded permission probe")
struct BoundedProbeTests {

  /// Signalled by a probe that is never going to answer, so the test can let it go at the
  /// end rather than leaving a thread parked for the life of the test process.
  private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
  }

  @Test("A probe that never answers still returns at the deadline")
  func neverAnsweringProbeIsBounded() async {
    let gate = Gate()
    let started = ContinuousClock.now

    let status = await SystemPermissionProbe.boundedSyncProbe(deadline: .milliseconds(200)) {
      // Exactly what a wedged `tccd` looks like from here: a synchronous call that does not
      // come back. Before the fix this test deadlocked rather than failing: the call could
      // not return until this closure did, and this closure is released after the await.
      gate.wait()
      return .granted
    }
    let elapsed = ContinuousClock.now - started

    #expect(status == .unknown, "an unanswered probe is unknown, not a guess")
    #expect(elapsed < .seconds(5), "the deadline did not bound the call")

    gate.open()
  }

  @Test("A probe that answers in time returns its own answer")
  func fastProbeWins() async {
    let status = await SystemPermissionProbe.boundedSyncProbe(deadline: .seconds(5)) {
      .denied
    }
    // The deadline must not overwrite a real answer, which is the other half of the race.
    #expect(status == .denied)
  }

  @Test(
    "Every status the probe can return survives the race",
    arguments: [PermissionStatus.granted, .denied, .notDetermined, .unknown]
  )
  func answersPassThrough(expected: PermissionStatus) async {
    let status = await SystemPermissionProbe.boundedSyncProbe(deadline: .seconds(5)) { expected }
    #expect(status == expected)
  }

  @Test("A probe answering as the deadline fires resolves once, not twice")
  func simultaneousResolutionIsSafe() async {
    // A continuation resumed twice is a crash, and after the fix two things race to resume
    // this one. Run enough of them that a missing guard would be caught rather than hoped
    // about: the probe and the deadline are aimed at the same instant.
    for _ in 0..<200 {
      let status = await SystemPermissionProbe.boundedSyncProbe(deadline: .milliseconds(1)) {
        Thread.sleep(forTimeInterval: 0.001)
        return .granted
      }
      #expect(status == .granted || status == .unknown)
    }
  }

  @Test("Several bounded probes can be in flight at once")
  func concurrentProbes() async {
    // The permissions page checks a handful at once, and each holds its own thread and its
    // own continuation.
    let gate = Gate()
    let statuses = await withTaskGroup(of: PermissionStatus.self) { group in
      for _ in 0..<4 {
        group.addTask {
          await SystemPermissionProbe.boundedSyncProbe(deadline: .milliseconds(150)) {
            gate.wait()
            return .granted
          }
        }
      }
      var collected: [PermissionStatus] = []
      for await status in group { collected.append(status) }
      return collected
    }

    #expect(statuses.count == 4)
    #expect(statuses.allSatisfy { $0 == .unknown })
    for _ in 0..<4 { gate.open() }
  }
}

//  StalledProbeGateTests
//  A permission daemon that stops answering costs one leaked thread, not one every tick.
//
//  `boundedSyncProbe` abandons a blocked thread on purpose: a blocked `mach_msg` cannot be
//  interrupted, so giving up on the thread is the only way to answer within a deadline. That
//  reasoning is sound for one call and wrong for the loop that actually drives it.
//  `PermissionsService` re-checks every two seconds forever, so a `tccd` that has stopped
//  answering produced roughly thirty abandoned threads a minute, each holding a half-megabyte
//  stack and a kernel thread port, until the process hit the per-task thread limit and died.
//
//  The shape of that was reproduced with a probe that never returns: thread count climbs
//  linearly and nothing is reclaimed. What is asserted here is the gate that stops it, which
//  is testable without blocking anything: while a target is stalled, a caller is refused and
//  spawns nothing, and the refusal lifts by itself when the abandoned thread finally answers.

import Foundation
import Testing

@testable import BBSystem

@Suite("Stalled probe gate")
struct StalledProbeGateTests {

  private typealias Gate = SystemPermissionProbe.StalledProbeGate

  @Test("A second caller is refused while one probe is in flight")
  func oneAtATime() async {
    let gate = Gate()
    #expect(await gate.beginProbe("com.apple.MobileSMS"))
    #expect(
      await gate.beginProbe("com.apple.MobileSMS") == false,
      "a concurrent caller must not get its own thread")
    // A different target is unaffected: they block independently.
    #expect(await gate.beginProbe("com.apple.FaceTime"))

    await gate.endProbe("com.apple.MobileSMS")
    #expect(await gate.beginProbe("com.apple.MobileSMS"), "and it reopens once that one ends")
  }

  @Test("Once a probe has been abandoned, nothing else is spawned for that target")
  func stalledRefusesEveryone() async {
    let gate = Gate()
    #expect(await gate.beginProbe("com.apple.MobileSMS"))
    await gate.markStalled("com.apple.MobileSMS")
    #expect(await gate.isStalled("com.apple.MobileSMS"))

    // This is the loop that used to leak: thirty ticks, thirty threads.
    for _ in 0..<30 {
      #expect(
        await gate.beginProbe("com.apple.MobileSMS") == false,
        "a stalled target must cost exactly one leaked thread in total")
    }
    // And it does not spread to the other host.
    #expect(await gate.beginProbe("com.apple.FaceTime"))
  }

  @Test("Recovery is automatic when the abandoned thread finally answers")
  func lateAnswerReopensTheGate() async {
    let gate = Gate()
    #expect(await gate.beginProbe("com.apple.MobileSMS"))
    await gate.markStalled("com.apple.MobileSMS")
    #expect(await gate.beginProbe("com.apple.MobileSMS") == false)

    await gate.clearStalled("com.apple.MobileSMS")
    #expect(await gate.isStalled("com.apple.MobileSMS") == false)
    #expect(
      await gate.beginProbe("com.apple.MobileSMS"),
      "nothing else clears this, so a missed signal would wedge permissions forever")
  }

  @Test("The deadline reports whether it actually gave up on a thread")
  func deadlineKnowsWhetherItWon() async {
    // A probe that answers at once: the deadline fires later and must NOT report a stall,
    // or every healthy probe would mark its target stalled and stop all further checks.
    let abandoned = Recorder()
    let status = await SystemPermissionProbe.boundedSyncProbe(
      deadline: .milliseconds(50),
      onAbandon: { await abandoned.record() },
      probe: { .granted })
    #expect(status == .granted)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(await abandoned.count == 0, "a probe that answered must not be reported as abandoned")
  }
}

private actor Recorder {
  private(set) var count = 0
  func record() { count += 1 }
}

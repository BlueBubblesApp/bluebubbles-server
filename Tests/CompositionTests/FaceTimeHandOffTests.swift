//  FaceTimeHandOffTests
//  When the Mac may leave a call it placed or answered.
//
//  The rule used to live inside an HTTP handler's detached task, where the only way to test it
//  was a live call. It is a pure decision over the member list now, and these pin the cases
//  that were each learned the hard way on a real call.

import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Logging
import Testing
import struct os.OSAllocatedUnfairLock

@testable import BBFaceTime

@Suite("FaceTime hand-off")
struct FaceTimeHandOffTests {

  private func member(
    _ address: String, active: Bool = true, lightweight: Bool = false
  ) -> FaceTimeMember {
    FaceTimeMember(
      handle: FaceTimeHandle(value: address, displayName: nil),
      isPending: !active,
      isActive: active,
      isLightweight: lightweight
    )
  }

  @Test("On a 1:1 call the callee answering is not enough: the Mac would collapse the call")
  func calleeAloneIsNotEnough() {
    let members = [member("+12025550100")]
    #expect(!FaceTimeHandOff.mayLeave(members: members, dialledAddresses: ["+12025550100"]))
  }

  @Test("The Mac may leave once the callee AND the client are both active")
  func calleeAndClient() {
    let members = [member("+12025550100"), member("temp:guest", lightweight: true)]
    #expect(FaceTimeHandOff.mayLeave(members: members, dialledAddresses: ["+12025550100"]))
  }

  @Test("Someone still waiting to be let in does not count as joined")
  func waitingGuestDoesNotCount() {
    let members = [member("+12025550100"), member("temp:guest", active: false, lightweight: true)]
    #expect(!FaceTimeHandOff.mayLeave(members: members, dialledAddresses: ["+12025550100"]))
  }

  @Test("On a group call, two callees answering is not the client arriving")
  func groupCallWaitsForAnOutsider() {
    let dialled = ["+12025550100", "+12025550101", "+12025550102"]
    let twoCallees = [member("+12025550100"), member("+12025550101")]
    #expect(!FaceTimeHandOff.mayLeave(members: twoCallees, dialledAddresses: dialled))

    let withClient = twoCallees + [member("someone@example.com")]
    #expect(FaceTimeHandOff.mayLeave(members: withClient, dialledAddresses: dialled))
  }

  @Test("A callee reported in a different number format is still recognised as a callee")
  func handleFormatsAreLoose() {
    #expect(FaceTimeHandOff.sameHandle("+12025550100", "2025550100"))
    #expect(FaceTimeHandOff.sameHandle("Someone@Example.com", "someone@example.com"))
    #expect(!FaceTimeHandOff.sameHandle("+12025550100", "+12025550101"))
    // Not by number format alone: the callee is one of ours however it is spelled.
    let members = [member("(202) 555-0100"), member("+12025550101")]
    #expect(FaceTimeHandOff.mayLeave(members: members, dialledAddresses: ["+12025550100"]))
  }

  @Test("An answered incoming call needs any two active remotes")
  func incomingCallCountsRemotes() {
    #expect(!FaceTimeHandOff.mayLeave(members: [member("a@example.com")], dialledAddresses: []))
    #expect(
      FaceTimeHandOff.mayLeave(
        members: [member("a@example.com"), member("b@example.com")], dialledAddresses: []))
  }

  // MARK: - What the watcher claims
  //
  // The leave was a `try?` followed by an unconditional "the Mac left the call", and a failed
  // membership read was `?? []`, which is "nobody joined". Both told a person something about
  // a live call that was not true. These drive `run` against a helper double, with the real
  // timeout, poll interval and leave grace, on a test clock that skips every wait.

  /// Runs the watcher on an incoming call, keeping every log line and every wait it asked for.
  private func runHandOff(
    _ api: FailingPrivateAPI, clock: TestClock = TestClock(skipsSleeps: true)
  ) async -> (FaceTimeHandOff.Outcome, [String]) {
    let lines = OSAllocatedUnfairLock(initialState: [String]())
    let outcome = await FaceTimeHandOff.run(
      api: api, callUUID: "CALL-1", conversationUUID: "CONVERSATION-1", dialledAddresses: [],
      logger: Logger(label: "test") { _ in CapturedLines(lines: lines) }, clock: clock
    )
    return (outcome, lines.withLock { $0 })
  }

  private var twoRemotes: @Sendable (String) async throws -> [FaceTimeMember] {
    { _ in
      [
        FaceTimeMember(
          handle: FaceTimeHandle(value: "a@example.com", displayName: nil),
          isPending: false, isActive: true, isLightweight: false),
        FaceTimeMember(
          handle: FaceTimeHandle(value: "temp:guest", displayName: nil),
          isPending: false, isActive: true, isLightweight: true),
      ]
    }
  }

  @Test("A refused leave is not logged as the Mac leaving, and the timeout names the refusal")
  func refusedLeaveIsNotClaimed() async {
    var api = FailingPrivateAPI()
    api.onFaceTimeMembers = twoRemotes
    // `onLeaveCall` nil: every leave throws.
    let clock = TestClock(skipsSleeps: true)
    let (outcome, lines) = await runHandOff(api, clock: clock)

    #expect(outcome == .stayed(.leaveRefused))
    #expect(!lines.contains { $0.contains("left the call") }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("warning") && $0.contains("could not leave") })
    // Every poll waits out the grace before it asks to leave, then the interval, and the
    // watcher keeps asking until the deadline rather than giving up after one refusal.
    let cycle = [FaceTimeHandOff.leaveGrace, FaceTimeHandOff.pollInterval]
    #expect(Array(clock.waits.prefix(4)) == cycle + cycle)
    #expect(clock.now.offset >= FaceTimeHandOff.timeout)
  }

  @Test("A membership read that fails is not reported as nobody joining")
  func unreadableMembershipIsNotAnEmptyCall() async {
    // `onFaceTimeMembers` nil: every read throws.
    let clock = TestClock(skipsSleeps: true)
    let (outcome, lines) = await runHandOff(FailingPrivateAPI(), clock: clock)

    #expect(outcome == .stayed(.membershipUnreadable))
    #expect(!lines.contains { $0.contains("before the client joined") }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("warning") && $0.contains("could not be read") })
    // Asked again every interval until the deadline, not abandoned on the first failure.
    #expect(clock.waits.allSatisfy { $0 == FaceTimeHandOff.pollInterval })
    #expect(clock.now.offset == FaceTimeHandOff.timeout)
  }

  @Test("A leave that succeeds is still reported as one")
  func successfulLeaveIsClaimed() async {
    var api = FailingPrivateAPI()
    api.onFaceTimeMembers = twoRemotes
    api.onLeaveCall = { _ in }
    let clock = TestClock(skipsSleeps: true)
    let (outcome, lines) = await runHandOff(api, clock: clock)

    #expect(outcome == .left)
    #expect(lines.contains { $0.contains("the Mac left the call") })
    #expect(clock.waits == [FaceTimeHandOff.leaveGrace], "the newest member was given no grace")
  }

  @Test("A call that ends is reported as ended, with nothing admitted or left")
  func endedCallStopsTheWatcher() async {
    var api = FailingPrivateAPI()
    api.onFaceTimeCallStatus = { _ in .disconnected }
    api.onFaceTimeMembers = twoRemotes
    api.onLeaveCall = { _ in Issue.record("the watcher left a call that had ended") }
    let clock = TestClock(skipsSleeps: true)
    let (outcome, _) = await runHandOff(api, clock: clock)

    #expect(outcome == .callEnded)
    #expect(clock.waits.isEmpty)
  }

  @Test("Cancelling the watcher between polls ends it as cancelled, not as a timeout")
  func cancellationStopsTheWatcher() async throws {
    // `onFaceTimeMembers` nil, so the watcher parks on its poll interval after the first read.
    let clock = TestClock()
    let watcher = Task { await runHandOff(FailingPrivateAPI(), clock: clock) }
    try await clock.waitForSleepers(1)
    watcher.cancel()
    let (outcome, lines) = await watcher.value

    #expect(outcome == .cancelled)
    #expect(!lines.contains { $0.hasPrefix("warning") }, "\(lines)")
  }
}

/// Keeps every line logged, prefixed with its level.
private struct CapturedLines: LogHandler {
  let lines: OSAllocatedUnfairLock<[String]>
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .trace
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }
  func log(event: LogEvent) {
    lines.withLock { $0.append("\(event.level): \(event.message)") }
  }
}

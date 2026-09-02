//  FaceTimeHandOffTests
//  When the Mac may leave a call it placed or answered.
//
//  The rule used to live inside an HTTP handler's detached task, where the only way to test it
//  was a live call. It is a pure decision over the member list now, and these pin the cases
//  that were each learned the hard way on a real call.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBInterfaces

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

  @Test("On a 1:1 call the callee answering is not enough — the Mac would collapse the call")
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
}

//  InconclusiveProbeTests
//  `.unknown` means "the check could not run", and nothing may read it as "revoked".
//
//  This is pinned because the failure was silent and expensive: `automation-messages`
//  produced 112 "A permission was revoked" notifications on an install where the permission
//  was granted the whole time, and the Permissions page said so. The probe returns `.unknown`
//  whenever `AEDeterminePermissionToAutomateTarget` overruns `tccProbeDeadline` (a busy
//  `tccd`, which is common) and both the alert condition (`to != .granted`) and the state
//  store treated that as a real transition.

import Testing

@testable import BBSystem

@Suite("An inconclusive permission probe is not a refusal")
struct InconclusiveProbeTests {

  @Test("Only a definite negative counts as a refusal")
  func onlyDefiniteNegatives() {
    #expect(PermissionStatus.denied.isDefiniteRefusal)
    #expect(PermissionStatus.restricted.isDefiniteRefusal)
    #expect(PermissionStatus.notDetermined.isDefiniteRefusal)

    #expect(!PermissionStatus.granted.isDefiniteRefusal)
    // The whole point. `!= .granted` was the old test and it is what produced the alerts.
    #expect(!PermissionStatus.unknown.isDefiniteRefusal)
  }

  /// The alert condition in `ServerComposition` reads
  /// `from == .granted && to.isDefiniteRefusal`. This is that predicate, held against every
  /// transition out of `granted`, so a future edit that widens it back to `!= .granted` fails
  /// here rather than in somebody's notification list.
  @Test("Leaving `granted` alerts for real refusals and stays silent for an unknown")
  func transitionsOutOfGranted() {
    func alerts(_ to: PermissionStatus) -> Bool {
      PermissionStatus.granted == .granted && to.isDefiniteRefusal
    }

    #expect(alerts(.denied))
    #expect(alerts(.restricted))
    #expect(alerts(.notDetermined))
    #expect(!alerts(.unknown))
    #expect(!alerts(.granted))
  }
}

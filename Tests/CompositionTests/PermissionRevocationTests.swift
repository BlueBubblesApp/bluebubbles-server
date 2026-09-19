//  PermissionRevocationTests
//  A permission taken away while the server runs has to reach the user.
//
//  Starting without Full Disk Access is onboarding's problem and every screen already says so.
//  LOSING it mid-run was a different event and reached nobody: the monitor re-checked on a
//  timer and raised nothing, the only consumers of `unsatisfiedRequired` were SwiftUI views,
//  and headless there is not even a badge. `ChangeDetector` logged "Poll failed" twice a
//  minute for ever while messages silently stopped arriving.
//
//  macOS does this on its own — a point update resets TCC, and moving, replacing or re-signing
//  the app invalidates the grant — so it is not a hypothetical. It is the most likely real
//  failure this server meets.

import BBServiceKit
import BBSystem
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Permission revocation")
struct PermissionRevocationTests {

  private static let required = Permission(
    id: .fullDiskAccess,
    title: "Full Disk Access",
    why: "Read your Messages database",
    requirement: .required,
    requiresRelaunch: true
  )
  private static let recommended = Permission(
    id: .contacts,
    title: "Contacts",
    why: "Show names instead of phone numbers",
    requirement: .recommended
  )
  private static let feature = Permission(
    id: .automationMessages,
    title: "Automation → Messages",
    why: "Send messages without the Private API",
    requirement: .feature("Sending without the Private API")
  )
  private static let catalogue = [required, recommended, feature]

  private func revoked(
    _ before: [PermissionID: PermissionStatus],
    _ now: [PermissionID: PermissionStatus]
  ) -> [PermissionID] {
    PermissionsMonitorService.revoked(from: before, to: now, in: Self.catalogue).map(\.id)
  }

  @Test("A required permission going from granted to denied is reported")
  func grantedToDeniedIsReported() {
    #expect(revoked([.fullDiskAccess: .granted], [.fullDiskAccess: .denied]) == [.fullDiskAccess])
  }

  @Test("Restricted counts too, because no prompt will help")
  func restrictedIsReported() {
    // MDM or parental controls. The user still needs telling; what they can do about it is
    // different, which is the alert body's job rather than this decision's.
    #expect(
      revoked([.fullDiskAccess: .granted], [.fullDiskAccess: .restricted]) == [.fullDiskAccess])
  }

  @Test("A permission that was never granted is not a revocation")
  func stillMissingIsNotReported() {
    // The state a server that has never been set up sits in. Reporting it here would put a
    // critical alert on top of onboarding, every sixty seconds.
    #expect(revoked([.fullDiskAccess: .denied], [.fullDiskAccess: .denied]).isEmpty)
    #expect(revoked([.fullDiskAccess: .notDetermined], [.fullDiskAccess: .denied]).isEmpty)
  }

  @Test("The first broadcast reports nothing, whatever it says")
  func noPreviousReadingIsNotARevocation() {
    // With no prior reading there is no transition, only a state. Without this the check that
    // runs at start would report every ungranted permission as freshly taken away.
    #expect(revoked([:], [.fullDiskAccess: .denied]).isEmpty)
  }

  @Test("A probe that could not run is not a revocation")
  func unknownIsNotARefusal() {
    // `.unknown` means the check failed, not that anything changed. Treating it as a refusal
    // would raise a false outage at exactly the moment the machine is already struggling —
    // which is why `PermissionStatus.isDefiniteRefusal` exists rather than `!= .granted`.
    #expect(revoked([.fullDiskAccess: .granted], [.fullDiskAccess: .unknown]).isEmpty)
  }

  @Test("Recovering is not a revocation")
  func regrantedIsNotReported() {
    #expect(revoked([.fullDiskAccess: .denied], [.fullDiskAccess: .granted]).isEmpty)
  }

  @Test("Only required permissions raise this alert")
  func onlyRequiredIsReported() {
    // A recommended or feature permission degrades something specific, and the screen for
    // that feature says so. A critical alert for each would teach people to dismiss the one
    // that means messages have stopped arriving.
    #expect(revoked([.contacts: .granted], [.contacts: .denied]).isEmpty)
    #expect(revoked([.automationMessages: .granted], [.automationMessages: .denied]).isEmpty)
  }

  @Test("Two revocations in one broadcast are both reported")
  func severalAtOnce() {
    // A TCC reset takes everything at once, which is the common case rather than a corner.
    let all = [
      Self.required,
      Permission(
        id: .systemIntegrityProtection, title: "System Integrity Protection",
        why: "Load the Private API helper", requirement: .required),
    ]
    let reported = PermissionsMonitorService.revoked(
      from: [.fullDiskAccess: .granted, .systemIntegrityProtection: .granted],
      to: [.fullDiskAccess: .denied, .systemIntegrityProtection: .denied],
      in: all
    )
    #expect(Set(reported.map(\.id)) == [.fullDiskAccess, .systemIntegrityProtection])
  }
}

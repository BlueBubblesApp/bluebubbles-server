//  PermissionGuidanceTests
//  What the Permissions page calls each state, and what it tells someone to do.
//
//  The advice is the feature: "Grant this permission" tells someone nothing, and the two
//  facts that actually unstick people — that macOS never prompts for Full Disk Access, and
//  that it never re-prompts for anything once denied — are the ones worth pinning.

import BBServiceKit
import BBSystem
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Permission guidance")
struct PermissionGuidanceTests {

  /// Listed rather than derived: `PermissionStatus` is not `CaseIterable` and `PermissionID`
  /// is a `RawRepresentable` struct, not an enum, so a manifest can declare one this app has
  /// never heard of. Both lists are the ones the page actually renders.
  private static let statuses: [PermissionStatus] = [
    .granted, .denied, .restricted, .notDetermined, .unknown,
  ]
  private static let ids: [PermissionID] = [
    .fullDiskAccess, .automationMessages, .contacts, .notifications,
    .systemIntegrityProtection,
  ]

  private func permission(_ id: PermissionID, why: String = "Because.") -> Permission {
    Permission(id: id, title: "Title", why: why, requirement: .required)
  }

  @Test("Every state has its own word, and they are all distinct")
  func labels() {
    let labels = Self.statuses.map(PermissionGuidance.statusLabel)
    #expect(Set(labels).count == labels.count, "two states read the same: \(labels)")
  }

  /// "Not set" and "Unknown" are different answers: the first is a permission nobody has
  /// been asked for, the second is one the probe could not determine at all, which for
  /// Automation means Messages.app was not found.
  @Test("Not-determined and unknown are not the same word")
  func notSetIsNotUnknown() {
    #expect(PermissionGuidance.statusLabel(.notDetermined) == "Not set")
    #expect(PermissionGuidance.statusLabel(.unknown) == "Unknown")
  }

  /// The fact that unsticks Full Disk Access: macOS will not prompt, so waiting for a
  /// dialog is waiting forever. The advice says so whatever the current state.
  @Test("Full Disk Access always says macOS will not prompt")
  func fullDiskAccessNeverPrompts() {
    for status in Self.statuses {
      let text = PermissionGuidance.guidance(
        for: permission(.fullDiskAccess), status: status)
      #expect(text.contains("will not prompt"))
      #expect(text.contains("relaunch"), "the relaunch requirement is the other half")
    }
  }

  /// Once denied, macOS never asks again, so "allow the prompt" is advice for a prompt that
  /// will not come. This is the one branch that depends on the state.
  @Test("A denied permission is told it must be re-enabled by hand")
  func deniedSaysByHand() {
    let denied = PermissionGuidance.guidance(
      for: permission(.automationMessages), status: .denied)
    #expect(denied.contains("will not ask again"))

    let notDetermined = PermissionGuidance.guidance(
      for: permission(.automationMessages), status: .notDetermined)
    #expect(!notDetermined.contains("will not ask again"))
  }

  /// A permission with no special case falls back to the manifest's own sentence, which is
  /// the reason a service author wrote for it — not a generic one.
  @Test("An ordinary permission falls back to its own stated reason")
  func fallsBackToWhy() {
    let text = PermissionGuidance.guidance(
      for: permission(.contacts, why: "so it can name your conversations"),
      status: .notDetermined)
    #expect(text == "so it can name your conversations")
  }

  @Test("An ordinary permission, once denied, also says macOS will not ask again")
  func fallbackDeniedBranch() {
    let text = PermissionGuidance.guidance(
      for: permission(.contacts, why: "so it can name your conversations"), status: .denied)
    #expect(text.contains("will not ask again"))
  }

  @Test("Every permission and state produces something to read")
  func nothingIsBlank() {
    for id in Self.ids {
      for status in Self.statuses {
        #expect(
          !PermissionGuidance.guidance(for: permission(id), status: status).isEmpty,
          "\(id) / \(status) says nothing")
      }
    }
  }
}

//  PermissionGuidanceTests
//  What the Permissions page calls each state, and what it tells someone to do.
//
//  The advice is the feature: "Grant this permission" tells someone nothing, and the two
//  facts that actually unstick people — that macOS never prompts for Full Disk Access, and
//  that it never re-prompts for anything once denied — are the ones worth pinning.

import BBServiceKit
import BBSystem
import BBTestSupport
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

  /// A dialog on arrival is one nobody asked for, over a step they are still reading. The row's
  /// button is the only way the step asks, so it has to be there for Contacts.
  @Test("The onboarding step asks through its rows' buttons and never by itself")
  func theStepWaitsForTheButton() async throws {
    let step = try SourceScanner.file(
      "Sources/BlueBubblesApp/Views/Onboarding/OnboardingSteps.swift"
    ).text
    #expect(step.contains("PermissionRow("))
    #expect(!step.contains("permissions.request("))
    let contacts = await PermissionsService().permissions.first { $0.id == .contacts }
    #expect(contacts?.canPrompt == true)
  }

  /// Passing the button has to leave a way back, on a Mac that may not start again for weeks.
  @Test("Finishing setup tells the server, which raises the notice for an unanswered Contacts")
  func finishingSetupRaisesTheNotice() throws {
    let view = try SourceScanner.file(
      "Sources/BlueBubblesApp/Views/Onboarding/OnboardingView.swift"
    ).text
    #expect(view.contains("await model.server?.setupFinished()"))
    let server = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition+RunningServer.swift"
    ).text
    #expect(server.contains("public func setupFinished() async"))
  }

  @Test("What a service is missing, required and recommended, once somebody knows")
  func unmet() {
    let list = [
      Permission(id: .fullDiskAccess, title: "Disk", why: "", requirement: .required),
      Permission(id: .contacts, title: "Contacts", why: "", requirement: .recommended),
      Permission(id: .systemIntegrityProtection, title: "SIP", why: "", requirement: .required),
    ]
    let manifest = ServiceManifest.minimal(
      id: "subject",
      permissions: [
        .init(.fullDiskAccess, .required, purpose: "so it can read"),
        .init(.contacts, .recommended, purpose: "so it can name"),
        .init(.systemIntegrityProtection, .feature("Tapbacks"), purpose: "so it can inject"),
      ])

    func ids(_ statuses: [PermissionID: PermissionStatus]) -> [PermissionID] {
      PermissionGuidance.unmet(by: manifest, in: list, statuses: statuses).map(\.id)
    }

    #expect(
      ids([
        .fullDiskAccess: .denied, .contacts: .notDetermined, .systemIntegrityProtection: .denied,
      ])
        == [.fullDiskAccess, .contacts],
      "a .feature permission is one named thing, and this page runs without it")
    #expect(ids([.fullDiskAccess: .granted, .contacts: .granted]).isEmpty)
    // Neither a status not read yet nor a probe that could not run says anything is missing.
    #expect(ids([:]).isEmpty)
    #expect(ids([.fullDiskAccess: .unknown]).isEmpty)
  }

  @Test("Waiting on a permission means a required one")
  func awaitingRequired() {
    let manifest = ServiceManifest.minimal(
      id: "subject",
      permissions: [
        .init(.fullDiskAccess, .required, purpose: "so it can read"),
        .init(.contacts, .recommended, purpose: "so it can name"),
      ])
    #expect(PermissionGuidance.isAwaitingRequired(manifest, statuses: [.fullDiskAccess: .denied]))
    #expect(
      !PermissionGuidance.isAwaitingRequired(
        manifest, statuses: [.fullDiskAccess: .granted, .contacts: .denied]),
      "Contacts gates nothing, so this service is not waiting on it")
    #expect(!PermissionGuidance.isAwaitingRequired(manifest, statuses: [.fullDiskAccess: .unknown]))
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

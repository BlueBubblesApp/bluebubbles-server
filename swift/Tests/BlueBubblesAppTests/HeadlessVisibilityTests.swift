//  HeadlessVisibilityTests
//  A headless server must still be visible in the menu bar.
//
//  REGRESSION TEST. The headless launch used `.prohibited`, which suppresses the Dock icon AND
//  every other way an app presents itself — including `MenuBarExtra`. A headless server ran
//  with no indication at all that it was running: no Dock icon, no status item, and nothing to
//  click to stop it. `.accessory` is what "no Dock icon" means, and it is the same policy the
//  `hide_dock_icon` setting already used.

import AppKit
import Testing

@testable import BlueBubblesApp

@Suite("Headless visibility")
@MainActor
struct HeadlessVisibilityTests {

  /// The policy the headless launch must use. `.prohibited` would hide the status item too.
  @Test("Headless uses accessory, which keeps the menu bar")
  func headlessPolicyKeepsMenuBar() {
    let policy = AppBehaviourPolicy.activationPolicy(headless: true)
    #expect(policy == .accessory)
    #expect(policy != .prohibited, "prohibited suppresses the status item as well")
  }

  /// Hiding the Dock icon and running headless are the same visual outcome, and were
  /// already the same policy in the settings path — the launch path was the odd one out.
  @Test("Hiding the Dock icon and headless agree")
  func dockHidingMatchesHeadless() {
    #expect(
      AppBehaviourPolicy.activationPolicy(headless: true)
        == AppBehaviourPolicy.activationPolicy(dockHidden: true)
    )
    #expect(AppBehaviourPolicy.activationPolicy(dockHidden: false) == .regular)
  }
}

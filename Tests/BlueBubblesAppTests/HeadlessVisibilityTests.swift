//  HeadlessVisibilityTests
//  A headless server must still be visible in the menu bar.
//
//  REGRESSION TEST. The headless launch used `.prohibited`, which suppresses the Dock icon AND
//  every other way an app presents itself, including `MenuBarExtra`. A headless server ran
//  with no indication at all that it was running: no Dock icon, no status item, and nothing to
//  click to stop it. `.accessory` is what "no Dock icon" means, and it is the same policy the
//  `hide_dock_icon` setting already used.

import AppKit
import Testing

@testable import BlueBubblesApp

@Suite("Headless visibility")
@MainActor
struct HeadlessVisibilityTests {

  /// The policy the headless launch and the hidden Dock icon both use. `.prohibited` would
  /// hide the status item too.
  @Test("A hidden Dock icon uses accessory, which keeps the menu bar")
  func hiddenDockKeepsMenuBar() {
    let policy = AppBehaviourPolicy.activationPolicy(dockHidden: true)
    #expect(policy == .accessory)
    #expect(policy != .prohibited, "prohibited suppresses the status item as well")
    #expect(AppBehaviourPolicy.activationPolicy(dockHidden: false) == .regular)
  }

  /// The decision `applyAppearance` makes, which is where the launch policy was being undone.
  ///
  /// The test above asserts a pure function the defect walked straight past: the launch
  /// set `.accessory` correctly and then the appearance step overwrote it from the setting
  /// alone. It would still have passed with the headless path deleted entirely.
  /// This one covers the combination, which is the thing that was wrong.
  @Test("A headless launch keeps the Dock icon hidden whatever the setting says")
  func headlessOutranksTheSetting() {
    #expect(
      AppBehaviourPolicy.shouldHideDockIcon(isHeadless: true, hideDockIconSetting: false),
      "a --headless run regained its Dock icon, with no window behind it")
    #expect(AppBehaviourPolicy.shouldHideDockIcon(isHeadless: true, hideDockIconSetting: true))
    #expect(AppBehaviourPolicy.shouldHideDockIcon(isHeadless: false, hideDockIconSetting: true))
    #expect(!AppBehaviourPolicy.shouldHideDockIcon(isHeadless: false, hideDockIconSetting: false))
  }
}

//  AppBehaviourPolicyTests
//  When the app locks the screen, delays a start, starts minimised or badges its icon.
//
//  `AppBehaviourPolicy` is an app type, so these assertions live with the app's tests rather
//  than in `CompositionTests`, which does not link the SwiftUI app.

import Testing

@testable import BlueBubblesApp

@Suite("App behaviour settings")
struct AppBehaviourPolicyTests {

  @Test("Locking happens only just after a reboot")
  func lockOnlyNearBoot() {
    // The rule the Electron server has and this reproduces. Without the uptime test the
    // setting would lock the screen every time the server started, including when the
    // person sitting in front of it pressed Start. It exists for a headless Mac that came
    // back from a power cut to an unlocked desktop.
    #expect(AppBehaviourPolicy.shouldLock(enabled: true, uptime: 30))
    #expect(AppBehaviourPolicy.shouldLock(enabled: true, uptime: 300))
    #expect(!AppBehaviourPolicy.shouldLock(enabled: true, uptime: 301))
    #expect(!AppBehaviourPolicy.shouldLock(enabled: true, uptime: 86_400))
  }

  @Test("Locking never happens when the setting is off")
  func lockRespectsTheSetting() {
    #expect(!AppBehaviourPolicy.shouldLock(enabled: false, uptime: 10))
  }

  @Test("The startup delay applies to an unattended start only")
  func delayIsForUnattendedStarts() {
    // A delay on a button press is a button that appears not to work, and a delay on an
    // app somebody just double-clicked is the same thing: they watched "Starting in 30s…"
    // for half a minute. The setting exists so a LOGIN can let the network or an external
    // disk come up first, which is the only case the launcher's argument marks.
    #expect(AppBehaviourPolicy.startDelay(30, isUnattended: true) == .seconds(30))
    #expect(AppBehaviourPolicy.startDelay(30, isUnattended: false) == nil)
  }

  @Test("A zero or negative delay is no delay at all")
  func noDelay() {
    #expect(AppBehaviourPolicy.startDelay(0, isUnattended: true) == nil)
    #expect(AppBehaviourPolicy.startDelay(-5, isUnattended: true) == nil)
  }

  @Test("The delay is clamped to what the setting allows")
  func delayIsClamped() {
    // `start_delay` validates 0-600 on write, but a value can arrive from a migrated
    // Electron config or a `--set` override without passing through that check.
    #expect(AppBehaviourPolicy.startDelay(9_999, isUnattended: true) == .seconds(600))
  }

  @Test("Starting minimised needs the setting, an unattended launch, and no setup waiting")
  func minimizeIsForUnattendedStarts() {
    #expect(
      AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: true, isAwaitingSetup: false))
    // Off is off.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: false, isUnattended: true, isAwaitingSetup: false))
    // A person who just opened the app is watching it. A window that minimises itself in
    // front of them reads as a crash, which is what was reported.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: false, isAwaitingSetup: false))
    // And setup outranks the preference in both directions: onboarding and the migration
    // wizard are sheets ON the main window, so minimising hides a modal dialogue that is
    // waiting for an answer.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: true, isAwaitingSetup: true))
  }

  @Test("A zero badge shows nothing rather than a zero")
  func badgeHidesZero() {
    // A permanent "0" trains people to stop reading the badge: the same reasoning the
    // sidebar badges use.
    #expect(AppBehaviourPolicy.badgeLabel(count: 0, enabled: true) == nil)
    #expect(AppBehaviourPolicy.badgeLabel(count: 3, enabled: true) == "3")
    #expect(AppBehaviourPolicy.badgeLabel(count: 3, enabled: false) == nil)
  }
}

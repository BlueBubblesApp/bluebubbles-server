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
        configured: true, isUnattended: true, isHeadless: false, isAwaitingSetup: false))
    // Off is off.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: false, isUnattended: true, isHeadless: false, isAwaitingSetup: false))
    // A person who just opened the app is watching it. A window that minimises itself in
    // front of them reads as a crash, which is what was reported.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: false, isHeadless: false, isAwaitingSetup: false))
    // And setup outranks the preference in both directions: onboarding and the migration
    // wizard are sheets ON the main window, so minimising hides a modal dialogue that is
    // waiting for an answer.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: true, isHeadless: false, isAwaitingSetup: true))
  }

  @Test("A headless launch never minimises the window it is about to close")
  func headlessIsNotMinimised() {
    // `closeMainWindow` passes over a window that is not visible, and a minimised one is not,
    // so a minimise that got in first would leave a window behind.
    #expect(
      !AppBehaviourPolicy.shouldStartMinimized(
        configured: true, isUnattended: true, isHeadless: true, isAwaitingSetup: false))
  }

  @Test("The window needs a person for a failure, the migration gate and either setup sheet")
  func windowNeedsPerson() {
    func needs(_ phase: ServerPhase, migration: Bool = false, onboarding: Bool = false) -> Bool {
      AppBehaviourPolicy.mainWindowNeedsPerson(
        phase: phase, isMigrationPresented: migration, isOnboardingPresented: onboarding)
    }
    #expect(needs(.failed("the database is busy")))
    #expect(needs(.migrationRequired))
    #expect(needs(.running, migration: true))
    #expect(needs(.running, onboarding: true))
    // A sheet counts during a start as well: `start` can be in flight when one opens.
    #expect(needs(.starting, onboarding: true))
    // Nothing on these asks anything of the window. A minimised window sits through the
    // startup delay on purpose: the delay is for a start nobody is watching.
    for phase in [ServerPhase.idle, .starting, .waiting(.seconds(30)), .running, .stopping] {
      #expect(!needs(phase), "\(phase.label) must not bring a minimised window back")
    }
  }

  @Test("What starting minimised does next, for every state it can be in")
  func startMinimisedSteps() {
    func step(
      _ state: AppBehaviourPolicy.StartMinimised, needsPerson: Bool
    ) -> AppBehaviourPolicy.StartMinimisedStep? {
      AppBehaviourPolicy.startMinimisedStep(state, windowNeedsPerson: needsPerson)
    }
    #expect(step(.awaitingWindow, needsPerson: false) == .minimise)
    #expect(step(.awaitingWindow, needsPerson: true) == .forget)
    #expect(step(.minimised, needsPerson: true) == .restore)
    #expect(step(.minimised, needsPerson: false) == nil)
    // Whatever is on the window, nothing here reaches a window this path does not answer for.
    #expect(step(.nothingOwed, needsPerson: true) == nil)
    #expect(step(.nothingOwed, needsPerson: false) == nil)
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

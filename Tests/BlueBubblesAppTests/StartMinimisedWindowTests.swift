//  StartMinimisedWindowTests
//  Minimising as soon as the setting is known, without hiding what comes after.
//
//  The window is a fake: `StartMinimisedWindow` takes its two AppKit calls as closures, and a
//  test process has no window server to minimise anything on. So these pin the state between
//  the decision and the calls, and the scans below pin WHERE in a start `AppModel` makes them,
//  because `AppModel.start` opens two databases and binds a port and cannot run here. Neither
//  proves what AppKit does with the calls; that needs a launch from the login item.

import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

/// A window that can be absent, and that a person can take back.
@MainActor
private final class FakeWindow {
  var isOnScreen = true
  private(set) var minimiseCount = 0
  private(set) var restoreCount = 0
  private var onTakenBack: (@MainActor () -> Void)?

  func tracker() -> StartMinimisedWindow {
    StartMinimisedWindow(
      minimise: { [self] taken in
        guard isOnScreen else { return false }
        minimiseCount += 1
        onTakenBack = taken
        return true
      },
      restore: { [self] in restoreCount += 1 })
  }

  /// What the Dock icon, the menu bar's Open or closing the window comes to.
  func personTakesItBack() { onTakenBack?() }
}

@Suite("Starting minimised")
@MainActor
struct StartMinimisedWindowTests {

  @Test("A window on screen is minimised as soon as it is asked for")
  func minimisesAtOnce() {
    let window = FakeWindow()
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    #expect(window.minimiseCount == 1)
    #expect(tracker.state == .minimised)
    // Every phase change reconciles, and none of them minimises it a second time.
    tracker.reconcile(windowNeedsPerson: false)
    #expect(window.minimiseCount == 1)
  }

  @Test("A decision made before the window appears waits for it")
  func waitsForTheWindow() {
    // Storage can open before AppKit has shown the window. This is the case that would
    // otherwise be a setting that silently does nothing.
    let window = FakeWindow()
    window.isOnScreen = false
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    #expect(tracker.state == .awaitingWindow)
    #expect(window.minimiseCount == 0)

    window.isOnScreen = true
    tracker.reconcile(windowNeedsPerson: false)
    #expect(window.minimiseCount == 1)
    #expect(tracker.state == .minimised)
  }

  @Test("A start that fails brings back the window it minimised")
  func failureRestores() {
    let window = FakeWindow()
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    tracker.reconcile(windowNeedsPerson: true)
    #expect(window.restoreCount == 1)
    #expect(tracker.state == .nothingOwed)
    // Restored once: the failure is still there on the next change, and the window is the
    // person's from here.
    tracker.reconcile(windowNeedsPerson: true)
    #expect(window.restoreCount == 1)
  }

  @Test("A failure before the window appeared cancels the minimise rather than performing it")
  func failureCancelsAWaitingMinimise() {
    let window = FakeWindow()
    window.isOnScreen = false
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    tracker.reconcile(windowNeedsPerson: true)
    #expect(tracker.state == .nothingOwed)

    // The window arrives to show the failure, and stays up.
    window.isOnScreen = true
    tracker.reconcile(windowNeedsPerson: true)
    #expect(window.minimiseCount == 0)
    #expect(window.restoreCount == 0)
  }

  @Test("A window the person took back is never restored again")
  func takenBackIsThePersons() {
    // They un-minimised it, then minimised it themselves. A failure later must leave it where
    // they put it, however much it looks like the window this path minimised.
    let window = FakeWindow()
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    window.personTakesItBack()
    #expect(tracker.state == .nothingOwed)
    tracker.reconcile(windowNeedsPerson: true)
    #expect(window.restoreCount == 0)
  }

  @Test("Nothing asked for means nothing touched")
  func neverAsked() {
    let window = FakeWindow()
    let tracker = window.tracker()
    tracker.reconcile(windowNeedsPerson: true)
    tracker.reconcile(windowNeedsPerson: false)
    tracker.settle(windowNeedsPerson: true)
    #expect(window.minimiseCount == 0)
    #expect(window.restoreCount == 0)
  }

  @Test("The end of a start is the last attempt, and a window opened after it stays open")
  func settleIsTheLastAttempt() {
    let window = FakeWindow()
    window.isOnScreen = false
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    tracker.settle(windowNeedsPerson: false)
    #expect(tracker.state == .nothingOwed)

    // Somebody opened it from the menu bar, and it must not minimise in front of them.
    window.isOnScreen = true
    tracker.reconcile(windowNeedsPerson: false)
    #expect(window.minimiseCount == 0)
  }

  @Test("The end of a start still minimises a window that has appeared")
  func settleMinimises() {
    let window = FakeWindow()
    window.isOnScreen = false
    let tracker = window.tracker()
    tracker.request(windowNeedsPerson: false)
    window.isOnScreen = true
    tracker.settle(windowNeedsPerson: false)
    #expect(window.minimiseCount == 1)
    #expect(tracker.state == .minimised)
  }

  // MARK: - The model's wiring

  @Test("Opening the Setup Assistant brings the window back")
  func onboardingSheetRestores() {
    // "Setup Assistant…" is in the app menu, which works with the window in the Dock, and
    // "Reset and Start Over" reaches the same sheet.
    let window = FakeWindow()
    let tracker = window.tracker()
    let model = AppModel(startMinimisedWindow: tracker)
    tracker.request(windowNeedsPerson: false)
    model.onboarding.present()
    #expect(window.restoreCount == 1)
  }

  @Test("Opening the migration wizard brings the window back")
  func migrationSheetRestores() {
    let window = FakeWindow()
    let tracker = window.tracker()
    let model = AppModel(startMinimisedWindow: tracker)
    tracker.request(windowNeedsPerson: false)
    model.migration.present()
    #expect(window.restoreCount == 1)
  }

  // MARK: - Where in a start it happens

  private static func appModelCode() throws -> String {
    try SourceScanner.file("Sources/BlueBubblesApp/AppModel.swift").code
  }

  /// The code from one function's signature to the signature of the function named after it.
  private static func body(of signature: String, endingAt next: String) throws -> Substring {
    let source = try appModelCode()
    let start = try #require(source.range(of: signature))
    let end = try #require(source[start.upperBound...].range(of: next))
    return source[start.upperBound..<end.lowerBound]
  }

  @Test("The decision sits between the migration gate and building the composition")
  func decidedAfterTheGate() throws {
    let start = try Self.body(
      of: "private func start(isUnattended", endingAt: "private func openStorage")
    let gate = try #require(start.range(of: "openStorage(options"))
    let decision = try #require(start.range(of: "decideStartMinimised("))
    let build = try #require(start.range(of: "assemble(storage"))
    #expect(gate.upperBound <= decision.lowerBound, "before the gate, a sheet can still come")
    #expect(
      decision.upperBound <= build.lowerBound,
      "the composition and the startup delay are what this exists not to wait for")
  }

  @Test("Locking and FindMy stay behind the running phase, and minimising does not")
  func onlyMinimisingMoved() throws {
    let source = try Self.appModelCode()
    let running = try #require(source.range(of: "phase = .running"))
    let applied = try #require(source.range(of: "await applyStartupBehaviour("))
    #expect(running.upperBound <= applied.lowerBound, "locking must follow a start that worked")

    let behaviour = try Self.body(
      of: "private func applyStartupBehaviour", endingAt: "func applyAppearance")
    #expect(behaviour.contains("shouldLock("))
    #expect(behaviour.contains("shouldOpenFindMy("))
    #expect(!behaviour.contains("shouldStartMinimized("))
    #expect(behaviour.contains("settle("), "a window that appeared late has one more attempt")
  }

  @Test("A failed start reaches the window through the phase")
  func phaseChangesReconcile() throws {
    let source = try Self.appModelCode()
    let phase = try #require(source.range(of: "private(set) var phase: ServerPhase"))
    let declaration = source[phase.upperBound...].prefix(80)
    #expect(
      declaration.contains("reconcileMainWindow()"),
      "`.failed` and `.migrationRequired` are told to nothing else")
  }

  @Test("The window's task picks up a decision made before it appeared")
  func windowTaskReconciles() throws {
    let entry = try SourceScanner.file("Sources/BlueBubblesApp/BlueBubblesApp.swift").code
    #expect(entry.contains("model.reconcileMainWindow()"))
  }
}

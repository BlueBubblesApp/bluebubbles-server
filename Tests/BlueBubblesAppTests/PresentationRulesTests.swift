//  PresentationRulesTests
//  The small decisions the shared components draw, each moved off a view so it could be
//  stated here: the one tone vocabulary, an action's outcome, where the client address
//  points, what the Private API card and a migration step say.

import BBCore
import BlueBubblesServerCore
import Testing

@testable import BlueBubblesApp

@Suite("Presentation rules")
@MainActor
struct PresentationRulesTests {

  // MARK: - Tones

  /// The sidebar and Home used to disagree: a starting server was a warning in one and
  /// unknown in the other. Nothing is wrong during a start, so it is not coloured.
  @Test("A server on its way up or down is not a warning")
  func phaseTones() {
    #expect(ServerPhase.running.tone == .good)
    #expect(ServerPhase.failed("x").tone == .problem)
    #expect(ServerPhase.migrationRequired.tone == .attention)
    for phase in [ServerPhase.idle, .starting, .waiting(.seconds(3)), .stopping] {
      #expect(phase.tone == .informational, "\(phase)")
    }
  }

  @Test("Each tone has one symbol, and only the informational one is uncoloured")
  func toneSymbols() {
    let tones: [StatusTone] = [.informational, .good, .attention, .problem]
    #expect(Set(tones.map(\.symbol)).count == tones.count)
  }

  @Test("An alert's severity maps onto the same tones")
  func severityTones() {
    #expect(StatusTone(Severity.critical) == .problem)
    #expect(StatusTone(Severity.error) == .problem)
    #expect(StatusTone(Severity.warning) == .attention)
    #expect(StatusTone(Severity.success) == .good)
    #expect(StatusTone(Severity.info) == .informational)
  }

  // MARK: - Actions

  @Test("A cleanup that found nothing says so, and one that could not run says why")
  func cleanupOutcomes() {
    #expect(
      ActionOutcome.faceTimeCleanup(links: 0, calls: 0, alerts: 0, failure: nil)
        == .done("Nothing to clear."))
    let failed = ActionOutcome.faceTimeCleanup(
      links: 0, calls: 0, alerts: 0, failure: "FaceTime is not running")
    #expect(failed.isFailure)
    #expect(failed.text.contains("FaceTime is not running"))
    #expect(
      ActionOutcome.faceTimeCleanup(links: 2, calls: 1, alerts: 1, failure: nil)
        == .done("Cleared 2 links, left 1 call, dismissed a blocking alert."))
  }

  @Test("Only a failure is drawn as one")
  func outcomeTones() {
    #expect(ActionOutcome.done("x").tone == .informational)
    #expect(ActionOutcome.waiting("x").tone == .informational)
    #expect(!ActionOutcome.waiting("x").isFailure)
    #expect(ActionOutcome.failed("x").tone == .problem)
  }

  // MARK: - The client address

  /// `localhost` on a phone is the phone, so it is never what a person is told to type;
  /// it is only for a request made from this Mac.
  @Test("Only the from-this-Mac form falls back to localhost")
  func clientAddress() {
    #expect(ClientAddress.unknown.forThisMac == nil)
    #expect(ClientAddress(published: "", port: 1234).forThisMac == "http://localhost:1234")
    #expect(
      ClientAddress(published: "https://example.com", port: 1234).forThisMac
        == "https://example.com")
  }

  // MARK: - The Private API card

  @Test("Switched on is not working: a helper that has not called back is not 'connected'")
  func privateAPISummary() {
    let waiting = PrivateAPIStatusSummary(outcome: .running, isConnected: false)
    #expect(waiting.title == "Private API is waiting for the helper")
    #expect(waiting.tone == .informational)
    #expect(PrivateAPIStatusSummary(outcome: .running, isConnected: true).tone == .good)
    #expect(PrivateAPIStatusSummary(outcome: .timedOut, isConnected: false).tone == .attention)
    let failed = PrivateAPIStatusSummary(outcome: .failed("no SIP"), isConnected: false)
    #expect(failed.detail == "no SIP")
    #expect(failed.tone == .problem)
    #expect(PrivateAPIStatusSummary(outcome: nil, isConnected: false).tone == .informational)
  }

  // MARK: - Migration steps

  @Test("Only the step that deletes files asks first, and not on a retry")
  func migrationConfirmation() {
    #expect(MigrationStepPresentation(step: .plaintextSecrets, state: nil).confirmsFirst)
    #expect(!MigrationStepPresentation(step: .plaintextSecrets, state: .failed).confirmsFirst)
    #expect(!MigrationStepPresentation(step: .settings, state: nil).confirmsFirst)
    #expect(MigrationStepPresentation(step: .settings, state: .failed).primaryTitle == "Try Again")
    #expect(MigrationStepPresentation(step: .certificates, state: nil).primaryTitle == "Move")
  }

  /// Whether the old copy survives differs by step, and decides whether somebody can go
  /// back to the previous version.
  @Test("Every step says what happens to the old copy")
  func migrationExplanations() {
    for step in MigrationStep.allCases {
      let text = MigrationStepPresentation(step: step, state: nil).explanation
      #expect(
        text.contains("left exactly where it is") || text.contains("deleted")
          || text.contains("removed") || text.contains("cannot be undone"),
        "\(step) does not say what happens to the old copy")
    }
  }

  @Test("A step's glyph takes its outcome's tone, and the accent while it is an offer")
  func migrationTones() {
    #expect(MigrationStepPresentation(step: .settings, state: nil).tone == nil)
    #expect(MigrationStepPresentation(step: .settings, state: .completed).tone == .good)
    #expect(MigrationStepPresentation(step: .settings, state: .failed).tone == .problem)
  }
}

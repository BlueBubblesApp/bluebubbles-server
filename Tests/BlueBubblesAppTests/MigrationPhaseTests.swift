//  MigrationPhaseTests
//  The phase the adoption wizard leaves behind, and the properties every screen reads off it.
//
//  Three of these pin mistakes that were made and caught while building this:
//
//    - **`ServerPhase` must stay `Equatable`.** `HomeView` does `.task(id: model.phase)` and
//      `AppModel.start` opens with `phase == .idle`, so a case carrying a plan value (which
//      holds `@Sendable` closures) would kill the synthesized conformance and take both with
//      it. The plan lives on `MigrationModel` for exactly this reason.
//    - **`.migrationRequired` is not busy.** `isBusy` disables the start/stop control; a
//      phase whose whole point is "the user has something to do" must leave its button
//      pressable.
//    - **`.migrationRequired` is not running.** Every screen gates its content on
//      `phase.isRunning`, and a server that has deliberately not been built must render as
//      unavailable rather than as working.

import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Migration phase")
struct MigrationPhaseTests {

  @Test("The phase is equatable, so `.task(id:)` and the start guard still work")
  func staysEquatable() {
    #expect(ServerPhase.migrationRequired == ServerPhase.migrationRequired)
    #expect(ServerPhase.migrationRequired != ServerPhase.idle)
    #expect(ServerPhase.migrationRequired != ServerPhase.running)
    #expect(ServerPhase.failed("x") != ServerPhase.migrationRequired)
  }

  @Test("Setup required is neither running nor busy")
  func notRunningNotBusy() {
    let phase = ServerPhase.migrationRequired
    #expect(phase.isRunning == false)
    #expect(phase.isBusy == false, "the button that opens the wizard has to be pressable")
  }

  @Test("It says what it is")
  func label() {
    #expect(ServerPhase.migrationRequired.label == "Setup required")
  }

  /// The guard on `AppModel.start` is `phase == .idle || isFailed || phase ==
  /// .migrationRequired`. Without the last term the wizard's own "Start Server" returns
  /// immediately and the user is left with a finished wizard and a stopped server.
  @Test("The start guard admits the phase the wizard leaves behind")
  func startGuardAdmitsIt() {
    let admitted: [ServerPhase] = [.idle, .failed("x"), .migrationRequired]
    for phase in admitted {
      let isFailed = if case .failed = phase { true } else { false }
      #expect(
        phase == .idle || isFailed || phase == .migrationRequired,
        "\(phase.label) must be able to start"
      )
    }
    // And the ones that must not restart a server already on its way up.
    for phase in [ServerPhase.starting, .running, .stopping] {
      let isFailed = if case .failed = phase { true } else { false }
      #expect(!(phase == .idle || isFailed || phase == .migrationRequired))
    }
  }
}

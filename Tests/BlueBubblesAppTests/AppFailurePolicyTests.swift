//  AppFailurePolicyTests
//  Three app-layer rules that only bite on paths nobody exercises on purpose.
//
//  A `View` cannot be instantiated in a test process, so what is testable here is the
//  DECISION each of these rests on, plus a scan for the two that are structural. That split
//  is the app module's shape: the rules live outside the view precisely so they can be
//  checked.

import BBAuth
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("App failure policy")
struct AppFailurePolicyTests {

  // MARK: - Re-running the Setup Assistant

  @Test("An empty password field over a stored password is accepted")
  func keepingAnExistingPasswordIsAllowed() {
    // The case that made re-running the assistant destructive. Somebody opens it months
    // later to add a phone, walks through the connection step, and is required to type a
    // password: doing so disconnects every paired client, for a step they opened for an
    // unrelated reason.
    #expect(
      OnboardingRules.passwordRejection(typed: "", hasStoredPassword: true) == nil,
      "an empty field over an existing password means keep it"
    )
  }

  @Test("An empty password field with nothing stored is still refused")
  func firstRunStillRequiresAPassword() {
    // The other half, and the reason the field cannot simply be optional: an empty password
    // is not "no authentication", it is a server that refuses every request.
    #expect(OnboardingRules.passwordRejection(typed: "", hasStoredPassword: false) == "")
  }

  @Test("A weak typed password is refused whether or not one is stored")
  func weakPasswordsAreRefusedEitherWay() {
    for stored in [true, false] {
      let rejection = OnboardingRules.passwordRejection(typed: "a", hasStoredPassword: stored)
      #expect(rejection != nil && rejection != "", "expected a reason, got \(rejection ?? "nil")")
    }
  }

  @Test("A good typed password is accepted whether or not one is stored")
  func goodPasswordsAreAccepted() {
    for stored in [true, false] {
      #expect(
        OnboardingRules.passwordRejection(typed: "hunter2hunter2", hasStoredPassword: stored)
          == nil
      )
    }
  }

  // MARK: - The local-network switch

  @Test("The switch is keyed on the ranges, not on the note beside them")
  func localNetworkSwitchUsesRanges() {
    // The ranges are written by the server and read by the app, across a module boundary.
    // Matching on the NOTE (a display string) meant rewording either side made the switch
    // read off for a rule that was on, and flipping it appended a second copy of each range.
    for range in AccessControlService.localNetworkRanges {
      #expect(AccessControlService.isLocalNetworkRange(range))
    }
    #expect(!AccessControlService.isLocalNetworkRange("203.0.113.0/24"))
    // The note is a label and nothing branches on it.
    #expect(!AccessControlService.isLocalNetworkRange(AccessControlService.localNetworkNote))
  }

  @Test("The ranges are the private blocks, and IPv6 is among them")
  func localNetworkRangesAreThePrivateBlocks() {
    let ranges = AccessControlService.localNetworkRanges
    #expect(ranges.contains("10.0.0.0/8"))
    #expect(ranges.contains("172.16.0.0/12"))
    #expect(ranges.contains("192.168.0.0/16"))
    #expect(ranges.contains("fc00::/7"), "a LAN-only user on IPv6 is still a LAN-only user")
  }

  // MARK: - Structural rules

  private static func appSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BlueBubblesApp")
    return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
  }

  @Test("A failed start tears the composition down")
  func failedStartTearsDown() throws {
    // Structural because the failure needs a composition that builds and then refuses to
    // start, which cannot be arranged without a database, a port and a Private API socket.
    // What must not regress is that the catch has something to stop and stops it: without
    // that, a failed start left the composition running and holding `app.db`, and the next
    // press of Start failed on a busy database rather than on the original problem.
    let source = try Self.appSource("AppModel.swift")
    #expect(source.contains("var partiallyBuilt: RunningServer?"))
    #expect(
      source.contains("if let partiallyBuilt {"),
      "the catch must tear down a composition that got as far as being built"
    )
    #expect(
      source.contains("partiallyBuilt = nil"),
      "ownership must be released once `server` holds it, or `stop()` and this would race"
    )
    #expect(
      source.contains("private func tearDown("),
      "stop() and the failure path share one teardown so they cannot drift apart"
    )
  }

  @Test("Clearing FaceTime state asks first")
  func faceTimeClearConfirms() throws {
    // The button leaves every answered call with no hand-off watcher, and cannot tell one
    // the server got stuck in from one a person is sitting in at this Mac.
    let source = try Self.appSource("Views/FaceTimeMaintenance.swift")
    #expect(source.contains(".confirmationDialog("), "Clear Now must confirm before running")
    #expect(
      !source.contains(#"Button("Clear Now") { Task { await clear() } }"#),
      "the button must open the confirmation, not run the clear directly"
    )
    // And the copy has to say what it ends, since the danger is invisible otherwise.
    #expect(source.contains("LEAVES ANY CALL"))
  }
}

//  HandleFailureTests
//  What a client receives when Messages refuses a handle lookup.
//
//  `HandleInterface` has three Private-API call sites: small enough to have been easy to leave
//  out, which is why they are here. The same contract as the other walks — a refusal from
//  Messages is `InterfaceError.messagesFailed`, which projects to the 500 `iMessage Error`,
//  never a generic server error.
//
//  Split out of `InterfaceFailureTests`, which held this suite and the attachment one in a
//  single file. `FailureTranslationCoverageTests` attributes a table entry to the interface
//  its suite declares, and one file cannot declare two — so these operations sat in the
//  declared-uncovered list while being fully tested, which is the worst of both readings.
//
//  `availability` is walked once per service. Both branches sit inside the same
//  `throughMessages`, so today they share a translation and one entry would do; two entries
//  say each branch must keep it, which is what stops a later refactor from lifting one call
//  out of the wrapper and leaving the other behind.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBHTTPAPI
import BBPrivateAPIContract
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Handle failure translation")
struct HandleFailureTests {

  private static let address = "person@example.com"

  private func interface(
    privateAPI: (any PrivateAPI)? = FailingPrivateAPI()
  ) throws -> HandleInterface {
    HandleInterface(repository: try InterfaceFixtures.repository(), privateAPI: privateAPI)
  }

  /// Every handle operation that reaches Messages, by name, so a failure says which one.
  private func operations(
    _ handle: HandleInterface
  ) -> [(String, () async throws -> Void)] {
    [
      (
        "availability(iMessage)",
        { _ = try await handle.availability(address: Self.address, service: .iMessage) }
      ),
      (
        "availability(faceTime)",
        { _ = try await handle.availability(address: Self.address, service: .faceTime) }
      ),
      ("focusStatus", { _ = try await handle.focusStatus(address: Self.address) }),
    ]
  }

  @Test("Every handle lookup reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let handle = try interface()

    for (name, operation) in operations(handle) {
      do {
        try await operation()
        Issue.record("\(name) should have failed")
      } catch let error as InterfaceError {
        #expect(error == .messagesFailed("Messages said no"), "\(name)")
      } catch {
        Issue.record("\(name) threw \(type(of: error)) rather than InterfaceError: \(error)")
      }
    }
  }

  /// Availability is the one lookup clients most often mistake for a database question, so the
  /// "you do not have the Private API" answer has to stay the canonical one they match on.
  @Test("With no helper, a handle lookup gives the canonical unavailable message")
  func missingHelperKeepsItsPayload() async throws {
    let handle = try interface(privateAPI: nil)

    do {
      _ = try await handle.availability(address: Self.address, service: .iMessage)
      Issue.record("the lookup should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "checking address availability"))
    }
  }
}

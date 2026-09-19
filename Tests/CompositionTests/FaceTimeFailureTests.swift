//  FaceTimeFailureTests
//  What a client receives when Messages refuses a FaceTime operation.
//
//  The third of the exhaustive walks, and it exists because `FailureTranslationCoverageTests`
//  said out loud that eleven operations reached Messages with nothing checking that any of
//  them translated. The same contract as its two siblings: a refusal that came from Messages
//  is reported as `InterfaceError.messagesFailed`, which projects to the 500 `iMessage Error`
//  clients read, never as a generic server error.
//
//  **`leave` is why the coverage scan is keyed by type.** `ChatInterface.leave` was covered
//  and `FaceTimeInterface.leave` was not, and a scan matching on the bare name reported both
//  as done. It is a different operation on a different interface hanging up a different
//  thing; this file is where it finally gets tested.
//
//  The harness looked expensive from the outside and is not: `FaceTimeCoordinator` takes a
//  `SettingsStore` over an in-memory database, which `HandOffIdentityTests` already sets up
//  the same way, and the helper the operations actually call goes in through
//  `FaceTimeInterface` rather than the coordinator. The coordinator resolves its own helper
//  per call — `privateAPI: { nil }` here — because none of these reach it: `handOff` is the
//  only operation that would, and it throws inside `throughMessages` two lines before.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBFaceTime
import BBHTTPAPI
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("FaceTime failure translation")
struct FaceTimeFailureTests {

  private func interface() async throws -> FaceTimeInterface {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await SettingsStore(database: database, secrets: InMemorySecretStore())
    return FaceTimeInterface(
      coordinator: FaceTimeCoordinator(
        settings: settings,
        // Deliberately nil: nothing here reaches the coordinator's own helper, and a
        // failing one would hide which object actually refused.
        privateAPI: { nil },
        logger: Logger(label: "test")
      ),
      privateAPI: FailingPrivateAPI(),
      logger: Logger(label: "test")
    )
  }

  /// Every FaceTime operation that reaches Messages, by name, so a failure says which one.
  private func operations(
    _ faceTime: FaceTimeInterface
  ) -> [(String, () async throws -> Void)] {
    let call = "00000000-0000-0000-0000-00000000CA11"
    let conversation = "00000000-0000-0000-0000-0000000C0NV"
    return [
      ("mintLink", { _ = try await faceTime.mintLink() }),
      ("invalidateLinks", { _ = try await faceTime.invalidateLinks(urls: nil) }),
      (
        "placeCall",
        {
          // A non-empty address list, or the guard above rejects this as a 400 before any
          // of it reaches Messages — which would assert the opposite of the contract.
          _ = try await faceTime.placeCall(addresses: ["person@example.com"], video: false)
        }
      ),
      ("answer", { _ = try await faceTime.answer(callUUID: call) }),
      ("handOff", { _ = try await faceTime.handOff(callUUID: call) }),
      ("leave", { try await faceTime.leave(callUUID: call) }),
      (
        "admit",
        { try await faceTime.admit(conversationUUID: conversation, address: "person@example.com") }
      ),
      ("members", { _ = try await faceTime.members(conversationUUID: conversation) }),
      ("debugState", { _ = try await faceTime.debugState(conversationUUID: conversation) }),
      ("windows", { _ = try await faceTime.windows() }),
      ("dismissAlert", { _ = try await faceTime.dismissAlert() }),
    ]
  }

  @Test("Every FaceTime operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let faceTime = try await interface()

    for (name, operation) in operations(faceTime) {
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

  /// The rendered envelope, since that is what a client actually parses.
  @Test("A refused FaceTime operation renders as 500 with the iMessage error type")
  func rendersWithTheDocumentedShape() async throws {
    let faceTime = try await interface()

    do {
      try await faceTime.leave(callUUID: "00000000-0000-0000-0000-00000000CA11")
      Issue.record("leaving should have failed")
    } catch {
      let (status, envelope) = ErrorRenderer.render(error, logger: .init(label: "test"))
      #expect(status == 500)
      #expect(envelope.error?.type == .iMessageError)
      #expect(envelope.error?.message == "Messages said no")
    }
  }

  // MARK: - What must NOT be translated

  @Test("An empty address list stays a 400, not an iMessage error")
  func validationKeepsIts400() async throws {
    // `placeCall` checks its own request first. Wrapping that refusal would tell a client
    // its own mistake was a server fault and, because `IMessageError` is a 500, invite it
    // to retry a request that can never succeed.
    let faceTime = try await interface()

    do {
      _ = try await faceTime.placeCall(addresses: [], video: false)
      Issue.record("an empty address list should have been rejected")
    } catch let error as InterfaceError {
      guard case .invalidRequest = error else {
        Issue.record("expected .invalidRequest, got \(error)")
        return
      }
    }
  }
}

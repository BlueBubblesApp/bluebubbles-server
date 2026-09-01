//  InterfaceFailureTests
//  The last two interfaces that reach Messages, held to the same contract as the first two.
//
//  `HandleInterface` and `AttachmentInterface` have four Private-API call sites between them —
//  small enough to have been easy to leave out, which is exactly why they are here. See
//  `SendFailureTests` and `ChatFailureTests` for the same contract on the larger two.
//
//  Both suites also pin something each interface does DIFFERENTLY when no helper is connected,
//  because that difference is deliberate and a tidy-up would erase it.

import BBHTTPAPI
import BBIMessage
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Handle failure translation")
struct HandleFailureTests {

  private func interface(
    privateAPI: (any PrivateAPI)? = FailingPrivateAPI()
  ) throws -> HandleInterface {
    HandleInterface(repository: try InterfaceFixtures.repository(), privateAPI: privateAPI)
  }

  @Test(
    "Every handle lookup reports a helper refusal as an iMessage error",
    arguments: ["iMessage availability", "FaceTime availability", "Focus status"])
  func lookupsTranslate(_ operation: String) async throws {
    let handle = try interface()

    do {
      switch operation {
      case "iMessage availability":
        _ = try await handle.availability(address: "person@example.com", service: .iMessage)
      case "FaceTime availability":
        _ = try await handle.availability(address: "person@example.com", service: .faceTime)
      default:
        _ = try await handle.focusStatus(address: "person@example.com")
      }
      Issue.record("\(operation) should have failed")
    } catch let error as InterfaceError {
      #expect(error == .messagesFailed("Messages said no"))
    } catch {
      Issue.record("\(operation) threw \(type(of: error)) rather than InterfaceError: \(error)")
    }
  }

  /// Availability is the one lookup clients most often mistake for a database question, so the
  /// "you do not have the Private API" answer has to stay the canonical one they match on.
  @Test("With no helper, a handle lookup gives the canonical unavailable message")
  func missingHelperKeepsItsPayload() async throws {
    let handle = try interface(privateAPI: nil)

    do {
      _ = try await handle.availability(address: "person@example.com", service: .iMessage)
      Issue.record("the lookup should have been refused")
    } catch let error as InterfaceError {
      #expect(error == .helperUnavailable(feature: "checking address availability"))
    }
  }
}

@Suite("Attachment failure translation")
struct AttachmentFailureTests {

  private static let guid = "purged-attachment-guid"

  @Test("A failed iCloud download reports as an iMessage error")
  func purgedDownloadTranslates() async throws {
    let repository = try InterfaceFixtures.purgedAttachment(guid: Self.guid)
    let attachments = AttachmentInterface(
      repository: repository, privateAPI: FailingPrivateAPI()
    )

    do {
      _ = try await attachments.resolvePath(guid: Self.guid)
      Issue.record("the download should have failed")
    } catch let error as InterfaceError {
      #expect(error == .messagesFailed("Messages said no"))
    }
  }

  /// The exception in this set, and it must stay one.
  ///
  /// Every other interface answers "no helper" with the canonical `IMessageError`. This one
  /// answers with a 404 that says the attachment was offloaded to iCloud and that downloading
  /// it needs the Private API — which is both more specific and more actionable, because the
  /// caller's real problem is a missing file rather than a missing feature. Collapsing it into
  /// the shared helper for consistency would replace a useful sentence with a generic one, and
  /// turn a 404 into a 500.
  @Test("With no helper, a purged attachment stays a 404 that explains itself")
  func missingHelperKeepsTheSpecificNotFound() async throws {
    let repository = try InterfaceFixtures.purgedAttachment(guid: Self.guid)
    let attachments = AttachmentInterface(repository: repository, privateAPI: nil)

    do {
      _ = try await attachments.resolvePath(guid: Self.guid)
      Issue.record("the lookup should have been refused")
    } catch let error as InterfaceError {
      guard case .notFound(let detail) = error else {
        Issue.record("expected .notFound, got \(error)")
        return
      }
      #expect(detail.contains("offloaded to iCloud"))
      #expect(detail.contains("Private API"))
    }
  }
}

//  AttachmentFailureTests
//  What a client receives when Messages refuses an attachment download.
//
//  One Private-API call site, and it carries the exception in this set: see
//  `missingHelperKeepsTheSpecificNotFound`. Split out of `InterfaceFailureTests` so the
//  coverage scan can attribute this table to `AttachmentInterface` rather than to whichever
//  suite happened to be first in a shared file.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBHTTPAPI
import BBIMessage
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Attachment failure translation")
struct AttachmentFailureTests {

  private static let guid = "purged-attachment-guid"

  /// Every attachment operation that reaches Messages, by name.
  ///
  /// The repository is the purged-attachment fixture rather than the empty one: `resolvePath`
  /// looks the row up first and answers `.notFound` when there is none, so against an empty
  /// database this would assert a translation that never ran.
  private func operations(
    _ attachments: AttachmentInterface
  ) -> [(String, () async throws -> Void)] {
    [("resolvePath", { _ = try await attachments.resolvePath(guid: Self.guid) })]
  }

  @Test("Every attachment operation reports a helper refusal as an iMessage error")
  func everyOperationTranslates() async throws {
    let attachments = AttachmentInterface(
      repository: try InterfaceFixtures.purgedAttachment(guid: Self.guid),
      privateAPI: FailingPrivateAPI()
    )

    for (name, operation) in operations(attachments) {
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

  /// The exception in this set, and it must stay one.
  ///
  /// Every other interface answers "no helper" with the canonical `IMessageError`. This one
  /// answers with a 404 that says the attachment was offloaded to iCloud and that downloading
  /// it needs the Private API, which is both more specific and more actionable, because the
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

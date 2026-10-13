//  ReferenceRefusalTests
//  Two v1 refusals that answered with the wrong status, in the reference's shape now.
//
//  Neither is reachable by the parity replay: both are error paths the recorded corpus has
//  no response for, so the diff never saw them. The reference's sentences were declared in
//  `ReferenceMessages` and used by nothing.

import BBIMessage
import BBPersistence
import BBPrivateAPIContract
import BBSerialization
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Reference refusals", .removingChatDBCopies)
struct ReferenceRefusalTests {

  // MARK: - GET /attachment/:guid/blurhash

  /// `attachmentRouter.ts`: `throw new NotFound({ error: "Attachment is not an image!" })`.
  /// It was a 400 with a sentence of ours.
  @Test("A blurhash of something that is not an image is a 404 with the reference's sentence")
  func blurhashOfNonImage() async throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("reference-refusal-\(UUID().uuidString).txt")
    try Data("BB test".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let attachments = AttachmentInterface(
      repository: try InterfaceFixtures.attachment(guid: "attachment-1", filename: file.path))
    await #expect(throws: InterfaceError.notFound(ReferenceMessages.attachmentNotAnImage)) {
      _ = try await attachments.blurhash(guid: "attachment-1")
    }
  }

  // MARK: - GET /message/:guid/embedded-media

  /// A message the account sent, in a chat, in the committed fixture.
  private static let fixtureMessage = "11111111-0000-0000-0000-000000000007"

  private func messages(answering path: String?) async throws -> MessageInterface {
    let copy = try CommittedChatDB.copy()
    let database = try ReadOnlyDatabase(path: copy.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    var helper = FailingPrivateAPI(error: PrivateAPIError.rejectedByMessages(reason: "unused"))
    helper.onBalloonBundleMediaPath = { _ in path }
    return MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile),
      privateAPI: helper
    )
  }

  /// `messageRouter.getEmbeddedMedia`: `if (!mediaPath) throw new NotFound({ error: "No
  /// embedded media found!" })`. The helper's "nothing" was a thrown refusal, and reached
  /// the client as a 500 `iMessage Error`, which says to retry.
  @Test("A message whose plugin produced nothing is a 404 with the reference's sentence")
  func noEmbeddedMedia() async throws {
    let interface = try await messages(answering: nil)
    await #expect(throws: InterfaceError.notFound(ReferenceMessages.embeddedMediaNotFound)) {
      _ = try await interface.embeddedMediaPath(guid: Self.fixtureMessage)
    }
  }

  @Test("A message with media answers its path")
  func embeddedMediaFound() async throws {
    let interface = try await messages(answering: "/tmp/handwriting.png")
    #expect(
      try await interface.embeddedMediaPath(guid: Self.fixtureMessage) == "/tmp/handwriting.png")
  }

  /// The reference checks the message before asking the helper anything.
  @Test("A message that does not exist is refused before the helper is asked")
  func missingMessage() async throws {
    let interface = try await messages(answering: "/tmp/never.png")
    await #expect(throws: InterfaceError.invalidRequest(ReferenceMessages.selectedMessageMissing)) {
      _ = try await interface.embeddedMediaPath(guid: "00000000-0000-0000-0000-000000000000")
    }
  }
}

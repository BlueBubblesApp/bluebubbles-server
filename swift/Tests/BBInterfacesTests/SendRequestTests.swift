//  SendRequestTests
//  What a send request carries, and which action it becomes.
//
//  The three send entry points used to be a request struct, seven loose parameters and six
//  loose parameters. Unifying them moved one real decision out of `sendAttachment`'s body and
//  onto the request — whether a single-file send has to be promoted to a multipart one, and
//  what carries over when it is — so that decision now has somewhere to be asserted.
//
//  It is worth asserting because it is invisible when wrong. The helper's single-file action
//  has no field for a subject, an effect or a reply; a promotion that dropped one would send
//  the file successfully and silently lose the association, which reads to a user as the
//  server ignoring their reply.

import BBIMessage
import BBInterfaces
import BBTestSupport
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Send requests")
struct SendRequestTests {

  private func interface(privateAPI: MessageInterface.Helper? = nil) throws -> MessageInterface {
    MessageInterface(
      repository: try InterfaceFixtures.repository(),
      serializer: InterfaceFixtures.serializer,
      privateAPI: privateAPI
    )
  }

  // MARK: - Which action a request becomes

  @Test("A plain attachment needs nothing the single-file action cannot carry")
  func plainAttachmentStaysSingleFile() {
    let request = MessageInterface.SendAttachmentRequest(
      chatGUID: "iMessage;-;+15551234567", filePath: "/tmp/photo.jpg"
    )
    #expect(!request.needsMultipart)
  }

  @Test(
    "An association promotes it, whichever one is named",
    arguments: ["subject", "effect", "reply"]
  )
  func anyAssociationPromotes(_ field: String) {
    var request = MessageInterface.SendAttachmentRequest(
      chatGUID: "iMessage;-;+15551234567", filePath: "/tmp/photo.jpg"
    )
    switch field {
    case "subject": request.subject = "About last night"
    case "effect": request.effectID = "com.apple.MobileSMS.expressivesend.gentle"
    default: request.replyToGUID = "p:0/ABC-123"
    }

    #expect(request.needsMultipart)
  }

  @Test("Promotion carries every association across, and the file with it")
  func promotionCarriesEverything() {
    // The whole point of the promotion. A field dropped here is a send that succeeds and
    // quietly loses what the client asked for.
    let request = MessageInterface.SendAttachmentRequest(
      chatGUID: "iMessage;-;+15551234567",
      filePath: "/tmp/photo.jpg",
      subject: "About last night",
      effectID: "com.apple.MobileSMS.expressivesend.gentle",
      replyToGUID: "p:0/ABC-123",
      partIndex: 2
    )

    let multipart = request.asMultipart

    #expect(multipart.chatGUID == request.chatGUID)
    #expect(multipart.subject == request.subject)
    #expect(multipart.effectID == request.effectID)
    #expect(multipart.replyToGUID == request.replyToGUID)
    #expect(multipart.partIndex == request.partIndex)
    // One part, carrying the file and no text: the same bytes, sent through the action that
    // has somewhere to put the association.
    #expect(multipart.parts.count == 1)
    #expect(multipart.parts.first?.attachmentPath == "/tmp/photo.jpg")
    #expect(multipart.parts.first?.text == nil)
  }

  // MARK: - Through the interface

  @Test("An attachment with a reply takes the multipart path, which needs the helper")
  func attachmentWithReplyGoesMultipart() async throws {
    // With no helper, the two paths fail differently and that is what identifies which one
    // was taken: multipart refuses with `helperUnavailable` before doing anything, while a
    // plain single-file send would fall through to AppleScript.
    let file = try InterfaceFixtures.temporaryFile()
    let message = try interface()

    let error = await #expect(throws: InterfaceError.self) {
      try await message.sendAttachment(
        MessageInterface.SendAttachmentRequest(
          chatGUID: "iMessage;-;+15551234567",
          filePath: file,
          replyToGUID: "p:0/ABC-123"
        )
      )
    }
    #expect(error == .helperUnavailable(feature: "multipart messages"))
  }

  @Test("A voice memo cannot carry an association, and is refused before anything is sent")
  func voiceMemoWithSubjectIsRefused() async throws {
    // `isAudioMessage` is its own composition in Messages, so it cannot travel through the
    // multipart action — which means the association cannot be honoured at all. Refused
    // rather than silently dropped.
    let file = try InterfaceFixtures.temporaryFile()
    let message = try interface()

    let error = await #expect(throws: InterfaceError.self) {
      try await message.sendAttachment(
        MessageInterface.SendAttachmentRequest(
          chatGUID: "iMessage;-;+15551234567",
          filePath: file,
          isAudioMessage: true,
          subject: "About last night"
        )
      )
    }
    #expect(error == .invalidRequest("a voice memo cannot carry a subject, an effect or a reply"))
  }

  @Test("A send names the file that is missing rather than failing at the backend")
  func missingFileIsRejectedEarly() async throws {
    let message = try interface()

    let error = await #expect(throws: InterfaceError.self) {
      try await message.sendAttachment(
        MessageInterface.SendAttachmentRequest(
          chatGUID: "iMessage;-;+15551234567", filePath: "/tmp/definitely-not-here.jpg"
        )
      )
    }
    #expect(error == .invalidRequest("no file at /tmp/definitely-not-here.jpg"))
  }

  @Test("A multipart send with no parts is refused rather than sent empty")
  func emptyMultipartIsRefused() async throws {
    let message = try interface(privateAPI: FailingPrivateAPI())

    let error = await #expect(throws: InterfaceError.self) {
      try await message.sendMultipart(
        MessageInterface.SendMultipartRequest(
          chatGUID: "iMessage;-;+15551234567", parts: []
        )
      )
    }
    #expect(error == .invalidRequest("at least one part is required"))
  }

  // MARK: - The asymmetry that is deliberate

  @Test("partIndex defaults differ between text and the other two, on purpose")
  func partIndexDefaultsAreDeliberate() {
    // The contract's `replyPartIndex` is `Int?`. A text send always sends a value; an
    // attachment or multipart send omits it. Making them agree would change what goes over
    // the wire for one of the two, so the difference is pinned here rather than left to
    // look like drift somebody should tidy.
    let text = MessageInterface.SendTextRequest(chatGUID: "chat", text: "hello")
    let attachment = MessageInterface.SendAttachmentRequest(chatGUID: "chat", filePath: "/f")
    let multipart = MessageInterface.SendMultipartRequest(chatGUID: "chat", parts: [])

    #expect(text.partIndex == 0)
    #expect(attachment.partIndex == nil)
    #expect(multipart.partIndex == nil)
  }
}

//  SendFilenameTests
//  The name a send gives a file is the name the recipient sees.
//
//  The reference names the file at SEND time: multipart copies each part to `part.name`
//  (`messageInterface.ts:585-592`), and the attachment route writes under the form's `name`.
//  The upload's own filename is only the default. Multipart ignored `name` here, so a file
//  went out under whatever the client's HTTP library called it at upload.
//
//  What the recipient sees is the last path component of what reaches `AttachmentStaging`,
//  which keeps it, so asserting that component is asserting the name on the wire to Messages.

import BBCore
import BBHTTPAPI
import BBMedia
import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBHandlers

@Suite("Send-time filenames")
struct SendFilenameTests {

  private func store() -> UploadStore {
    UploadStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-send-filename-\(UUID().uuidString)"))
  }

  /// The path `POST /attachment/upload` hands a client for a file it uploaded as `filename`.
  private func uploaded(_ filename: String, to uploads: UploadStore) throws -> String {
    uploads.clientPath(of: try uploads.stage(Data("bytes".utf8), named: filename))
  }

  private func parts(_ parts: [JSONValue], uploads: UploadStore) throws -> [MessagePart] {
    try WriteHandlers.multipartParts(
      from: RequestValues(.object(["parts": .array(parts)])), uploads: uploads)
  }

  @Test("A multipart part's `name` is the name its file is sent under")
  func multipartNameWins() throws {
    let uploads = store()
    let path = try uploaded("image_picker_4F2A.jpg", to: uploads)

    let sent = try parts(
      [
        .object(["text": .string("Here it is")]),
        // The reference's own keys: the upload's path under `attachment`, and `name`.
        .object(["attachment": .string(path), "name": .string("Beach.jpg")]),
      ], uploads: uploads)

    #expect(sent.count == 2)
    #expect(sent[0].attachmentPath == nil)
    let file = try #require(sent[1].attachmentPath)
    #expect((file as NSString).lastPathComponent == "Beach.jpg")
    // Still inside the store: confining it again succeeds.
    #expect(try uploads.confined(file).hasSuffix("/Beach.jpg"))
  }

  @Test("Without a `name`, a part keeps the name it was uploaded under")
  func multipartWithoutNameKeepsTheUpload() throws {
    let uploads = store()
    let path = try uploaded("IMG_0001.heic", to: uploads)
    let sent = try parts([.object(["filePath": .string(path)])], uploads: uploads)
    #expect((try #require(sent[0].attachmentPath) as NSString).lastPathComponent == "IMG_0001.heic")
  }

  @Test("A part's `name` is cleaned like any other filename")
  func multipartNameIsSanitised() throws {
    let uploads = store()
    let path = try uploaded("IMG_0001.heic", to: uploads)
    let sent = try parts(
      [.object(["attachment": .string(path), "name": .string("../../photo\u{202E}gnp.exe")])],
      uploads: uploads)
    #expect((try #require(sent[0].attachmentPath) as NSString).lastPathComponent == "photognp.exe")
  }

  @Test("A `name` does not open the path: one outside the store is still refused")
  func nameDoesNotBypassConfinement() throws {
    #expect(throws: (any Error).self) {
      _ = try parts(
        [.object(["filePath": .string("/etc/passwd"), "name": .string("innocent.txt")])],
        uploads: store())
    }
  }

  @Test("A JSON attachment send names its staged file with `name`")
  func jsonBodyNameWins() throws {
    let uploads = store()
    let path = try uploaded("image_picker_4F2A.jpg", to: uploads)
    let request = APIRequestContext(
      method: .post, path: "/api/v1/message/attachment",
      headers: ["Content-Type": "application/json"],
      body: Data(
        #"{"chatGuid":"any;-;person@example.com","filePath":"\#(path)","name":"Beach.jpg"}"#
          .utf8))

    let named = try UploadedFileBody.parse(request, filePart: "attachment", uploads: uploads)
    #expect((named.path as NSString).lastPathComponent == "Beach.jpg")

    // The routes that pass `nameField: nil` (a sticker's `name` is the sticker's, a group
    // photo has no filename to give) keep the staged name.
    let unnamed = try UploadedFileBody.parse(
      request, filePart: "attachment", uploads: uploads, nameField: nil)
    #expect((unnamed.path as NSString).lastPathComponent == "image_picker_4F2A.jpg")
  }
}

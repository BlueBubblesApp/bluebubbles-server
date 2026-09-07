//  UploadedFileBodyTests
//  The file routes read what clients actually send.
//
//  The recorded `POST /message/attachment` fixture is a multipart form — `chatGuid`,
//  `tempGuid`, `name`, `method` and an `attachment` part — captured from the reference. The
//  send routes are deny-listed from replay (the harness would send a real message), so this
//  is where that recording is held against the parser: the form it carries must come out as
//  the fields the handler reads and a file on disk. Without this the handler could go back
//  to reading a JSON path and nothing in CI would notice, which is how it got that way.

import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Uploaded file bodies")
struct UploadedFileBodyTests {

  private func store() -> UploadStore {
    UploadStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-uploaded-file-body-\(UUID().uuidString)")
    )
  }

  /// The recorded request, exactly as the reference received it.
  private func recordedAttachmentForm() throws -> (contentType: String, body: Data) {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/http/post_api_v1_message_attachment-5baa61-200.json")
    let fixture = try JSONValue.parse(try Data(contentsOf: url))
    let request = try #require(fixture["request"])
    let headers = try #require(request["headers"])
    let contentType = try #require(headers["content-type"]?.stringValue)
    let body = try #require(request["body"]?["value"]?.stringValue)
    return (contentType, Data(body.utf8))
  }

  @Test("The recorded attachment form parses into the handler's fields and a file")
  func recordedForm() throws {
    let (contentType, body) = try recordedAttachmentForm()
    let form = try MultipartForm.parse(body: body, contentType: contentType)
    let parsed = try UploadedFileBody.parse(form: form, filePart: "attachment", uploads: store())

    #expect(parsed.values.string("chatGuid") == "any;-;person@example.com")
    #expect(parsed.values.string("name") == "fixture.png")
    #expect(parsed.values.string("method") != nil)
    #expect(parsed.values.string("tempGuid")?.hasPrefix("fixture-") == true)
    // Written under EXACTLY the `name` the client gave, which is what the recipient sees;
    // uniqueness is the directory's job.
    #expect((parsed.path as NSString).lastPathComponent == "fixture.png")
    #expect(FileManager.default.fileExists(atPath: parsed.path))
  }

  @Test("A multipart request is parsed from its Content-Type, not from the route")
  func multipartRequest() throws {
    let boundary = "bb-test-boundary"
    var body = ""
    for (name, value) in [
      ("chatGuid", "any;-;person@example.com"), ("partIndex", "2"),
      ("isAudioMessage", "true"), ("xScalar", "0.25"),
    ] {
      body +=
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }
    body +=
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"attachment\"; "
      + "filename=\"sticker.png\"\r\nContent-Type: image/png\r\n\r\nPNGBYTES\r\n--\(boundary)--\r\n"
    let request = APIRequestContext(
      method: .post, path: "/api/v1/message/attachment",
      headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
      body: Data(body.utf8)
    )

    let parsed = try UploadedFileBody.parse(request, filePart: "attachment", uploads: store())
    #expect(parsed.values.string("chatGuid") == "any;-;person@example.com")
    // Form fields are strings; the typed reads coerce them the way the reference does.
    #expect(parsed.values.int("partIndex") == 2)
    #expect(parsed.values.bool("isAudioMessage") == true)
    #expect(parsed.values.double("xScalar") == 0.25)
    #expect((parsed.path as NSString).lastPathComponent == "sticker.png")
    #expect(try Data(contentsOf: URL(fileURLWithPath: parsed.path)) == Data("PNGBYTES".utf8))
  }

  @Test("A JSON body names a file already on disk")
  func jsonRequest() throws {
    let request = APIRequestContext(
      method: .post, path: "/api/v1/message/attachment",
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"chatGuid":"any;-;person@example.com","path":"/tmp/already-there.png"}"#.utf8)
    )
    let parsed = try UploadedFileBody.parse(request, filePart: "attachment", uploads: store())
    #expect(parsed.path == "/tmp/already-there.png")
    #expect(parsed.values.string("chatGuid") == "any;-;person@example.com")
  }

  @Test("A form without the file part is refused")
  func missingFilePart() throws {
    let boundary = "bb-test-boundary"
    let body =
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"chatGuid\"\r\n\r\nx\r\n--\(boundary)--\r\n"
    let request = APIRequestContext(
      method: .post, path: "/api/v1/message/attachment",
      headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
      body: Data(body.utf8)
    )
    #expect(throws: BadRequest.self) {
      try UploadedFileBody.parse(request, filePart: "attachment", uploads: store())
    }
  }
}

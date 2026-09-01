//  MultipartFormTests
//
//  The parser works on bytes rather than text. These check that specifically: a body carrying
//  real binary must survive, and decoding it as a String to find boundaries corrupts the
//  payload while still appearing to parse, because the headers around it are ASCII.

import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("MultipartForm")
struct MultipartFormTests {

  private let boundary = "----BBTestBoundary7MA4YWxkTrZu0gW"

  private func body(_ sections: [String], binary: (name: String, bytes: Data)? = nil) -> Data {
    var data = Data()
    for section in sections {
      data += Data("--\(boundary)\r\n\(section)\r\n".utf8)
    }
    if let binary {
      data += Data("--\(boundary)\r\n".utf8)
      data += Data(
        """
        Content-Disposition: form-data; name="\(binary.name)"; filename="photo.jpg"\r
        Content-Type: image/jpeg\r
        \r

        """.utf8)
      data += binary.bytes
      data += Data("\r\n".utf8)
    }
    data += Data("--\(boundary)--\r\n".utf8)
    return data
  }

  private var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  @Test("reads simple fields")
  func fields() throws {
    let form = try MultipartForm.parse(
      body: body([
        "Content-Disposition: form-data; name=\"chatGuid\"\r\n\r\niMessage;-;a@example.com",
        "Content-Disposition: form-data; name=\"name\"\r\n\r\nphoto.jpg",
      ]),
      contentType: contentType
    )
    #expect(form.parts.count == 2)
    #expect(form["chatGuid"]?.text == "iMessage;-;a@example.com")
    #expect(form["name"]?.text == "photo.jpg")
  }

  /// The test that matters. These bytes include CRLF sequences, a `--`, and invalid UTF-8;
  /// a String-based parser mangles all three.
  @Test("preserves binary payloads exactly")
  func binary() throws {
    var bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
    bytes += Data("\r\n--not-the-boundary\r\n".utf8)
    bytes += Data([0x00, 0x80, 0xFE, 0xFF, 0x0D, 0x0A])
    bytes += Data((0...255).map(UInt8.init))

    let form = try MultipartForm.parse(
      body: body(
        ["Content-Disposition: form-data; name=\"chatGuid\"\r\n\r\niMessage;-;a@example.com"],
        binary: (name: "attachment", bytes: bytes)
      ),
      contentType: contentType
    )

    let part = try #require(form["attachment"])
    #expect(part.data == bytes, "binary payload was altered")
    #expect(part.filename == "photo.jpg")
    #expect(part.contentType == "image/jpeg")
    #expect(form["chatGuid"]?.text == "iMessage;-;a@example.com")
  }

  @Test("reads a quoted boundary")
  func quotedBoundary() throws {
    let form = try MultipartForm.parse(
      body: body(["Content-Disposition: form-data; name=\"a\"\r\n\r\nvalue"]),
      contentType: "multipart/form-data; boundary=\"\(boundary)\""
    )
    #expect(form["a"]?.text == "value")
  }

  @Test("rejects a body that is not multipart")
  func notMultipart() {
    #expect(throws: MultipartForm.MultipartError.notMultipart) {
      try MultipartForm.parse(body: Data("{}".utf8), contentType: "application/json")
    }
    #expect(throws: MultipartForm.MultipartError.missingBoundary) {
      try MultipartForm.parse(body: Data(), contentType: "multipart/form-data")
    }
  }

  @Test("an empty part keeps its name")
  func emptyPart() throws {
    let form = try MultipartForm.parse(
      body: body(["Content-Disposition: form-data; name=\"empty\"\r\n\r\n"]),
      contentType: contentType
    )
    #expect(form["empty"]?.data.isEmpty == true)
  }

  @Test("boundary parsing handles extra parameters")
  func boundaryExtraction() {
    #expect(MultipartForm.boundary(in: "multipart/form-data; boundary=abc") == "abc")
    #expect(MultipartForm.boundary(in: "multipart/form-data; charset=utf-8; boundary=abc") == "abc")
    #expect(MultipartForm.boundary(in: "multipart/form-data; BOUNDARY=abc") == "abc")
    #expect(MultipartForm.boundary(in: "multipart/form-data") == nil)
  }
}

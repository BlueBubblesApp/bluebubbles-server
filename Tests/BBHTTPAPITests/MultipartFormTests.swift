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

  // MARK: - Not copying the body
  //
  // The parser used to prefix the whole body with CRLF so that every boundary had a leading
  // one, then copy each section out again. For an attachment upload that is the body twice
  // over: measured at a 50MB body growing the process by 150MB, on a route a 4GB Mac serves.
  // The first delimiter is special-cased now and the parts are slices of the body.

  /// A part's bytes SHARE the body's storage rather than duplicating it.
  ///
  /// Asserted through the slice's index base, which is the observable difference: a `Data`
  /// slice keeps its parent's indices, and `Data(slice)` -- the copy this removed -- re-bases
  /// them to zero. Any part but the first therefore starts above zero exactly when it has not
  /// been copied.
  @Test("A part's data is a slice of the body, not a copy of it")
  func partsAreSlices() throws {
    let boundary = "----slice"
    var body = Data("--\(boundary)\r\n".utf8)
    body.append(Data("Content-Disposition: form-data; name=\"first\"\r\n\r\n".utf8))
    body.append(Data("one".utf8))
    body.append(Data("\r\n--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"second\"\r\n\r\n".utf8))
    body.append(Data("two".utf8))
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let form = try MultipartForm.parse(
      body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    #expect(form.parts.count == 2)
    let second = try #require(form["second"])
    #expect(second.text == "two")
    #expect(second.data.startIndex > 0, "the part was copied out of the body rather than sliced")
  }

  /// The first boundary has no leading CRLF, which is the case the removed copy existed to
  /// paper over.
  @Test("A body beginning with the boundary parses")
  func openingBoundaryIsFound() throws {
    let boundary = "----open"
    var body = Data("--\(boundary)\r\n".utf8)
    body.append(Data("Content-Disposition: form-data; name=\"only\"\r\n\r\n".utf8))
    body.append(Data("value".utf8))
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let form = try MultipartForm.parse(
      body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    #expect(form["only"]?.text == "value")
  }

  /// RFC 2046 allows a preamble before the first boundary, and some clients send a bare CRLF
  /// there. Both reach the delimiter with its leading CRLF, which is the other branch.
  @Test(
    "A body with a preamble before the first boundary parses",
    arguments: [
      "\r\n", "ignored preamble text\r\n",
    ])
  func preambleIsSkipped(_ preamble: String) throws {
    let boundary = "----pre"
    var body = Data(preamble.utf8)
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"only\"\r\n\r\n".utf8))
    body.append(Data("value".utf8))
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let form = try MultipartForm.parse(
      body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    #expect(form["only"]?.text == "value")
  }

  /// A slice that is written to disk must write its own bytes, not the parent's.
  @Test("A sliced part round-trips through the filesystem byte for byte")
  func slicedPartWritesItsOwnBytes() throws {
    let boundary = "----bytes"
    let payload = Data((0...255).map { UInt8($0) })
    var body = Data("--\(boundary)\r\n".utf8)
    body.append(Data("Content-Disposition: form-data; name=\"pad\"\r\n\r\n".utf8))
    body.append(Data("padding that shifts the next part's index".utf8))
    body.append(Data("\r\n--\(boundary)\r\n".utf8))
    let header =
      "Content-Disposition: form-data; name=\"file\"; filename=\"b.bin\"\r\n"
      + "Content-Type: application/octet-stream\r\n\r\n"
    body.append(Data(header.utf8))
    body.append(payload)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    let form = try MultipartForm.parse(
      body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    let file = try #require(form["file"])
    #expect(file.data.startIndex > 0, "this test is only meaningful for a slice")
    #expect(file.data == payload)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-slice-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try file.data.write(to: url)
    #expect(try Data(contentsOf: url) == payload)
  }
}

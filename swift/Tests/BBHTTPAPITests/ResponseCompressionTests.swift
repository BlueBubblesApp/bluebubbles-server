//  ResponseCompressionTests
//  What a client asked for is what a client gets.
//
//  Compression is the one change here that alters bytes a shipped client already receives, so
//  the tests that matter are the ones pinning when it must NOT happen: no `Accept-Encoding`,
//  an explicit `gzip;q=0`, a body too small to be worth it. Each of those is a client that
//  would be handed something it cannot read, and each is a silent failure — the request
//  succeeds, the status is 200, and the body is binary noise.
//
//  The round trip is asserted rather than assumed: a compressor that produces a well-formed
//  gzip stream of the WRONG bytes passes every header check ever written.

import CompressNIO
import Foundation
import NIOCore
import Testing

@testable import BBHTTPAPI

@Suite("Response compression")
struct ResponseCompressionTests {

  // MARK: - Negotiation

  @Test("A client that says nothing is never sent gzip")
  func silenceIsNotConsent() {
    #expect(!ResponseCompression.accepts(nil))
    #expect(!ResponseCompression.accepts(""))
  }

  @Test("The usual spellings are accepted")
  func commonHeaders() {
    for header in [
      "gzip",
      "gzip, deflate",
      "gzip, deflate, br",
      "deflate, gzip",
      "GZIP",
      " gzip ",
      "gzip;q=1.0, identity;q=0.5",
      "*",
    ] {
      #expect(ResponseCompression.accepts(header), "should accept: \(header)")
    }
  }

  @Test("`gzip;q=0` is a refusal, even though it contains the word")
  func qualityZeroIsARefusal() {
    // The reason this is parsed rather than substring-matched. A client that goes out of its
    // way to say "not gzip" and is sent gzip anyway cannot read the response at all.
    #expect(!ResponseCompression.accepts("gzip;q=0"))
    #expect(!ResponseCompression.accepts("gzip;q=0.0"))
    #expect(!ResponseCompression.accepts("gzip; q=0"))
    #expect(!ResponseCompression.accepts("deflate, gzip;q=0"))
  }

  @Test("An encoding this server does not speak is not mistaken for gzip")
  func otherEncodings() {
    #expect(!ResponseCompression.accepts("br"))
    #expect(!ResponseCompression.accepts("deflate"))
    #expect(!ResponseCompression.accepts("identity"))
    #expect(!ResponseCompression.accepts("compress"))
    // Substring traps: both contain "gzip" and neither names it.
    #expect(!ResponseCompression.accepts("x-gzip-ish"))
    #expect(!ResponseCompression.accepts("notgzip"))
  }

  // MARK: - The threshold

  @Test("A small body is left alone")
  func smallBodiesAreNotCompressed() {
    // A `ping` envelope is 55 bytes and an error is ~120. Compressing those spends CPU to
    // make them bigger.
    let small = Data(String(repeating: "a", count: ResponseCompression.minimumBytes - 1).utf8)
    #expect(ResponseCompression.gzip(small) == nil)
  }

  @Test("A body at the threshold is compressed")
  func thresholdIsInclusive() {
    let atLimit = Data(String(repeating: "a", count: ResponseCompression.minimumBytes).utf8)
    #expect(ResponseCompression.gzip(atLimit) != nil)
  }

  // MARK: - The bytes

  @Test("Compressed bytes decompress back to exactly what went in")
  func roundTrip() throws {
    // Realistic shape rather than repeated characters: a run of 'a' compresses 1000:1 and
    // would hide an encoder that mangles anything structured.
    let payload = try JSONSerialization.data(withJSONObject: [
      "status": 200,
      "message": "Success",
      "data": (0..<200).map { index in
        [
          "guid": "message-\(index)-0123456789ABCDEF",
          "text": "the quick brown fox jumps over the lazy dog \(index)",
          "isFromMe": index.isMultiple(of: 2),
          "dateCreated": 1_757_000_000_000 + index,
        ] as [String: Any]
      },
    ])

    var compressed = try #require(ResponseCompression.gzip(payload))
    #expect(compressed.readableBytes < payload.count, "gzip should shrink this")

    var decompressed = try compressed.decompress(with: .gzip())
    let bytes = decompressed.readBytes(length: decompressed.readableBytes) ?? []
    #expect(Data(bytes) == payload, "round trip must be byte-identical")
  }

  @Test("The output is a real gzip stream, not a bare deflate one")
  func gzipFraming() throws {
    // `Content-Encoding: gzip` means RFC 1952 framing. A client handed a raw deflate stream
    // under that header fails to decode, which is the kind of thing that works in curl (which
    // is lenient) and fails in a phone.
    let payload = Data(String(repeating: "bluebubbles ", count: 500).utf8)
    var compressed = try #require(ResponseCompression.gzip(payload))
    let header = compressed.getBytes(at: compressed.readerIndex, length: 3) ?? []
    #expect(header == [0x1f, 0x8b, 0x08], "gzip magic + deflate method")
  }

  // MARK: - The request side

  @Test("The context reads the header, case-insensitively")
  func contextReadsHeader() {
    // Header casing is not guaranteed across HTTP versions: HTTP/2 lowercases everything.
    var context = APIRequestContext(
      method: .post, path: "/api/v1/message/query",
      headers: ["Accept-Encoding": "gzip, deflate"])
    #expect(context.acceptsGzipEncoding)

    context = APIRequestContext(
      method: .post, path: "/api/v1/message/query",
      headers: ["accept-encoding": "gzip"])
    #expect(context.acceptsGzipEncoding)

    context = APIRequestContext(method: .post, path: "/api/v1/message/query")
    #expect(!context.acceptsGzipEncoding)
  }
}

//  AttributedBodyTests
//  The decoder behind `message.attributedBody`, and its wire shape.
//
//  This is the highest-consequence parser in the read path: `message.text` is frequently NULL
//  from Ventura onward, so a message the decoder cannot read is a message with no text. It
//  fails quietly — the row comes back, `text` is null, the client shows an empty bubble.
//
//  Archives here are built with `NSArchiver`, the class that wrote the ones in chat.db, so
//  these exercise the real format rather than an approximation of it.

import BBSerialization
import Foundation
import Testing

@testable import BBIMessage

// MARK: - Helpers

enum Archive {

  /// A `typedstream` archive of an attributed string, as chat.db stores them.
  static func typedStream(
    _ string: String,
    attributes: [(NSRange, [NSAttributedString.Key: Any])] = []
  ) -> Data {
    let attributed = NSMutableAttributedString(string: string)
    for (range, values) in attributes {
      attributed.addAttributes(values, range: range)
    }
    // Deprecated, and the only writer for this format — the same reason the decoder uses
    // NSUnarchiver. NSKeyedArchiver would produce a different format entirely, so there is
    // nothing to migrate to. See the DeprecatedDeclaration exception in swift-pr.yml.
    return NSArchiver.archivedData(withRootObject: attributed)
  }

  /// The Ventura-and-later alternative: an NSKeyedArchiver binary plist.
  static func keyedArchive(_ string: String) throws -> Data {
    try NSKeyedArchiver.archivedData(
      withRootObject: NSAttributedString(string: string), requiringSecureCoding: false
    )
  }
}

// MARK: - Decoding

@Suite("Attributed body decoding")
struct AttributedBodyDecodingTests {

  @Test("A typedstream archive decodes to its text")
  func decodesText() throws {
    let decoded = try AttributedBodyDecoder.decode(Archive.typedStream("Hello, world"))
    #expect(decoded.string == "Hello, world")
    #expect(decoded.text == "Hello, world")
  }

  /// Runs are what carry mentions, links and file-transfer GUIDs. The hand-rolled reader
  /// this replaced recovered none of them.
  @Test("Attribute runs survive with their ranges and values")
  func decodesRuns() throws {
    let data = Archive.typedStream(
      "Hello there",
      attributes: [
        (
          NSRange(location: 0, length: 5),
          [NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0)]
        )
      ]
    )

    let decoded = try AttributedBodyDecoder.decode(data)
    let attributed = decoded.runs.first { !$0.attributes.isEmpty }
    let run = try #require(attributed)

    #expect(run.location == 0)
    #expect(run.length == 5)
    #expect(run.attributes["__kIMMessagePartAttributeName"] == .integer(0))
  }

  /// THE test for the Objective-C shim. NSUnarchiver raises
  /// `NSArchiverArchiveInconsistency` on a truncated archive, and an uncaught Objective-C
  /// exception terminates the process — measured: a 13-byte truncation aborts with SIGABRT.
  /// chat.db is written by Messages while we read it, so torn rows happen. If this test
  /// ever stops passing, it will not fail — the test runner will crash.
  @Test("A truncated archive is an error, not a crash")
  func truncatedArchiveDoesNotCrash() {
    let full = Archive.typedStream("Some message text here")
    // Past the header, partway through the body: the case that raises.
    let truncated = full.prefix(full.count / 2)

    #expect(throws: AttributedBodyError.self) {
      _ = try AttributedBodyDecoder.decode(Data(truncated))
    }
  }

  @Test("Garbage decodes to an error rather than a crash or a wrong answer")
  func garbageIsAnError() {
    #expect(throws: AttributedBodyError.self) {
      _ = try AttributedBodyDecoder.decode(Data([0x01, 0x02, 0x03, 0x04]))
    }
  }

  @Test("Empty data is empty, not an error")
  func emptyData() throws {
    let decoded = try AttributedBodyDecoder.decode(Data())
    #expect(decoded == .empty)
    #expect(decoded.text.isEmpty)
  }

  /// Multi-byte text is where a length-prefix bug shows up.
  @Test("Unicode survives the round trip")
  func unicode() throws {
    let text = "Grüße 👋 from Zürich"
    #expect(try AttributedBodyDecoder.decode(Archive.typedStream(text)).string == text)
  }
}

@Suite("Message text extraction")
struct MessageTextExtractionTests {

  /// U+FFFC is where an attachment sits. Clients render the attachment, so leaving the
  /// placeholder in produces a stray glyph beside it. Matches Node's `sanitizeStr`.
  @Test("The attachment placeholder is stripped from text but kept in string")
  func placeholderHandling() throws {
    let decoded = try AttributedBodyDecoder.decode(
      Archive.typedStream("\u{FFFC}Caption below the image")
    )

    #expect(decoded.text == "Caption below the image")
    // `string` stays raw: run ranges are indexed against it, and stripping would put
    // every range out of alignment with the text it describes.
    #expect(decoded.string.contains("\u{FFFC}"))
  }

  @Test("An attachment-only message has empty text")
  func attachmentOnly() throws {
    #expect(try AttributedBodyDecoder.decode(Archive.typedStream("\u{FFFC}")).text.isEmpty)
  }

  @Test("Surrounding whitespace is trimmed")
  func trimsWhitespace() throws {
    #expect(try AttributedBodyDecoder.decode(Archive.typedStream("  padded  ")).text == "padded")
  }
}

@Suite("Archive format routing")
struct ArchiveRoutingTests {

  /// Two formats live in this column and feeding one to the other's reader yields garbage
  /// rather than an error, so they are told apart by magic bytes — not by OS version, since
  /// a restored database can carry either.
  @Test("bplist magic is detected")
  func detectsBinaryPlist() throws {
    #expect(AttributedBodyDecoder.isBinaryPlist(try Archive.keyedArchive("x")))
    #expect(!AttributedBodyDecoder.isBinaryPlist(Archive.typedStream("x")))
    #expect(!AttributedBodyDecoder.isBinaryPlist(Data("bplis".utf8)))
    #expect(!AttributedBodyDecoder.isBinaryPlist(Data()))
  }

  @Test("A keyed archive decodes through the class-restricted path")
  func keyedArchiveDecodes() throws {
    let decoded = try AttributedBodyDecoder.decode(try Archive.keyedArchive("Archived text"))
    #expect(decoded.text == "Archived text")
  }
}

// MARK: - Wire shape

@Suite("Attributed body wire format")
struct AttributedBodyWireTests {

  /// `[{ string, runs: [{ range: [loc, len], attributes }] }]`. The array wrapper matters:
  /// the client's own text extraction walks it looking for the first element with a
  /// non-empty `string`, so a bare object breaks text on the client too.
  @Test("The legacy shape is an array of string plus runs")
  func legacyShape() throws {
    let body = try AttributedBodyDecoder.decode(
      Archive.typedStream(
        "Hi",
        attributes: [
          (
            NSRange(location: 0, length: 2),
            [NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0)]
          )
        ]
      )
    )
    let encoded = AttributedBodyWire.encode(body, format: .legacy)

    guard case .array(let elements) = encoded, let first = elements.first else {
      Issue.record("expected an array wrapper")
      return
    }
    #expect(first["string"] == .string("Hi"))

    guard case .array(let runs)? = first["runs"], let run = runs.first else {
      Issue.record("expected runs")
      return
    }
    #expect(run["range"] == .array([.int(0), .int(2)]))
    #expect(run["attributes"]?["__kIMMessagePartAttributeName"] == .int(0))
  }

  /// `node-typedstream` cannot decode NSData- or NSURL-valued attributes: it omits the
  /// former and yields `undefined` for the latter, which JSON.stringify drops. Both are
  /// absent from the current wire, so legacy mode reproduces that — measured against 4,000
  /// live rows, where legacy output matched Node's on all 4,000.
  @Test("Legacy omits the values node-typedstream could not decode")
  func legacyOmitsUndecodableValues() throws {
    let data = Archive.typedStream(
      "Link",
      attributes: [
        (
          NSRange(location: 0, length: 4),
          [
            NSAttributedString.Key("__kIMLinkAttributeName"): URL(string: "https://example.com")!,
            NSAttributedString.Key("__kIMDataDetectedAttributeName"): Data([0x01, 0x02]),
          ]
        )
      ]
    )
    let body = try AttributedBodyDecoder.decode(data)

    let legacy = AttributedBodyWire.encode(body, format: .legacy)
    let legacyAttributes = try #require(firstRunAttributes(of: legacy))
    #expect(!legacyAttributes.contains("__kIMLinkAttributeName"))
    #expect(!legacyAttributes.contains("__kIMDataDetectedAttributeName"))
  }

  /// The additive mode. Belongs behind per-device capability negotiation, not switched on
  /// globally, because a new key is a parity diff.
  @Test("Extended includes them, as a URL string and base64")
  func extendedIncludesThem() throws {
    let payload = Data([0x01, 0x02])
    let data = Archive.typedStream(
      "Link",
      attributes: [
        (
          NSRange(location: 0, length: 4),
          [
            NSAttributedString.Key("__kIMLinkAttributeName"): URL(string: "https://example.com")!,
            NSAttributedString.Key("__kIMDataDetectedAttributeName"): payload,
          ]
        )
      ]
    )
    let encoded = AttributedBodyWire.encode(
      try AttributedBodyDecoder.decode(data), format: .extended
    )

    guard case .array(let elements) = encoded,
      case .array(let runs)? = elements.first?["runs"],
      let attributes = runs.first(where: { ($0["attributes"]?.objectKeys.isEmpty == false) })?[
        "attributes"]
    else {
      Issue.record("expected a populated run")
      return
    }

    #expect(attributes["__kIMLinkAttributeName"] == .string("https://example.com"))
    #expect(attributes["__kIMDataDetectedAttributeName"] == .string(payload.base64EncodedString()))
  }

  private func firstRunAttributes(of encoded: JSONValue) -> Set<String>? {
    guard case .array(let elements) = encoded,
      case .array(let runs)? = elements.first?["runs"]
    else { return nil }
    return runs.reduce(into: Set<String>()) { keys, run in
      keys.formUnion(run["attributes"]?.objectKeys ?? [])
    }
  }
}

// MARK: - Property-list blobs

@Suite("Property-list blob columns")
struct PropertyListWireTests {

  /// `messageSummaryInfo` and `payloadData` reach clients DECODED, wrapped in an array —
  /// `messageSummaryInfo?.[0]?.retractedParts` is a real client-side access. Emitting
  /// base64, as the first pass of this port did, breaks every one of those reads.
  @Test("A plist blob decodes to an array-wrapped object")
  func decodesToArrayWrappedObject() throws {
    let plist: [String: Any] = ["ust": 1, "amc": 2]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .binary, options: 0
    )

    let decoded = try #require(PropertyListWire.decode(data))
    guard case .array(let elements) = decoded, let first = elements.first else {
      Issue.record("expected an array wrapper")
      return
    }
    #expect(first["ust"] == .int64(1))
    #expect(first["amc"] == .int64(2))
  }

  /// Property lists carry two types JSON does not.
  /// `Date` becomes an ISO 8601 STRING here, not epoch milliseconds — the one place on this
  /// wire where that is right.
  ///
  /// The epoch-ms rule governs the serializer's own date fields, which the reference
  /// converts by hand with `.getTime()`. Nothing converts the insides of a decoded blob:
  /// TypeORM hands back a JS `Date` and `JSON.stringify` renders it as ISO. Measured against
  /// a live Electron server, where `chat.properties[0].markedAsKnownDate` is
  /// `"2026-03-23T14:38:18.937Z"`. This test asserted the epoch-ms form and was asserting
  /// the bug.
  @Test("Data becomes base64 and Date becomes an ISO 8601 string")
  func convertsNonJSONTypes() throws {
    let payload = Data([0xDE, 0xAD])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["blob": payload, "when": date], format: .binary, options: 0
    )

    let decoded = try #require(PropertyListWire.decode(data))
    guard case .array(let elements) = decoded, let first = elements.first else {
      Issue.record("expected an array wrapper")
      return
    }
    #expect(first["blob"] == .string(payload.base64EncodedString()))
    #expect(first["when"] == .string("2023-11-14T22:13:20.000Z"))
  }

  /// Sub-millisecond precision is TRUNCATED, not rounded.
  ///
  /// A plist `NSDate` is a double of seconds since 2001, so it carries more precision than
  /// JSON does. JavaScript's `new Date(ms)` truncates; a formatter handed the raw value
  /// rounds. Measured, the two disagreed by one millisecond on about half of all real
  /// dates — `…18.937Z` against `…18.938Z` — which nothing notices until something compares
  /// two timestamps for equality.
  @Test("Sub-millisecond precision is truncated, matching JavaScript")
  func truncatesSubMilliseconds() throws {
    // .9375 of a second: rounding to milliseconds gives .938, truncating gives .937.
    let date = Date(timeIntervalSince1970: 1_700_000_000.9375)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["when": date], format: .binary, options: 0
    )

    let decoded = try #require(PropertyListWire.decode(data))
    guard case .array(let elements) = decoded, let first = elements.first else {
      Issue.record("expected an array wrapper")
      return
    }
    #expect(first["when"] == .string("2023-11-14T22:13:20.937Z"))
  }

  @Test("An unreadable blob costs the field, not the message")
  func malformedBlobReturnsNil() {
    #expect(PropertyListWire.decode(Data([0x00, 0x01, 0x02])) == nil)
    #expect(PropertyListWire.decode(Data()) == nil)
    #expect(PropertyListWire.decode(nil) == nil)
  }

  @Test("A decoded plist is JSON-serializable")
  func outputIsSerializable() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["blob": Data([0x01]), "when": Date()], format: .binary, options: 0
    )
    let decoded = try #require(PropertyListWire.decode(data))
    #expect(throws: Never.self) { try decoded.serialize() }
  }
}

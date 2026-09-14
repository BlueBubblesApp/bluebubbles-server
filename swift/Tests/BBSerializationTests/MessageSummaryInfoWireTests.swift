//  MessageSummaryInfoWireTests
//  The shape an edited message reaches a client in.
//
//  **Why this suite exists.** `messageSummaryInfo` shipped as a raw passthrough of the
//  `message_summary_info` plist: short Apple keys, nested typedstreams as base64, and none of
//  the three structural rewrites the reference performs. The client reads `editedParts`,
//  `editedContent` and `originalTextRange`, finds none of them, parses the message as
//  unedited, and shows the original text with no indication it was changed. Unsends kept
//  working throughout, which is what made it look like an edit-specific problem: `rp` is the
//  one key the reference also leaves short, so it was the one key that arrived.
//
//  Nothing caught it. The parity corpus contains eight non-null `messageSummaryInfo` values
//  and not one of them is an edited message: the recorded `message/:id/edit` response is
//  `[{"ust": true}]`, captured before Messages had written the history, so there were no keys
//  to disagree about. And `PropertyListWireTests` asserted `first["amc"] == 2` under a doc
//  comment citing `messageSummaryInfo?.[0]?.retractedParts` as "a real client-side access":
//  the comment named the contract and the test pinned its opposite.
//
//  **The expectations below are not derived from our code.** They were produced by running
//  `node-typedstream@1.4.0` — the library the reference decodes every plist blob with — over
//  a real `message_summary_info` row from a live chat.db, and transcribed from its output.
//  That is what makes this a contract test rather than a restatement.

import BBIMessage
import Foundation
import Testing

@testable import BBSerialization

@Suite("messageSummaryInfo wire shape")
struct MessageSummaryInfoWireTests {

  /// A typedstream archive of an `NSAttributedString`, as `ec` holds one per revision.
  ///
  /// Built rather than pasted: `TestDataPolicyTests` refuses real message content in a
  /// fixture, and a hand-rolled archive would be a guess at the format. `AttributedBody`
  /// round-trips through the same decoder the serializer uses.
  private func archivedAttributedString(_ text: String) -> Data {
    // `NSArchiver`, the class that wrote the ones in chat.db, so this exercises the real
    // format rather than an approximation of it; the same choice `AttributedBodyTests` makes.
    NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
  }

  private func plist(_ object: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
  }

  /// The whole shape, against the reference's own output for an edited single-part message.
  @Test("An edited message arrives in the shape the client parses")
  func editedMessage() throws {
    let first = archivedAttributedString("before")
    let second = archivedAttributedString("after")
    let data = try plist([
      "amc": 0,
      "ust": true,
      "ep": [0],
      "otr": ["0": ["lo": 0, "le": 6]],
      "ec": ["0": [["t": first, "d": 810_847_000.5], ["t": second, "d": 810_847_022.25]]],
    ])

    let decoded = try #require(PropertyListWire.decode(data))
    let summary = try #require(decoded[0])

    // 1. The keys are renamed.
    #expect(summary["editedParts"] == .array([.int64(0)]))
    #expect(summary["associatedMessageContent"] == .int64(0))
    // Unknown keys pass through untouched: `ust` is not in the reference's map.
    #expect(summary["ust"] == .bool(true))
    // And the short spellings are gone, not duplicated.
    #expect(summary["ep"] == nil)
    #expect(summary["amc"] == nil)
    #expect(summary["ec"] == nil)
    #expect(summary["otr"] == nil)

    // 2. A part-indexed map holding only part 0 collapses to that part's value, and a
    //    `{lo, le}` range becomes `[location, length]`. `MessageSummaryInfo.fromJson`
    //    branches on exactly this: `originalTextRange is List`.
    #expect(summary["originalTextRange"] == .array([.int64(0), .int64(6)]))

    // 3. The edit history is a bare array (collapsed), each revision carrying a DECODED
    //    attributed string under `text`, not base64. The client reads
    //    `EditedContent.text.values.first` and hands it to `AttributedBody.fromMap`.
    let history = try #require(summary["editedContent"]?.arrayValue)
    #expect(history.count == 2)
    #expect(history[0]["date"] == .double(810_847_000.5))
    let values = try #require(history[0]["text"]?["values"]?.arrayValue)
    #expect(values[0]["string"] == .string("before"))
    #expect(history[1]["text"]?["values"]?[0]?["string"] == .string("after"))
    // The typed-group wrapper the reference emits: `decodeAll()[0]` is a `TypedGroup`, and
    // a single archived object encodes as "@".
    #expect(history[0]["text"]?["encodings"] == .array([.string("@")]))
  }

  /// The key the reference does NOT rename, and the reason edits broke while unsends did not.
  @Test("retracted parts stay short, because the reference leaves them short")
  func retractedPartsAreNotRenamed() throws {
    let data = try plist(["rp": [0], "otr": ["0": ["lo": 0, "le": 25]], "ust": true])
    let summary = try #require(PropertyListWire.decode(data)?[0])
    // `rp` is absent from `BPlistReader.nameMap`, so it arrives short and the client's
    // `json["retractedParts"] ?? json["rp"]` fallback is what reads it. Renaming it here
    // would send a key nothing looks for and remove the one that works.
    #expect(summary["rp"] == .array([.int64(0)]))
    #expect(summary["retractedParts"] == nil)
  }

  @Test("the editing handle is renamed")
  func editingUserHandle() throws {
    let data = try plist(["euh": ["+15550001111"], "eogcd": 6, "enc": true])
    let summary = try #require(PropertyListWire.decode(data)?[0])
    #expect(summary["editingUserHandle"] == .array([.string("+15550001111")]))
    // Everything the reference does not name is left exactly as Apple wrote it.
    #expect(summary["eogcd"] == .int64(6))
    #expect(summary["enc"] == .bool(true))
  }

  /// A multi-part map must NOT collapse; the client's other branch handles it.
  @Test("a multi-part map keeps its part keys")
  func multiPartDoesNotCollapse() throws {
    let zero = archivedAttributedString("zero")
    let one = archivedAttributedString("one")
    let data = try plist([
      "ec": ["0": [["t": zero, "d": 1.0]], "1": [["t": one, "d": 2.0]]],
      "ep": [0, 1],
    ])
    let summary = try #require(PropertyListWire.decode(data)?[0])
    let content = try #require(summary["editedContent"])
    // Still a map, keyed by part: `MessageSummaryInfo.fromJson` takes its Map branch here.
    #expect(content["0"]?.arrayValue?.count == 1)
    #expect(content["1"]?[0]?["text"]?["values"]?[0]?["string"] == .string("one"))
  }

  /// The reference's own rule, faithfully, including where it loses a part.
  @Test("a map with part 0 and part 2 collapses, as the reference does")
  func collapseFollowsTheReferenceEvenWhenLossy() throws {
    let zero = archivedAttributedString("zero")
    let two = archivedAttributedString("two")
    let data = try plist([
      "ec": ["0": [["t": zero, "d": 1.0]], "2": [["t": two, "d": 2.0]]]
    ])
    let summary = try #require(PropertyListWire.decode(data)?[0])
    // `BPlistReader.process` tests "has 0 and not 1", so part 2 is dropped. Reproduced
    // rather than corrected: a client reads the collapsed form as part 0 either way, and
    // sending the map would be a shape no shipped client expects here. Pinned so the
    // divergence is a decision somebody made rather than one that drifts in.
    #expect(summary["editedContent"]?.arrayValue?.count == 1)
    #expect(summary["editedContent"]?[0]?["text"]?["values"]?[0]?["string"] == .string("zero"))
  }

  /// A blob that is not an archive keeps its bytes rather than costing the field.
  @Test("undecodable data falls back to base64")
  func undecodableData() throws {
    let data = try plist(["blob": Data([0x01, 0x02, 0x03])])
    let summary = try #require(PropertyListWire.decode(data)?[0])
    #expect(summary["blob"] == .string(Data([0x01, 0x02, 0x03]).base64EncodedString()))
  }
}

/// `payloadData` is an `NSKeyedArchiver` archive, and a keyed archive is UIDs all the way
/// down. Rendering one as `null` does not lose a value, it loses the graph.
@Suite("Keyed-archiver UIDs on the wire")
struct KeyedArchiverUIDWireTests {

  /// A real archive, built the way Messages builds a rich-link payload: `NSKeyedArchiver`.
  private func archive(_ root: Any) throws -> Data {
    try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
  }

  @Test("a UID reaches the client as {\"UID\": n}, not null")
  func uidIsSerialized() throws {
    let decoded = try #require(PropertyListWire.decode(try archive(["a", "b"])))
    let plist = try #require(decoded[0])

    // `$top.root` is the entry point into `$objects`; without it a client cannot begin.
    #expect(plist["$top"]?["root"] == .object(["UID": .int(1)]))
    #expect(plist["$archiver"] == .string("NSKeyedArchiver"))

    // And every reference inside, `$class` included, rather than just the root.
    let objects = try #require(plist["$objects"]?.arrayValue)
    let container = objects[1]
    #expect(container["$class"] != .null)
    if case .object(let fields)? = container["$class"] {
      #expect(fields["UID"] != nil)
    } else {
      Issue.record("$class should be a UID reference")
    }
  }

  /// The case a single-byte reader truncates silently.
  @Test("a UID past 255 is not truncated")
  func multiByteUID() throws {
    // More than 255 objects, so the binary plist widens its UIDs to two bytes.
    let many = (0..<400).map { "entry-\($0)" }
    let decoded = try #require(PropertyListWire.decode(try archive(many)))
    let objects = try #require(decoded[0]?["$objects"]?.arrayValue)
    let references = try #require(objects[1]["NS.objects"]?.arrayValue)

    let values = references.compactMap { $0["UID"]?.intValue }
    #expect(values.count == 400)
    // Strictly increasing and past the single-byte boundary: a width bug shows up as a
    // wrapped value here rather than as a plausible-looking number.
    #expect(values == Array(2...401))
  }

  /// The extraction must not mistake anything else for a UID.
  @Test("other plist values are untouched")
  func nonUIDsAreNotMisread() throws {
    // Key names chosen to avoid `renamedKeys`: `d` here would arrive as `date`, which is
    // correct and would make this test about the renaming instead.
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["n": 7, "s": "text", "b": true, "blob": Data([0xFF])] as [String: Any],
      format: .binary, options: 0)
    let plist = try #require(PropertyListWire.decode(data)?[0])
    #expect(plist["n"] == .int64(7))
    #expect(plist["s"] == .string("text"))
    #expect(plist["b"] == .bool(true))
    // Not a UID, and not mistaken for one: still base64.
    #expect(plist["blob"] == .string(Data([0xFF]).base64EncodedString()))
  }

  /// Both shapes are real, and both come from `chat.properties` rather than from
  /// `message_summary_info`: a live Mac's blob carries
  /// `com.apple.iChat.LastArchivedMessageID`, whose value is `[String, Int]`.
  ///
  /// Written as a unit test because the corpus cannot check it. `chat.properties` is a
  /// free-form dictionary whose KEYS are per-chat data — two chats recorded from the same
  /// Mac carry different sets — so a synthetic blob in the fixture database satisfies one
  /// recorded fixture and is "unexpected" in the next. That was measured, not assumed: a
  /// blob was added to the generator, and the key that made
  /// `GET /message/:guid` match made `GET /chat/:guid` fail. The decode is testable; the
  /// cross-database key match is not.
  @Test("a reverse-DNS key and a mixed-type array survive the plist path")
  func dottedKeysAndMixedArrays() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        // The dots are the point: this is the one key name that could collide with the
        // parity diff's own dotted paths, and with any code that splits a key on ".".
        "com.apple.iChat.LastArchivedMessageID": ["33333333-0000-0000-0000-000000000001", 130_936],
        "shouldForceToSMS": false,
        "numberOfTimesRespondedtoThread": 3,
      ] as [String: Any],
      format: .binary, options: 0)

    let plist = try #require(PropertyListWire.decode(data)?[0])

    // The key arrives whole, not split into nested objects.
    let archived = try #require(plist["com.apple.iChat.LastArchivedMessageID"]?.arrayValue)
    #expect(archived.count == 2)
    #expect(archived[0] == .string("33333333-0000-0000-0000-000000000001"))
    #expect(archived[1] == .int64(130_936))

    // And nothing else in the blob was disturbed by the odd key beside it.
    #expect(plist["shouldForceToSMS"] == .bool(false))
    #expect(plist["numberOfTimesRespondedtoThread"] == .int64(3))
  }

  @Test("an object that is not a property list answers nil rather than raising")
  func invalidObject() {
    // `data(fromPropertyList:)` throws for one of these, and a throw is catchable where an
    // Objective-C exception would take the process with it.
    final class NotAPropertyList: NSObject {}
    #expect(PropertyListWire.uidValue(NotAPropertyList()) == nil)
    #expect(PropertyListWire.uidValue("a string") == nil)
    #expect(PropertyListWire.uidValue(42) == nil)
  }
}

extension MessageSummaryInfoWireTests {

  /// The one place this server's `messageSummaryInfo` differs from the reference's.
  ///
  /// The reference decodes a NESTED attributed string with `BinaryDecoding.all`, so an
  /// attribute holding undecodable `NSData` survives as a bare array of octets; the
  /// top-level `attributedBody` uses `.decodable` and drops it, which is what
  /// `AttributedBodyWireFormat.legacy` reproduces. We apply the caller's format in both
  /// places, so a data attribute inside an edit is dropped too.
  ///
  /// Measured over sixty live rows: exactly one carried such an attribute, and everything a
  /// client reads — text, ranges, part indices, dates, `editedParts`, `originalTextRange` —
  /// matched the reference on every one of them. Asserted here so the divergence is a
  /// decision somebody made rather than something that drifts.
  @Test("a data attribute inside an edit follows the top-level format choice")
  func nestedAttributeFormat() throws {
    let attributed = NSMutableAttributedString(string: "detected")
    attributed.addAttribute(
      NSAttributedString.Key("__kIMCalendarEventAttributeName"),
      value: Data("bplist00".utf8), range: NSRange(location: 0, length: 8))
    let archived = NSArchiver.archivedData(withRootObject: attributed)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["ec": ["0": [["t": archived, "d": 1.0]]]] as [String: Any],
      format: .binary, options: 0)

    // `.legacy`, the default and what the top-level body uses: the attribute is absent.
    let legacy = try #require(PropertyListWire.decode(data)?[0])
    let legacyAttributes = try #require(
      legacy["editedContent"]?[0]?["text"]?["values"]?[0]?["runs"]?[0]?["attributes"])
    #expect(legacyAttributes["__kIMCalendarEventAttributeName"] == nil)

    // `.extended` carries it, as base64 — the encoding this server uses for recovered data
    // everywhere, and not the reference's octet array.
    let extended = try #require(
      PropertyListWire.decode(data, attributedBodyFormat: .extended)?[0])
    let extendedAttributes = try #require(
      extended["editedContent"]?[0]?["text"]?["values"]?[0]?["runs"]?[0]?["attributes"])
    #expect(extendedAttributes["__kIMCalendarEventAttributeName"] != nil)
  }
}

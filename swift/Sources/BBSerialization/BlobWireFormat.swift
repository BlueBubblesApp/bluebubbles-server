//  BlobWireFormat
//  The three chat.db blob columns, as clients receive them.
//
//  `attributedBody`, `messageSummaryInfo` and `payloadData` are all typed `NodeJS.Dict<any>[]`
//  on the v1 wire: DECODED STRUCTURES, not base64. The first pass of this port emitted
//  base64 for all three, which every existing client would fail to read: they index into the
//  object.
//
//  See `.claude/docs/api.md` and `.claude/docs/imessage.md`.

import BBIMessage
import Foundation

// MARK: - attributedBody

/// How much of the decoded attributed string to put on the wire.
///
/// The native decoder recovers strictly more than `node-typedstream` did, which is a
/// compatibility question rather than a free win: emitting a key the reference omits is
/// a diff the parity harness will flag, and a strict client parser may reject.
public enum AttributedBodyWireFormat: String, Sendable, CaseIterable {

  /// Byte-for-byte what the Node server produces, including what it fails to produce.
  ///
  /// `node-typedstream` cannot decode `NSData`- or `NSURL`-valued attributes: it omits the
  /// former entirely and yields `undefined` for the latter, which `JSON.stringify` then
  /// drops. Both are therefore ABSENT from the v1 wire, and this mode reproduces that.
  /// Verified against 4,000 live rows, not inferred.
  case legacy

  /// Everything the native decoder recovers.
  ///
  /// Adds `__kIMDataDetectedAttributeName`, `__kIMCalendarEventAttributeName`,
  /// `__kIMPhoneNumberAttributeName` and `__kIMAddressAttributeName` as base64, and real
  /// URLs for `__kIMLinkAttributeName`. Additive, so it belongs behind the per-device
  /// capability negotiation rather than being switched on globally.
  case extended
}

public enum AttributedBodyWire {

  /// Encodes to the array shape clients parse: `[{ string, runs: [{ range, attributes }] }]`.
  ///
  /// The array wrapper is not decoration: `AttributedBodyUtils.extractText` walks it
  /// looking for the first element with a non-empty `string`, so a bare object would break
  /// text extraction on the client side too.
  public static func encode(
    _ body: AttributedBody,
    format: AttributedBodyWireFormat = .legacy
  ) -> JSONValue {
    let runs = body.runs.map { run -> JSONValue in
      var attributes: [String: JSONValue] = [:]
      for (key, value) in run.attributes {
        guard let encoded = encode(value, format: format) else { continue }
        attributes[key] = encoded
      }
      return .object([
        // [location, length]: an array, matching NSRange's field order.
        "range": .array([.int(run.location), .int(run.length)]),
        "attributes": .object(attributes),
      ])
    }

    return .array([.object(["string": .string(body.string), "runs": .array(runs)])])
  }

  /// Returns nil for a value this format omits.
  static func encode(_ value: AttributeValue, format: AttributedBodyWireFormat) -> JSONValue? {
    switch value {
    case .string(let string): .string(string)
    case .integer(let number): .int(number)
    case .double(let number): .double(number)
    case .boolean(let flag): .bool(flag)
    case .null: .null

    // The two the legacy decoder loses. Omitted rather than nulled, because "absent" is
    // what the v1 wire actually shows.
    case .data(let data):
      format == .extended ? .string(data.base64EncodedString()) : nil
    case .url(let string):
      format == .extended ? .string(string) : nil

    case .array(let values):
      .array(values.compactMap { encode($0, format: format) })
    case .dictionary(let values):
      .object(values.compactMapValues { encode($0, format: format) })

    // A class the decoder does not model. Never guessed at.
    case .unsupported:
      nil
    }
  }
}

// MARK: - messageSummaryInfo and payloadData

/// Decodes the two property-list blob columns.
///
/// Both are plain binary plists (500/500 sampled `message_summary_info` rows were `bplist`,
/// none typedstream) so `PropertyListSerialization` reads them natively. The current server
/// routes them through the same decoder as `attributedBody` and publishes the result as an
/// array of dictionaries; that array shape is what clients index into.
public enum PropertyListWire {

  /// The key renames the reference performs, and the only ones it performs.
  ///
  /// Transcribed from `node-typedstream`'s `BPlistReader.nameMap`, which is what the
  /// reference runs every plist blob through (`AttributedBodyTransformer` →
  /// `convertAttributedBody` → `Unarchiver.open` → `BPlistReader`). Verified by running that
  /// library against a real `message_summary_info` row, not read off the source alone.
  ///
  /// **`rp` is deliberately absent**, and that is not an oversight to tidy: the reference
  /// leaves retracted parts short, the BlueBubbles client reads `json["retractedParts"] ??
  /// json["rp"]` because of it, and renaming it here would send a key no client looks for
  /// while removing the one it falls back to. It is also the reason unsends kept working
  /// while edits did not, which is what identified this bug.
  static let renamedKeys: [String: String] = [
    "ec": "editedContent",
    "ep": "editedParts",
    "euh": "editingUserHandle",
    "bcg": "backwardsCompatibilityGuid",
    "d": "date",
    "t": "text",
    "otr": "originalTextRange",
    "amc": "associatedMessageContent",
    "ams": "associatedMessageSummary",
  ]

  /// Returns nil when the blob is absent or unreadable. A malformed blob costs that one
  /// field, never the message.
  ///
  /// - Parameter attributedBodyFormat: how a NESTED archived attributed string is encoded.
  ///   `ec`'s edit history is a typedstream inside the plist, so the same choice that
  ///   governs the top-level `attributedBody` governs these.
  public static func decode(
    _ data: Data?,
    attributedBodyFormat: AttributedBodyWireFormat = .legacy
  ) -> JSONValue? {
    guard let data, !data.isEmpty else { return nil }
    guard
      let object = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      )
    else { return nil }

    // Wrapped in an array to match `NodeJS.Dict<any>[]`, which is what clients read:
    // `messageSummaryInfo?.[0]?.retractedParts` is a real access in the reference.
    return .array([convert(object, format: attributedBodyFormat)])
  }

  /// Property lists carry two types JSON does not have.
  ///
  /// `Data` becomes base64. `Date` becomes an **ISO 8601 string**, which contradicts the
  /// epoch-milliseconds rule everywhere else on this wire and is correct here.
  ///
  /// That rule governs the serializer's own date FIELDS (`dateCreated`, `dateRead`) which
  /// the reference converts by hand with `.getTime()`. Nothing converts the insides of a
  /// decoded blob: TypeORM's transformer hands back a JS `Date` and `JSON.stringify`
  /// renders it as ISO. So `chat.properties[0].markedAsKnownDate` has always been
  /// `"2026-08-28T18:55:12.667Z"` on the wire, and emitting a number there is a type change
  /// a client parsing the string will trip over.
  ///
  /// Measured against a live Electron server.
  static func convert(_ object: Any, format: AttributedBodyWireFormat = .legacy) -> JSONValue {
    switch object {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      let encoding = String(cString: number.objCType)
      if encoding == "d" || encoding == "f" { return .double(number.doubleValue) }
      return .int64(number.int64Value)
    case let string as String:
      return .string(string)
    case let data as Data:
      // A NESTED ARCHIVE, decoded, not base64.
      //
      // `ec` (the edit history) holds one typedstream per revision, and the reference
      // decodes each of them: `BPlistReader.process` runs `Unarchiver.open(data).decodeAll()`
      // on every Buffer it meets and only falls back to the raw bytes when that throws.
      // Emitting base64 here is what made an edited message arrive with its history
      // unreadable, so the client had nothing to render and showed the message unedited.
      //
      // The `encodings`/`values` wrapper is the decoded typed GROUP, not the string itself:
      // the reference returns `decodeAll()[0]`, which is a `TypedGroup`, where the top-level
      // `attributedBody` goes on to pull `.values` out of it. That is why the client models
      // an edit's text as `Content { values: [AttributedBody] }` and a message's body as a
      // bare array. `["@"]` is the encoding of a single archived object, which is what this
      // blob always holds; confirmed by running the reference decoder over a live row.
      //
      // ONE KNOWN DIVERGENCE, and it is the `.legacy` decision already taken for the
      // top-level `attributedBody`, met again one level down. The reference decodes the
      // top-level blob with `BinaryDecoding.decodable`, which DROPS an attribute whose value
      // is undecodable `NSData` — so `.legacy` matches it there. Nested inside `ec` it uses
      // the default `.all` instead and keeps those bytes, rendering them as a bare JSON
      // array of octets. Measured over sixty live rows: one carried
      // `__kIMCalendarEventAttributeName` on an edited message and is the only difference
      // in the set; every string, range, part index, date, `editedParts` and
      // `originalTextRange` matched exactly.
      //
      // Not reproduced, deliberately. Matching would mean emitting a bare byte array, a
      // shape this server produces nowhere else and that `.extended` (base64) does not
      // produce either, for a data-detector attribute the client never reads:
      // `Attributes.fromMap` names four keys and this is not one of them. Pinned by
      // `MessageSummaryInfoWireTests` so it stays a decision.
      if let body = try? AttributedBodyDecoder.decode(data) {
        return .object([
          "encodings": .array([.string("@")]),
          // `encode` already returns the `[{ string, runs }]` array wrapper, which IS the
          // `values` list: wrapping it again nests an array inside an array and the client
          // reads `values.first` as a list rather than an attributed body.
          "values": AttributedBodyWire.encode(body, format: format),
        ])
      }
      return .string(data.base64EncodedString())
    case let date as Date:
      // TRUNCATED to whole milliseconds, not rounded.
      //
      // A plist NSDate is a double of seconds since 2001, so it carries sub-millisecond
      // precision that JSON does not. JavaScript's `new Date(ms)` truncates; an
      // `ISO8601DateFormatter` given the raw value rounds. Measured, that is a
      // one-millisecond disagreement on roughly half of all dates:
      // `…18.937Z` there against `…18.938Z` here, which is invisible until something
      // compares two timestamps for equality.
      let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
      return .string(WireDate.iso(Date(timeIntervalSince1970: milliseconds / 1000)))
    case let array as [Any]:
      return .array(array.map { convert($0, format: format) })
    case let dictionary as [String: Any]:
      return convert(dictionary: dictionary, format: format)
    default:
      // A KEYED-ARCHIVER UID, which is the one plist type left that JSON has no shape for
      // and the one this arm used to swallow. See `uidValue`.
      if let uid = uidValue(object) { return .object(["UID": .int(uid)]) }
      return .null
    }
  }

  /// The integer inside a `CFKeyedArchiverUID`, or nil for anything else.
  ///
  /// **Why this matters more than a leaf type usually would.** `payloadData` is an
  /// `NSKeyedArchiver` archive, and in one of those every reference between objects is a UID
  /// into `$objects`: `$top.root`, every `$class`, every field of every object. Rendering
  /// them as `null` does not lose a value, it loses the entire object GRAPH, so a rich-link
  /// preview arrives as a flat pile of strings with nothing saying which belongs to which.
  /// The reference emits `{"UID": n}` (that is how `bplist-parser` models one, and
  /// `JSON.stringify` writes it), and a client walks the archive with it.
  ///
  /// **Read by re-encoding, which is the only PUBLIC way there is.** The type is
  /// `__NSCFType` with no Swift or Objective-C surface: it answers no selector, bridges to
  /// no `NSNumber`, and `CFKeyedArchiverUIDGetValue` is CoreFoundation SPI (exported as
  /// `_CFKeyedArchiverUIDGetValue`, reachable only through `dlsym`). The remaining options
  /// were that private symbol, scraping `{value = n}` out of the description, and this.
  ///
  /// So the object is written back out as a one-object binary plist and the value read from
  /// the bytes. The format is documented and fixed: `bplist00`, then the object table, so
  /// the root object begins at offset 8; a UID is marker `0x8N` where `N + 1` is the byte
  /// count, followed by that many big-endian bytes. Verified against both alternatives over
  /// a 400-object archive, including the two-byte UIDs past 255 that a single-byte reader
  /// would silently truncate.
  ///
  /// Anything that is not a UID fails the marker check and answers nil; an object that is
  /// not a property list at all makes `data(fromPropertyList:)` throw, which is caught here
  /// rather than raising. Both measured.
  static func uidValue(_ object: Any) -> Int? {
    guard
      let encoded = try? PropertyListSerialization.data(
        fromPropertyList: object, format: .binary, options: 0),
      encoded.count > 9
    else { return nil }
    let marker = encoded[8]
    // 0x8N is the UID marker. Every other type has its own high nibble.
    guard marker & 0xF0 == 0x80 else { return nil }
    let width = Int(marker & 0x0F) + 1
    guard encoded.count >= 9 + width else { return nil }
    return encoded[9..<(9 + width)].reduce(0) { $0 << 8 | Int($1) }
  }

  /// The three structural rewrites the reference performs on every plist dictionary.
  ///
  /// All three come from `BPlistReader.process`, and none of them are cosmetic: the client
  /// is written against their OUTPUT. `MessageSummaryInfo.fromJson` branches on
  /// `editedContent is List` for the collapsed form and reads `originalTextRange` as a
  /// two-element list, so a server that skips these sends a shape the client silently
  /// parses as empty.
  private static func convert(
    dictionary: [String: Any], format: AttributedBodyWireFormat
  ) -> JSONValue {
    // 1. A part-indexed map with only part 0 collapses to that part's value, so `ec` and
    //    `otr` arrive as a bare array on the overwhelmingly common single-part message.
    //
    //    **Reproduced exactly, including where it loses data.** The reference's test is
    //    "has `0` and not `1`", so a message edited in parts 0 and 2 collapses to part 0
    //    and part 2 is dropped. That is a bug in the reference and it is still the wire:
    //    a client reads the collapsed form as part 0 either way, and sending the map
    //    instead would be a shape no existing client expects on a message it can already
    //    display. Worth fixing upstream; not worth diverging over here.
    if dictionary["0"] != nil, dictionary["1"] == nil, let inner = dictionary["0"] {
      return convert(inner, format: format)
    }

    // 2. A range becomes `[location, length]`, matching how `attributedBody` writes one.
    if dictionary.count == 2, let location = dictionary["lo"], let length = dictionary["le"] {
      return .array([convert(location, format: format), convert(length, format: format)])
    }

    // 3. The short Apple keys become the long ones the client reads. An unknown key is
    //    passed through untouched, which is what keeps `ust`, `enc` and `eogcd` intact.
    var converted: [String: JSONValue] = [:]
    for (key, value) in dictionary {
      converted[renamedKeys[key] ?? key] = convert(value, format: format)
    }
    return .object(converted)
  }
}

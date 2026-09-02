//  BlobWireFormat
//  The three chat.db blob columns, as clients receive them.
//
//  `attributedBody`, `messageSummaryInfo` and `payloadData` are all typed `NodeJS.Dict<any>[]`
//  on the current wire — DECODED STRUCTURES, not base64. The first pass of this port emitted
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
/// compatibility question rather than a free win: emitting a key the current server omits is
/// a diff the parity harness will flag, and a strict client parser may reject.
public enum AttributedBodyWireFormat: String, Sendable, CaseIterable {

  /// Byte-for-byte what the Node server produces, including what it fails to produce.
  ///
  /// `node-typedstream` cannot decode `NSData`- or `NSURL`-valued attributes: it omits the
  /// former entirely and yields `undefined` for the latter, which `JSON.stringify` then
  /// drops. Both are therefore ABSENT from the current wire, and this mode reproduces that.
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
  /// The array wrapper is not decoration — `AttributedBodyUtils.extractText` walks it
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
        // [location, length] — an array, matching NSRange's field order.
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
    // what the current wire actually shows.
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
/// Both are plain binary plists — 500/500 sampled `message_summary_info` rows were `bplist`,
/// none typedstream — so `PropertyListSerialization` reads them natively. The current server
/// routes them through the same decoder as `attributedBody` and publishes the result as an
/// array of dictionaries; that array shape is what clients index into.
public enum PropertyListWire {

  /// Returns nil when the blob is absent or unreadable. A malformed blob costs that one
  /// field, never the message.
  public static func decode(_ data: Data?) -> JSONValue? {
    guard let data, !data.isEmpty else { return nil }
    guard
      let object = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      )
    else { return nil }

    // Wrapped in an array to match `NodeJS.Dict<any>[]`, which is what clients read —
    // `messageSummaryInfo?.[0]?.retractedParts` is a real access in the current code.
    return .array([convert(object)])
  }

  /// Property lists carry two types JSON does not have.
  ///
  /// `Data` becomes base64. `Date` becomes an **ISO 8601 string**, which contradicts the
  /// epoch-milliseconds rule everywhere else on this wire and is correct here.
  ///
  /// That rule governs the serializer's own date FIELDS — `dateCreated`, `dateRead` — which
  /// the reference converts by hand with `.getTime()`. Nothing converts the insides of a
  /// decoded blob: TypeORM's transformer hands back a JS `Date` and `JSON.stringify`
  /// renders it as ISO. So `chat.properties[0].markedAsKnownDate` has always been
  /// `"2026-08-28T18:55:12.667Z"` on the wire, and emitting a number there is a type change
  /// a client parsing the string will trip over.
  ///
  /// Measured against a live Electron server; the epoch-ms choice here was reasoned from
  /// the contract's general rule and was wrong for this one case.
  static func convert(_ object: Any) -> JSONValue {
    switch object {
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      let encoding = String(cString: number.objCType)
      if encoding == "d" || encoding == "f" { return .double(number.doubleValue) }
      return .int64(number.int64Value)
    case let string as String:
      return .string(string)
    case let data as Data:
      return .string(data.base64EncodedString())
    case let date as Date:
      // TRUNCATED to whole milliseconds, not rounded.
      //
      // A plist NSDate is a double of seconds since 2001, so it carries sub-millisecond
      // precision that JSON does not. JavaScript's `new Date(ms)` truncates; an
      // `ISO8601DateFormatter` given the raw value rounds. Measured, that is a
      // one-millisecond disagreement on roughly half of all dates —
      // `…18.937Z` there against `…18.938Z` here — which is invisible until something
      // compares two timestamps for equality.
      let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
      return .string(WireDate.iso(Date(timeIntervalSince1970: milliseconds / 1000)))
    case let array as [Any]:
      return .array(array.map(convert))
    case let dictionary as [String: Any]:
      return .object(dictionary.mapValues(convert))
    default:
      return .null
    }
  }
}

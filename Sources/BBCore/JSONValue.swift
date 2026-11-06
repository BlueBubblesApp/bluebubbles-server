//  JSONValue
//  A JSON document as a closed Swift value: the one representation every module below the
//  wire and the wire itself build, read and render.
//
//  In BBCore so that every layer can hold one without linking the layer that renders client
//  responses. The audit log is the reader that needs it: a record about a settings change
//  carries the new value as JSON, and BBAudit sits below the message layer. What this
//  placement prevents is a second, audit-only JSON enum, which has to re-implement `Codable`
//  and spell the withheld-secret marker on its own, and drifts from this one with nothing
//  to notice.
//
//  What renders a CLIENT response is `serialize()`, and its bytes are the frozen v1 contract
//  that the parity harness and the fixture replay hold. `Codable` is a separate codec for
//  documents this server stores and forwards itself (the audit log), never for the wire.
//
//  Kept apart on purpose, each for a reason stated in its own header: `WireJSON` (the helper
//  protocol, doubles only, in the contract the injected helper links instead of this module),
//  `OrderedJSON` (key order preserved, for a document committed and diffed in CI) and
//  `AttributeValue` (typedstream attribute values, which carry `Data`, URLs and unmodelled
//  classes that JSON cannot).

import Foundation

/// A JSON value with explicit presence.
///
/// Needed because "omit this key" and "emit null" are different outcomes, and Swift's
/// Optional plus synthesised Codable conflates them.
///
/// NOT `indirect`, which it used to be and did not need to be: the only recursive cases are
/// `array` and `object`, and `Array` and `Dictionary` already put their storage on the heap,
/// so the keyword bought nothing and cost a heap box per node. Measured on a 20,000-object
/// tree: the same footprint either way -- the dictionaries' own storage dominates, so the
/// often-repeated claim that this saves memory is not true -- and about 20% off the time to
/// build one, which is the allocations rather than the bytes.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int)
  case int64(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public var foundationObject: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    case .int(let value): value
    case .int64(let value): value
    case .double(let value): value
    case .string(let value): value
    case .array(let values): values.map(\.foundationObject)
    case .object(let values): values.mapValues(\.foundationObject)
    }
  }

  /// What a payload cannot be encoded as.
  public enum EncodingError: BBError, Equatable {
    /// JSON has no representation for NaN or an infinity.
    ///
    /// `JSONSerialization` does not throw for these: it raises an Objective-C
    /// `NSInvalidArgumentException`, which is not catchable from Swift and terminates the
    /// process. A response carrying a non-finite double took the server down with it.
    case notFinite(Double)

    public var code: String { "json.not_finite" }
    public var domain: String { "Serialization" }
    public var title: String { "A response could not be written" }

    /// What a client reads in the 500 when a response would have carried one: a server
    /// defect, so the sentence says what was refused rather than blaming the request.
    public var body: String {
      switch self {
      case .notFinite(let value):
        "The response contained a number JSON cannot represent (\(value)), so it was not sent."
      }
    }
  }

  /// UTF-8 JSON bytes.
  ///
  /// Written DIRECTLY rather than through `JSONSerialization`, which needs
  /// `foundationObject` first: a complete second tree of boxed `NSNumber`, `NSString` and
  /// `NSDictionary`, built entirely so it can be walked once and thrown away. Four
  /// representations of one response coexisted at peak -- the rows, this tree, the Foundation
  /// tree and the output `Data`.
  ///
  /// Key order is still arbitrary: `object` is a `[String: JSONValue]`, insertion order is
  /// not preserved and cannot be, so every comparison against recorded fixtures is
  /// structural rather than byte-for-byte. See `expectFrameEquivalent` in `SocketCodecTests`.
  ///
  /// Two DELIBERATE differences from `JSONSerialization`, both of which move toward the
  /// frozen v1 contract rather than away from it:
  ///
  /// - Doubles are written shortest-round-trip, so `0.1` is `0.1` where
  ///   `JSONSerialization` wrote `0.10000000000000001`. The Node reference emits `0.1`
  ///   (`JSON.stringify` uses the same algorithm), so every double this server has ever
  ///   sent has differed from the reference; it no longer does. The values parse identically
  ///   either way.
  /// - A non-finite double THROWS instead of terminating the process.
  ///
  /// `pretty` keeps the old path. It is for humans reading a response, not for the wire.
  public func serialize(pretty: Bool = false) throws -> Data {
    if pretty {
      return try JSONSerialization.data(
        withJSONObject: foundationObject, options: [.prettyPrinted])
    }
    // `[UInt8]`, not `Data`: appending a byte at a time to `Data` goes through its storage
    // indirection on every call and measured far slower than an array's amortised append.
    // The single copy into `Data` at the end is one memcpy.
    var out: [UInt8] = []
    out.reserveCapacity(4096)
    try write(into: &out)
    return Data(out)
  }

  private static let nullBytes = Array("null".utf8)
  private static let trueBytes = Array("true".utf8)
  private static let falseBytes = Array("false".utf8)
  private static let hexDigits = Array("0123456789abcdef".utf8)

  private func write(into out: inout [UInt8]) throws {
    switch self {
    case .null: out.append(contentsOf: Self.nullBytes)
    case .bool(let value): out.append(contentsOf: value ? Self.trueBytes : Self.falseBytes)
    case .int(let value): out.append(contentsOf: String(value).utf8)
    case .int64(let value): out.append(contentsOf: String(value).utf8)
    case .double(let value): try Self.write(double: value, into: &out)
    case .string(let value): Self.write(string: value, into: &out)
    case .array(let values):
      out.append(UInt8(ascii: "["))
      for (offset, value) in values.enumerated() {
        if offset > 0 { out.append(UInt8(ascii: ",")) }
        try value.write(into: &out)
      }
      out.append(UInt8(ascii: "]"))
    case .object(let values):
      out.append(UInt8(ascii: "{"))
      var isFirst = true
      for (key, value) in values {
        if !isFirst { out.append(UInt8(ascii: ",")) }
        isFirst = false
        Self.write(string: key, into: &out)
        out.append(UInt8(ascii: ":"))
        try value.write(into: &out)
      }
      out.append(UInt8(ascii: "}"))
    }
  }

  private static func write(double value: Double, into out: inout [UInt8]) throws {
    guard value.isFinite else { throw EncodingError.notFinite(value) }
    // A double with no fractional part is written as an integer, which is what both the
    // reference server and `JSONSerialization` do: `1.0` is `1`, and `-0.0` is `0`. Bounded
    // by what `Int64` can hold; beyond that `description` gives exponential notation, which
    // is valid JSON and is what the old path produced there too.
    if value == value.rounded(), value.magnitude < 9e18 {
      out.append(contentsOf: String(Int64(value)).utf8)
      return
    }
    out.append(contentsOf: value.description.utf8)
  }

  private static func write(string value: String, into out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    // Almost every string on this wire -- a GUID, an address, a service name, ordinary
    // message text -- contains nothing to escape, so it is worth one scan to find out and
    // then append the whole thing in a single copy. Only a string that does need escaping
    // pays the byte-at-a-time path.
    if !value.utf8.contains(where: Self.needsEscaping) {
      out.append(contentsOf: value.utf8)
      out.append(UInt8(ascii: "\""))
      return
    }
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
      case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
      case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
      case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
      case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
      case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
      case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
      // Everything else below 0x20 has no shorthand and must be escaped; nothing at or
      // above it does. `/` is NOT escaped, matching both the reference and Foundation, and
      // non-ASCII is emitted as its own UTF-8 rather than as \u escapes.
      case 0x00...0x1F:
        out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0")])
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
      default: out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }

  @inline(__always)
  private static func needsEscaping(_ byte: UInt8) -> Bool {
    byte < 0x20 || byte == UInt8(ascii: "\"") || byte == 0x5C
  }

  /// Parses JSON into the same representation.
  ///
  /// `.fragmentsAllowed` because a Socket.IO event payload is frequently a bare string or
  /// `null` rather than an object: `2["hello-world",null]` is a real frame.
  public static func parse(_ data: Data) throws -> JSONValue {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return from(object)
  }

  /// An `NSNumber` as the JSON scalar it is: the one reading of one, for every decoder that
  /// meets one (a parsed body, a property list, an archived attributed string).
  ///
  /// NSNumber erases Bool into a number, and `true` becoming `1` on the wire is a real client
  /// break; the CoreFoundation type is the only reliable way back. A float stays a float, and
  /// every other number is read as 64 bits, which three hand-written copies had not agreed on.
  public init(number: NSNumber) {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      self = .bool(number.boolValue)
      return
    }
    let encoding = String(cString: number.objCType)
    self =
      encoding == "d" || encoding == "f"
      ? .double(number.doubleValue) : .int64(number.int64Value)
  }

  static func from(_ object: Any) -> JSONValue {
    switch object {
    case is NSNull:
      return .null
    case let number as NSNumber:
      return JSONValue(number: number)
    case let value as String:
      return .string(value)
    case let values as [Any]:
      return .array(values.map(from))
    case let values as [String: Any]:
      return .object(values.mapValues(from))
    default:
      return .null
    }
  }
}

// MARK: - Reading

extension JSONValue {

  /// Subscript into an object. Returns nil for a non-object, so a chain like
  /// `payload["handle"]?["address"]` reads naturally without a cast at every step.
  public subscript(key: String) -> JSONValue? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }

  public subscript(index: Int) -> JSONValue? {
    guard case .array(let values) = self, values.indices.contains(index) else { return nil }
    return values[index]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  /// Integers arrive as either case depending on where the value came from (`.int` from a
  /// literal, `.int64` from a parse) so both are accepted.
  public var intValue: Int? {
    switch self {
    case .int(let value): value
    case .int64(let value): Int(value)
    default: nil
    }
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let values) = self else { return nil }
    return values
  }

  public var objectKeys: Set<String> {
    guard case .object(let values) = self else { return [] }
    return Set(values.keys)
  }

  public var isNull: Bool { self == .null }

  /// Adds keys to an object value. Returns the receiver unchanged for a non-object, since
  /// there is nothing sensible to merge into an array or a scalar.
  public func merging(_ other: [String: JSONValue]) -> JSONValue {
    guard case .object(let values) = self else { return self }
    return .object(values.merging(other) { _, new in new })
  }
}

// MARK: - Codable

/// The codec for documents this server keeps: the audit log stores, exports and forwards a
/// record's metadata through `AuditJSON`, which is `JSONEncoder` with sorted keys. NOT the
/// client wire, which is `serialize()` and nothing else.
///
/// Decoding tries `Bool`, then `Int`, then `Double`, so a whole number reads back as `.int`
/// and only a number with a fraction, or one past `Int`'s range, as `.double`. Every audit
/// row already stored was written to be read in that order, and it is what keeps a record's
/// `.int(42)` equal to itself after a round trip; `parse` gives `.int64` instead, which
/// renders the same digits and compares unequal. `.int64` encodes as the same digits as
/// `.int`, and `JSONEncoder` writes a whole `.double` without a fraction, so the encoded bytes
/// do not depend on which numeric case built the value. `AuditEncodingStabilityTests` pins
/// those bytes against a row written before this type was shared.
extension JSONValue: Codable {

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .int64(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let values): try container.encode(values)
    }
  }
}

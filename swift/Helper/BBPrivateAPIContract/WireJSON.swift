//  WireJSON
//  The value type of the helper protocol, shared by both ends of the socket.
//
//  It existed twice: `WireJSON` in the server's transport and `HelperProtocol.WireValue`
//  inside the injected helper — same six cases, same coercions, same decoder, written
//  separately because the two live in different targets. Two spellings of one wire format is
//  a drift waiting to happen: the day one side starts treating a number as a boolean and the
//  other does not, the difference shows up as a helper "rejecting" a request nobody can see
//  anything wrong with.
//
//  Here, in the contract both sides already depend on, there is one of it.
//
//  NOT the same type as `BBSerialization.JSONValue`, and deliberately not merged with it.
//  That one carries `int` and `int64` separately because the numbers it renders are the
//  CLIENT-facing JSON, where `1` and `1.0` are different bytes and the parity harness holds
//  us to the ones shipped clients already parse. This type talks to our own helper, where a
//  double is all the wire has ever carried.

import Foundation

public enum WireJSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([WireJSON])
  case object([String: WireJSON])

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    switch self {
    case .bool(let value): value
    // The helper is Objective-C and answers with 0/1 as often as with true/false.
    case .number(let value): value != 0
    default: nil
    }
  }

  public var intValue: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }

  /// Needed because FindMy's payload is the first on this wire that is genuinely
  /// fractional. Reading a latitude through `intValue` truncates it to a whole degree,
  /// which is an error of up to seventy miles and looks like a plausible position.
  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var arrayValue: [WireJSON]? {
    if case .array(let values) = self { return values }
    return nil
  }

  public subscript(key: String) -> WireJSON? {
    guard case .object(let values) = self else { return nil }
    return values[key]
  }

  /// Whether this is absent-or-empty in the sense the current server means by `isEmpty`,
  /// which is what decides `error` vs success and `data` vs the stripped remainder.
  public var isEmptyValue: Bool {
    switch self {
    case .null: true
    case .string(let value): value.isEmpty
    case .array(let values): values.isEmpty
    case .object(let values): values.isEmpty
    default: false
    }
  }
}

// MARK: - Coding

extension WireJSON: Codable {

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([WireJSON].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: WireJSON].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "unrepresentable JSON value"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      // Whole numbers are written as integers. The helper compares some of these as
      // strings, and `0` arriving as `0.0` has bitten this protocol before.
      if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let values): try container.encode(values)
    case .object(let values): try container.encode(values)
    }
  }
}

// MARK: - Convenience construction

extension WireJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(nilLiteral: ()) { self = .null }
}

extension WireJSON {
  /// Builds an object, dropping nil values rather than writing nulls.
  ///
  /// The helper branches on key PRESENCE for several optional fields, so a null is not the
  /// same as an omission — the same distinction the client wire format makes.
  public static func object(dropping pairs: [String: WireJSON?]) -> WireJSON {
    .object(pairs.compactMapValues { $0 })
  }
}

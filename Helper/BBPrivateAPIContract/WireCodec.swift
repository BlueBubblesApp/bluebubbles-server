//  WireCodec
//  One encoder and one decoder per contract type that crosses the helper socket.
//
//  Two hand-written halves of one format drift, in the helper's encoder and in
//  `PrivateAPIClient`'s decoder: a key the other side reads under a different meaning, a
//  number sent as a string, a fallback for a shape no helper sends. A type that conforms
//  here is encoded by its `wire` and decoded by its `init(wire:)`, both in this module,
//  which both sides link, so a field has one spelling, one type and one rule for absence.
//  `WireCodecRoundTripTests` puts every codec through the bytes the socket carries.
//
//  THE RULE FOR ABSENCE. A field the contract requires and the reply lacks is not a default
//  waiting to be filled in: it is a helper from a different build, and `WireReader` throws
//  `PrivateAPIError.protocolMismatch` naming the reply and the field. A default is kept only
//  where absence is an answer of its own (an indefinite mute omits `mutedUntil`, a release
//  that cannot read a filter category omits it), and each such field says so where it is
//  decoded. A present field of the wrong type is the same mismatch and throws the same way.
//
//  Times are epoch MILLISECONDS on this wire, whole numbers, in both directions:
//  `Date.wireMilliseconds` and `Date(wireMilliseconds:)` are the only conversion.
//
//  Foundation only, like everything in this module: it is compiled into Messages.app, so
//  nothing here may trap on malformed input.

import Foundation

/// A contract type with one encoding on the helper wire.
public protocol WireCodable {
  /// The payload as the helper writes it: keyed by `WireKey`, absent fields dropped.
  var wire: WireObject { get }

  /// Decodes a payload the helper wrote, throwing `PrivateAPIError.protocolMismatch` for a
  /// required field that is missing or of the wrong type.
  init(wire: WireReader) throws
}

extension WireCodable {
  /// Decodes the reply to a Messages helper action.
  public init(reply: WireJSON?, to action: MessagesHelperAction) throws {
    try self.init(wire: WireReader(reply: reply, to: action))
  }

  /// Decodes the reply to a FaceTime helper action.
  public init(reply: WireJSON?, to action: FaceTimeHelperAction) throws {
    try self.init(wire: WireReader(reply: reply, to: action))
  }
}

// MARK: - Reading

/// Typed, keyed reads of one payload object, each naming what it wanted when it is not there.
///
/// A nil payload reads as an object with no fields rather than as an error of its own: a
/// helper action that answers nothing is then refused by the first field it was required to
/// carry, with that field's name in the message, and a type whose every field is optional
/// decodes to its "cannot say" value.
public struct WireReader: Sendable {
  /// What is being read, for the error: "the get-chat-mute reply".
  public let context: String
  /// Where in it: empty at the top, `friends[2].` inside a list.
  private let location: String
  private let fields: [String: WireJSON]

  public init(_ value: WireJSON?, context: String) throws {
    try self.init(value, context: context, location: "")
  }

  /// The reply to a Messages helper action, named after it in any error.
  public init(reply: WireJSON?, to action: MessagesHelperAction) throws {
    try self.init(reply, context: "the \(action.rawValue) reply")
  }

  /// The reply to a FaceTime helper action, named after it in any error.
  public init(reply: WireJSON?, to action: FaceTimeHelperAction) throws {
    try self.init(reply, context: "the \(action.rawValue) reply")
  }

  /// An event's fields, named after the event in any error.
  public init(event: HelperEventName, fields: [String: WireJSON]) throws {
    try self.init(.object(fields), context: "the \(event.rawValue) event")
  }

  private init(_ value: WireJSON?, context: String, location: String) throws {
    self.context = context
    self.location = location
    switch value {
    case nil, .null?:
      fields = [:]
    case .object(let object)?:
      fields = object
    default:
      throw PrivateAPIError.protocolMismatch(
        "\(context) carries \(location.isEmpty ? "a payload" : "'\(location.dropLast())'") "
          + "that is not an object")
    }
  }

  /// Whether the field is present with a value. A null counts as absent: the helper never
  /// writes one (`WireObject` drops nils), so a null carries no meaning of its own.
  public func contains(_ key: WireKey) -> Bool {
    guard let value = fields[key.rawValue] else { return false }
    return value != .null
  }

  // MARK: Required

  public func string(_ key: WireKey) throws -> String {
    try required(key, "a string", \.stringValue)
  }

  public func bool(_ key: WireKey) throws -> Bool {
    try required(key, "a boolean", \.boolValue)
  }

  public func int(_ key: WireKey) throws -> Int {
    try required(key, "a whole number", \.intValue)
  }

  public func double(_ key: WireKey) throws -> Double {
    try required(key, "a number", \.doubleValue)
  }

  public func date(_ key: WireKey) throws -> Date {
    Date(wireMilliseconds: try double(key))
  }

  public func strings(_ key: WireKey) throws -> [String] {
    try required(key, "a list of strings", Self.strings)
  }

  /// A string naming a case of `T`; a value `T` does not have is a mismatch, not a default.
  public func value<T: RawRepresentable>(_ key: WireKey, as type: T.Type) throws -> T
  where T.RawValue == String {
    try required(key, "one of \(T.self)'s values") { $0.stringValue.flatMap(T.init(rawValue:)) }
  }

  public func decode<T: WireCodable>(_ key: WireKey, as type: T.Type = T.self) throws -> T {
    guard contains(key) else { throw missing(key) }
    return try T(wire: nested(key))
  }

  public func decodeList<T: WireCodable>(_ key: WireKey, as type: T.Type = T.self) throws -> [T] {
    guard let list = fields[key.rawValue]?.arrayValue else {
      throw contains(key) ? wrongType(key, "a list") : missing(key)
    }
    return try list.enumerated().map { index, element in
      try T(
        wire: WireReader(
          element, context: context, location: "\(location)\(key.rawValue)[\(index)]."))
    }
  }

  // MARK: Optional

  public func optionalString(_ key: WireKey) throws -> String? {
    try optional(key, "a string", \.stringValue)
  }

  public func optionalBool(_ key: WireKey) throws -> Bool? {
    try optional(key, "a boolean", \.boolValue)
  }

  public func optionalInt(_ key: WireKey) throws -> Int? {
    try optional(key, "a whole number", \.intValue)
  }

  public func optionalDouble(_ key: WireKey) throws -> Double? {
    try optional(key, "a number", \.doubleValue)
  }

  public func optionalDate(_ key: WireKey) throws -> Date? {
    try optionalDouble(key).map(Date.init(wireMilliseconds:))
  }

  public func optionalDecode<T: WireCodable>(_ key: WireKey, as type: T.Type = T.self) throws
    -> T?
  {
    guard contains(key) else { return nil }
    return try T(wire: nested(key))
  }

  /// Every field as a string, skipping those that are not one: for the free-form FaceTime
  /// debug dump, the one reply whose keys the contract does not model.
  public var stringFields: [String: String] {
    fields.compactMapValues(\.stringValue)
  }

  // MARK: Plumbing

  private func nested(_ key: WireKey) throws -> WireReader {
    try WireReader(
      fields[key.rawValue], context: context, location: "\(location)\(key.rawValue).")
  }

  private func optional<T>(_ key: WireKey, _ kind: String, _ convert: (WireJSON) -> T?) throws
    -> T?
  {
    guard contains(key), let raw = fields[key.rawValue] else { return nil }
    guard let value = convert(raw) else { throw wrongType(key, kind) }
    return value
  }

  private func required<T>(_ key: WireKey, _ kind: String, _ convert: (WireJSON) -> T?) throws
    -> T
  {
    guard let value = try optional(key, kind, convert) else { throw missing(key) }
    return value
  }

  private static func strings(_ value: WireJSON) -> [String]? {
    guard let list = value.arrayValue else { return nil }
    let strings = list.compactMap(\.stringValue)
    return strings.count == list.count ? strings : nil
  }

  private func missing(_ key: WireKey) -> PrivateAPIError {
    .protocolMismatch("\(context) has no '\(location)\(key.rawValue)'")
  }

  private func wrongType(_ key: WireKey, _ kind: String) -> PrivateAPIError {
    .protocolMismatch("\(context) carries '\(location)\(key.rawValue)' that is not \(kind)")
  }
}

// MARK: - Values with one wire form

extension Date {
  /// Epoch milliseconds, rounded to a whole number: the one form a time takes on this wire.
  ///
  /// Never traps, because the helper runs this inside Messages: a date no `Int` can hold
  /// (only a deliberately absurd one) is clamped rather than converted, and NaN reads as the
  /// epoch. A fractional value is never written: `timeIntervalSince1970 * 1000` of a date
  /// that began as whole milliseconds comes back a hair off, and the wire then carried
  /// `1700000000000.0002` where the sender meant `1700000000000`.
  public var wireMilliseconds: Int {
    let milliseconds = (timeIntervalSince1970 * 1000).rounded()
    if let exact = Int(exactly: milliseconds) { return exact }
    if milliseconds.isNaN { return 0 }
    return milliseconds > 0 ? .max : .min
  }

  /// The inverse of `wireMilliseconds`.
  public init(wireMilliseconds milliseconds: Double) {
    self.init(timeIntervalSince1970: milliseconds / 1000)
  }
}

extension Double {
  /// This value, or nil when JSON has no form for it.
  ///
  /// `JSONSerialization` raises an Objective-C exception for NaN or infinity, which nothing
  /// in Swift can catch, inside Messages. An encoder writes a measured `Double` through this,
  /// so a nonsense reading drops one field rather than failing the whole reply.
  public var wireFinite: Double? { isFinite ? self : nil }
}

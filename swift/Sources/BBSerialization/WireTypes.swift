//  WireTypes
//  The JSON shapes clients receive. This file IS the compatibility contract.
//
//  Rules that hold throughout, each of which a client depends on:
//    - Dates are epoch MILLISECONDS, or null. Never ISO strings.
//    - A field absent from this macOS version is ABSENT from the JSON, not null. Clients
//      distinguish the two.
//    - `isForNotification` strips ~18 fields; that trimmed variant is what FCM and webhooks
//      receive, while the socket gets the full one.
//    - Key names are frozen. `address` comes from `handle.id`, `isExpired` from
//      `message.isExpirable` — both renames the wire format requires.
//
//  Encoded through an explicit `encode(to:)` rather than synthesised Codable, because
//  conditional key PRESENCE is the whole point and `encodeIfPresent` on an optional cannot
//  express "absent because this OS lacks the column" versus "present and null".
//
//  See `.claude/docs/decisions.md`.

import Foundation

// MARK: - Response envelope

public enum ResponseMessage: String, Sendable {
  case success = "Success"
  case badRequest = "Bad Request"
  case serverError = "Server Error"
  case unauthorized = "Unauthorized"
  case forbidden = "Forbidden"
  case noData = "No Data"
  case notFound = "Not Found"
  case unknownIMessageError = "Unknown iMessage Error"
  case gatewayTimeout = "Gateway Timeout"
}

public enum ErrorType: String, Sendable {
  case serverError = "Server Error"
  /// Spelled DATABSE_ERROR in the original enum. The wire value is what matters.
  case databaseError = "Database Error"
  case iMessageError = "iMessage Error"
  case socketError = "Socket Error"
  case validationError = "Validation Error"
  case authenticationError = "Authentication Error"
  case gatewayTimeout = "Gateway Timeout"
}

/// The envelope every JSON response uses.
///
/// `data` and `metadata` are OMITTED when absent — never emitted as null. The parity harness
/// asserts this, since null-vs-absent is a real difference to a strict parser.
public struct ResponseEnvelope: Sendable {
  public let status: Int
  public let message: String
  public let error: ErrorBody?
  public let data: JSONValue?
  public let metadata: JSONValue?
  /// Always present on socket responses, even though the AES path is retired: clients
  /// read the field, so removing it would break them.
  public let encrypted: Bool?

  public init(
    status: Int,
    message: String,
    error: ErrorBody? = nil,
    data: JSONValue? = nil,
    metadata: JSONValue? = nil,
    encrypted: Bool? = nil
  ) {
    self.status = status
    self.message = message
    self.error = error
    self.data = data
    self.metadata = metadata
    self.encrypted = encrypted
  }

  /// HTTP 200.
  ///
  /// `message` defaults to "Success" and is overridden per route. It is NOT decorative: the
  /// reference gives about forty routes their own string — `"Ping received!"`,
  /// `"Successfully fetched messages!"` — and every one of them was answering "Success"
  /// here. Found by diffing a live Electron server; see `SuccessMessages`.
  public static func success(
    _ data: JSONValue? = nil,
    metadata: JSONValue? = nil,
    message: String? = nil
  ) -> Self {
    ResponseEnvelope(
      status: 200, message: message ?? ResponseMessage.success.rawValue,
      data: data, metadata: metadata)
  }

  /// HTTP 201 with "No Data". Used by POST /facetime/leave/:call_uuid.
  public static func noData() -> Self {
    ResponseEnvelope(status: 201, message: ResponseMessage.noData.rawValue)
  }

  public func encoded(pretty: Bool = false) throws -> Data {
    var object: [String: JSONValue] = [
      "status": .int(status),
      "message": .string(message),
    ]
    if let encrypted { object["encrypted"] = .bool(encrypted) }
    if let error {
      object["error"] = .object([
        "type": .string(error.type.rawValue),
        "message": .string(error.message),
      ])
    }
    if let data { object["data"] = data }
    if let metadata { object["metadata"] = metadata }

    return try JSONValue.object(object).serialize(pretty: pretty)
  }
}

public struct ErrorBody: Sendable {
  public let type: ErrorType
  public let message: String
  public init(type: ErrorType, message: String) {
    self.type = type
    self.message = message
  }
}

// MARK: - JSON

/// A JSON value with explicit presence.
///
/// Needed because "omit this key" and "emit null" are different outcomes, and Swift's
/// Optional plus synthesised Codable conflates them.
public indirect enum JSONValue: Sendable, Equatable {
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

  public func serialize(pretty: Bool = false) throws -> Data {
    var options: JSONSerialization.WritingOptions = []
    if pretty { options.insert(.prettyPrinted) }
    // Deliberately NOT .sortedKeys, but note what that does and does not buy: `object`
    // is a [String: JSONValue], so key order here is arbitrary and varies between
    // processes. Insertion order is NOT preserved and cannot be. Every comparison
    // against recorded fixtures is therefore structural, never byte-for-byte — see
    // expectFrameEquivalent in SocketCodecTests. Sorting would be equally correct on the
    // wire and merely costs a sort per encode.
    return try JSONSerialization.data(withJSONObject: foundationObject, options: options)
  }

  /// Parses JSON into the same representation.
  ///
  /// `.fragmentsAllowed` because a Socket.IO event payload is frequently a bare string or
  /// `null` rather than an object — `2["hello-world",null]` is a real frame.
  public static func parse(_ data: Data) throws -> JSONValue {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return from(object)
  }

  static func from(_ object: Any) -> JSONValue {
    switch object {
    case is NSNull:
      return .null
    case let number as NSNumber:
      // NSNumber erases Bool into a number, and `true` becoming `1` on the wire is a
      // real client break. The ObjC type encoding is the only reliable way back.
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      if String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" {
        return .double(number.doubleValue)
      }
      return .int64(number.int64Value)
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

  /// Integers arrive as either case depending on where the value came from — `.int` from a
  /// literal, `.int64` from a parse — so both are accepted.
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
}

/// Builds an object while keeping absent keys absent.
public struct JSONObjectBuilder {
  private var storage: [String: JSONValue] = [:]

  public init() {}

  /// Sets a key. Passing nil OMITS it.
  public mutating func set(_ key: String, _ value: JSONValue?) {
    guard let value else { return }
    storage[key] = value
  }

  /// Sets a key to a value or to explicit null — for fields that exist on this schema but
  /// have no value, such as an unread message's `dateRead`.
  public mutating func setOrNull(_ key: String, _ value: JSONValue?) {
    storage[key] = value ?? .null
  }

  /// Sets only when `condition` holds. This is how macOS-gated fields stay absent rather
  /// than becoming null on an older release.
  public mutating func setIf(
    _ condition: Bool, _ key: String, _ value: @autoclosure () -> JSONValue?
  ) {
    guard condition else { return }
    if let resolved = value() { storage[key] = resolved }
  }

  public mutating func setIfOrNull(
    _ condition: Bool, _ key: String, _ value: @autoclosure () -> JSONValue?
  ) {
    guard condition else { return }
    storage[key] = value() ?? .null
  }

  public func build() -> JSONValue { .object(storage) }
  public var keys: Set<String> { Set(storage.keys) }
}

// MARK: - Serializer configuration

public struct MessageSerializerConfig: Sendable {
  public var parseAttributedBody: Bool
  /// How much of the decoded attributed body to emit. Defaults to the legacy shape, which
  /// is the only one existing clients know how to read.
  public var attributedBodyFormat: AttributedBodyWireFormat = .legacy
  public var parseMessageSummary: Bool
  public var parsePayloadData: Bool
  public var loadChatParticipants: Bool
  public var includeChats: Bool
  /// FCM caps a data payload at 4KB, so the notification variant sheds chat participants
  /// when it would overflow.
  public var enforceMaxSize: Bool
  public var maxSizeBytes: Int

  public init(
    parseAttributedBody: Bool = false,
    parseMessageSummary: Bool = false,
    parsePayloadData: Bool = false,
    loadChatParticipants: Bool = true,
    includeChats: Bool = true,
    enforceMaxSize: Bool = false,
    maxSizeBytes: Int = 4000
  ) {
    self.parseAttributedBody = parseAttributedBody
    self.parseMessageSummary = parseMessageSummary
    self.parsePayloadData = parsePayloadData
    self.loadChatParticipants = loadChatParticipants
    self.includeChats = includeChats
    self.enforceMaxSize = enforceMaxSize
    self.maxSizeBytes = maxSizeBytes
  }

  /// What the socket receives: everything.
  public static let full = MessageSerializerConfig(
    parseAttributedBody: true, parseMessageSummary: true, parsePayloadData: true,
    loadChatParticipants: false, includeChats: true
  )

  /// What FCM and webhooks receive: trimmed, size-capped.
  public static let notification = MessageSerializerConfig(
    loadChatParticipants: false, includeChats: true, enforceMaxSize: true
  )
}

public struct AttachmentSerializerConfig: Sendable {
  public var convert: Bool
  public var loadData: Bool
  public var loadMetadata: Bool
  public var includeMessageGUIDs: Bool

  public init(
    convert: Bool = true,
    loadData: Bool = false,
    loadMetadata: Bool = true,
    includeMessageGUIDs: Bool = false
  ) {
    self.convert = convert
    self.loadData = loadData
    self.loadMetadata = loadMetadata
    self.includeMessageGUIDs = includeMessageGUIDs
  }

  public static let `default` = AttachmentSerializerConfig()
}

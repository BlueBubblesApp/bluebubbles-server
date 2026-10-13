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
//      `message.isExpirable`: both renames the wire format requires.
//
//  The value type these are built from, and the writer that turns it into bytes,
//  `JSONValue.serialize()`, live in BBCore so layers below this one can hold JSON too; see
//  that file's header. What is here is the envelope, the object builder and the serializer
//  configuration.
//
//  Encoded through an explicit `encode(to:)` rather than synthesised Codable, because
//  conditional key PRESENCE is the whole point and `encodeIfPresent` on an optional cannot
//  express "absent because this OS lacks the column" versus "present and null".
//
//  See `.claude/docs/decisions.md`.

import BBCore
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

public enum ErrorType: String, Sendable, CaseIterable {
  case serverError = "Server Error"
  /// Spelled DATABSE_ERROR in the original enum. The wire value is what matters.
  case databaseError = "Database Error"
  case iMessageError = "iMessage Error"
  case socketError = "Socket Error"
  case validationError = "Validation Error"
  case authenticationError = "Authentication Error"
  case gatewayTimeout = "Gateway Timeout"
  /// Only ever emitted by a route that declares a subscription tier, which is never a v1
  /// route. Additive to the reference's enum, and safe for that reason: a client that has
  /// never called a gated route can never receive it.
  case paymentRequired = "Payment Required"
}

/// The envelope every JSON response uses.
///
/// `data` and `metadata` are OMITTED when absent: never emitted as null. The parity harness
/// asserts this, since null-vs-absent is a real difference to a strict parser.
public struct ResponseEnvelope: Sendable {
  public let status: Int
  public let message: String
  public let error: ErrorBody?
  public let data: JSONValue?
  public let metadata: JSONValue?
  /// Emitted only when set, and **nothing in this server sets it**.
  ///
  /// This said "always present on socket responses". It is not: the field defaults to nil and
  /// is omitted from the encoding when nil, and the only call site passing a value anywhere is
  /// a serialization test.
  ///
  /// It is not a missing field either, which is the part worth being precise about. The
  /// reference sets `encrypted = false` at `socketRoutes.ts:57` on every ACK response to an
  /// inbound socket command, and this server answers no inbound socket commands, so there is
  /// no ack envelope for it to sit on. Socket broadcasts carry the raw object in both servers,
  /// and HTTP responses carry no `encrypted` in either.
  ///
  /// The field stays so that whoever implements the inbound command surface has it to hand,
  /// and must set it: the reference does so unconditionally. See `docs/EVENTS.md`.
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
  /// reference gives about forty routes their own string (`"Ping received!"`,
  /// `"Successfully fetched messages!"`) and every one of them was answering "Success"
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

// MARK: - JSON building

/// Builds an object while keeping absent keys absent.
public struct JSONObjectBuilder {
  private var storage: [String: JSONValue] = [:]

  public init() {}

  /// Sets a key. Passing nil OMITS it.
  public mutating func set(_ key: String, _ value: JSONValue?) {
    guard let value else { return }
    storage[key] = value
  }

  /// Sets a key to a value or to explicit null: for fields that exist on this schema but
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

  public init(
    parseAttributedBody: Bool = false,
    parseMessageSummary: Bool = false,
    parsePayloadData: Bool = false,
    loadChatParticipants: Bool = true,
    includeChats: Bool = true
  ) {
    self.parseAttributedBody = parseAttributedBody
    self.parseMessageSummary = parseMessageSummary
    self.parsePayloadData = parsePayloadData
    self.loadChatParticipants = loadChatParticipants
    self.includeChats = includeChats
  }

  /// What the socket receives: everything.
  public static let full = MessageSerializerConfig(
    parseAttributedBody: true, parseMessageSummary: true, parsePayloadData: true,
    loadChatParticipants: false, includeChats: true
  )

  /// What every notification transport and every webhook receives: the smaller CONTENT
  /// shape, and nothing to do with size.
  ///
  /// FCM's 4 KB limit is a constraint of one transport, imposed by Google, and does not
  /// belong in a projection that webhooks, ntfy and anything else built later all consume:
  /// ntfy's limit is configurable by whoever runs the server, a UnifiedPush endpoint's
  /// belongs to a distributor this server cannot see, and a webhook has none at all. The
  /// cap lives in `FCMSender`, next to Google's own rejection. See `docs/EVENTS.md`.
  /// Participants ARE loaded here and are NOT on `.full`, which looks backwards and is the
  /// reference's own arrangement: its socket emit passes `loadChatParticipants: false`
  /// explicitly, while its notification emit passes only `enforceMaxSize` and inherits
  /// `true` from `DEFAULT_MESSAGE_CONFIG`. A push for a group chat carries the roster; the
  /// socket payload does not, because a socket client can ask.
  ///
  /// It also makes the FCM trim mean something: participants are what `FCMSender` sheds when
  /// a payload is over 4 KB, and with them never loaded there would be nothing to shed.
  public static let notification = MessageSerializerConfig(
    loadChatParticipants: true, includeChats: true
  )

  /// The notification shape for an UPDATE, which is not the same as for a new message.
  ///
  /// The reference splits `updated-message` into two emits with two configs: the socket gets
  /// `loadChatParticipants: false, includeChats: true` (that is `.full`), and the FCM emit
  /// gets `loadChatParticipants: false, includeChats: false`, under the comment "Since this
  /// is a message update, we do not need to include the participants or chats"
  /// (`index.ts:1576`-`:1604`). We were sending `.notification` to both, so every edit,
  /// unsend, reaction and read receipt carried a chat object and its whole roster.
  ///
  /// **The socket must keep its chats**, and that is not a preference. The app reads
  /// `payload.data['chats'].first` with no null guard on the updated-message branch —
  /// `attachments` on the line below it uses `?? const []` and `chats` deliberately does not
  /// — so an updated-message without a chat throws inside the client's handler. This applies
  /// to the NOTIFICATION projection only.
  public static let notificationUpdate = MessageSerializerConfig(
    loadChatParticipants: false, includeChats: false
  )

  /// `message-send-error`: participants off, chats ON.
  ///
  /// Not the same as `.notificationUpdate`, though both are "an update". The reference
  /// serializes this one with `{ loadChatParticipants: false }` and nothing else
  /// (`index.ts:1236`), so `includeChats` falls through to `DEFAULT_MESSAGE_CONFIG`'s `true`
  /// — its comment says only "we don't need to include the participants". A client that has
  /// just failed to send still needs to know which conversation failed.
  public static let notificationSendError = MessageSerializerConfig(
    loadChatParticipants: false, includeChats: true
  )
}

public struct AttachmentSerializerConfig: Sendable {
  /// `convertAttachments` on the message routes. **Read by nothing here, deliberately.**
  ///
  /// In the reference this converts HEIC and CAF as a SIDE EFFECT of serializing, warming
  /// `FileSystem.convertDir` so a later download is quick. It changes no field on the wire:
  /// `mimeType` and `transferName` are read off the attachment row either way, which is
  /// measurable in its own serializer. This server converts on demand in
  /// `GET /attachment/:guid/download` instead, so the bytes a client receives are the same
  /// and only the first download pays.
  ///
  /// Kept as a declared field rather than deleted so the flag a client sends has somewhere
  /// to land and this note has somewhere to live; an audit of "parameters accepted and not
  /// applied" should find the answer here rather than concluding it was missed.
  public var convert: Bool
  /// `height`, `width` and `metadata`. On by default, as the reference's is.
  public var loadMetadata: Bool

  // The reference's other two flags, `loadData` and `includeMessageGuids`, have no field
  // here because no response this server sends can carry them. `includeMessageGuids` is
  // set true nowhere in the reference; `loadData` only by the socket `get-attachment`
  // command (`socketRoutes.ts:398`), and this server answers no inbound socket commands.
  // Both defaulted false in `DEFAULT_ATTACHMENT_CONFIG`, so neither `messages` nor `data` is
  // on any attachment an HTTP route or an event carries, there or here.

  public init(convert: Bool = true, loadMetadata: Bool = true) {
    self.convert = convert
    self.loadMetadata = loadMetadata
  }

  public static let `default` = AttachmentSerializerConfig()
}

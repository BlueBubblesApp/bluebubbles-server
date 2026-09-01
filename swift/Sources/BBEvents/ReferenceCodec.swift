//  ReferenceCodec
//  reference-v2: send identifiers, let the client fetch the content.
//
//  Why this beats "just encrypt the current payload"
//  ------------------------------------------------
//  Message content never transits Google's infrastructure at all, so there is **no key
//  management problem to get wrong**. An encrypted payload still has to be encrypted to
//  somebody, with a key that has to be distributed, rotated, and recovered when a device is
//  wiped. A payload with no content in it has none of those problems.
//
//  It also removes the 4KB FCM ceiling, which today forces the serializer to strip chat
//  participants out of notifications to fit — so the notification a client receives is
//  already lossy, just silently.
//
//  The honest downsides
//  --------------------
//  A client cannot render a notification body without a round trip. If the Mac is asleep or
//  the tunnel is down when the push arrives, the notification shows nothing useful. Latency
//  grows by one request, and Android's background-execution limits make that request
//  genuinely awkward.
//
//  Two things soften it, and neither pretends the cost is zero:
//
//    - **Hints.** A configurable, non-sensitive subset can travel in the clear, so the user
//      picks their own point on the privacy/usability curve rather than having one imposed.
//    - **Batch hydration.** `POST /api/v1/message/hydrate {guids: [...]}` turns a burst of
//      notifications into one request.
//
//  See `docs/EVENTS.md`.

import BBCore
import BBSerialization
import Foundation

/// How much non-sensitive context travels in the clear alongside the identifiers.
///
/// This is a privacy decision, so it is the user's rather than ours. The default is `.none`,
/// because a codec chosen to keep content off Google's infrastructure should not put content
/// back on it without being asked.
public enum NotificationHint: String, Sendable, CaseIterable, Codable {
  /// Identifiers only.
  case none
  /// Adds who it is from. Enough for "Message from Alice" without the message.
  case senderOnly = "sender-only"
  /// Adds a truncated preview. Convenient, and the content does leave the machine.
  case senderAndPreview = "sender-and-preview"
}

public struct ReferencePayloadCodec: EventPayloadCodec {

  public let identifier = CodecIdentifier.referenceV2

  /// How much a preview may reveal. Short on purpose: a preview is a hint, and a long one
  /// is just the message with extra steps.
  public static let maximumPreviewLength = 64

  private let hint: NotificationHint

  public init(hint: NotificationHint = .none) {
    self.hint = hint
  }

  public func encode(
    _ event: ServerEvent,
    projection: PayloadProjection,
    capabilities: TargetCapabilities
  ) async throws -> EncodedPayload {
    EncodedPayload(codec: identifier, body: Self.envelope(for: event, hint: hint))
  }

  /// `{"v":2,"t":"new-message","g":"…","c":"…","ts":…}` plus any hints.
  ///
  /// Keys are single letters because this rides in a 4KB FCM data payload and the whole
  /// point is to be small.
  static func envelope(for event: ServerEvent, hint: NotificationHint) -> JSONValue {
    let payload = event.payload(for: .notification)
    var fields: [String: JSONValue] = [
      "v": .int(2),
      "t": .string(event.name.rawValue),
      "ts": .int64(Int64(event.occurredAt.timeIntervalSince1970 * 1000)),
    ]

    // Absent rather than null when the event carries no message — an event like
    // `server-update` has no guid, and emitting `"g": null` would make every client
    // handle a case that never means anything.
    if let guid = payload["guid"]?.stringValue {
      fields["g"] = .string(guid)
    }
    if let chatGUID = Self.chatGUID(in: payload) {
      fields["c"] = .string(chatGUID)
    }

    switch hint {
    case .none:
      break
    case .senderOnly:
      if let sender = Self.sender(in: payload) { fields["s"] = .string(sender) }
    case .senderAndPreview:
      if let sender = Self.sender(in: payload) { fields["s"] = .string(sender) }
      if let preview = Self.preview(in: payload) { fields["p"] = .string(preview) }
    }

    return .object(fields)
  }

  /// The chat a message belongs to.
  ///
  /// A message can belong to several chats, and the payload carries them as an array. The
  /// first is what clients already use to route a notification, so it is what travels.
  static func chatGUID(in payload: JSONValue) -> String? {
    if let direct = payload["chatGuid"]?.stringValue { return direct }
    guard case .array(let chats)? = payload["chats"] else { return nil }
    return chats.first?["guid"]?.stringValue
  }

  /// Who sent it: the handle address, which is what the client already resolves to a name.
  ///
  /// Deliberately the address rather than a resolved contact name — resolving here would
  /// put a name from the user's address book into a push payload, which is a bigger
  /// disclosure than the address the message came from.
  static func sender(in payload: JSONValue) -> String? {
    if payload["isFromMe"]?.boolValue == true { return nil }
    return payload["handle"]?["address"]?.stringValue
  }

  /// A truncated preview, or nil when there is nothing to preview.
  static func preview(in payload: JSONValue) -> String? {
    guard let text = payload["text"]?.stringValue else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > maximumPreviewLength else { return trimmed }
    // Truncated on a character boundary, so a multi-byte grapheme is never split.
    return String(trimmed.prefix(maximumPreviewLength)) + "…"
  }
}

// MARK: - Hydration

/// `POST /api/v1/message/hydrate`.
///
/// Batched because notifications arrive in bursts — a group chat waking up produces a dozen
/// at once, and a dozen round trips on a phone radio is a meaningfully worse experience than
/// one.
public struct HydrationRequest: Codable, Sendable, Equatable {
  public let guids: [String]
  /// Whether to include attachment metadata. Off by default to keep the response small.
  public let withAttachments: Bool

  public init(guids: [String], withAttachments: Bool = false) {
    self.guids = guids
    self.withAttachments = withAttachments
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guids = try container.decode([String].self, forKey: .guids)
    withAttachments = try container.decodeIfPresent(Bool.self, forKey: .withAttachments) ?? false
  }

  enum CodingKeys: String, CodingKey {
    case guids
    case withAttachments
  }

  /// Ceiling on one request. A client that asks for ten thousand guids is either broken or
  /// probing; either way the answer is the same.
  public static let maximumGUIDs = 100

  public enum ValidationError: BBError, Equatable {
    case empty
    case tooMany(count: Int, limit: Int)
  }

  public func validate() throws {
    guard !guids.isEmpty else { throw ValidationError.empty }
    guard guids.count <= Self.maximumGUIDs else {
      throw ValidationError.tooMany(count: guids.count, limit: Self.maximumGUIDs)
    }
  }

  /// Deduplicated, preserving order.
  ///
  /// A burst of notifications for the same message — which happens, since a message in
  /// several chats produces several events — should not cost several lookups.
  public var uniqueGUIDs: [String] {
    var seen = Set<String>()
    return guids.filter { seen.insert($0).inserted }
  }
}

extension HydrationRequest.ValidationError {
  public var code: String {
    switch self {
    case .empty: "hydration.empty"
    case .tooMany: "hydration.too_many"
    }
  }

  public var domain: String { "Events" }

  public var title: String { "That hydration request was rejected" }

  public var body: String {
    switch self {
    case .empty: "The request asked for nothing."
    case .tooMany(let count, let limit):
      "The request asked for \(count) items; the limit is \(limit)."
    }
  }
}

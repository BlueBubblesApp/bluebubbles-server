//  Rows
//  Value types over chat.db rows.
//
//  Deliberately dumb: they map columns and nothing else. Business rules live above them, so
//  a schema change touches one layer.
//
//  Every optional here means the column is ABSENT from this schema, not that the value is
//  null — which is the distinction the serializer carries onto the wire, since clients treat
//  a missing key differently from a null one.

import BBCore
import Foundation
import GRDB

/// What the change detector compares: a message's identity and the fields that can move
/// after it is written. See `MessageRepository.messageFingerprints`.
public struct MessageFingerprintRow: Sendable, Hashable {
  public let rowID: Int64
  public let guid: String
  /// Converted exactly as `IMessageRow` converts them — a zero column is "not set" and
  /// reads as nil — so a fingerprint taken from either row shape compares equal.
  public let date: AppleTimestamp?
  public let dateRead: AppleTimestamp?
  public let dateDelivered: AppleTimestamp?
  public let datePlayed: AppleTimestamp?
  public let dateEdited: AppleTimestamp?
  public let dateRetracted: AppleTimestamp?
  public let didNotifyRecipient: Bool?
  public let error: Int

  init(row: Row, dateUnit: AppleTimestamp.Unit) {
    rowID = row["ROWID"]
    guid = row["guid"]
    date = AppleTimestamp.column(row.optional("date"), unit: dateUnit)
    dateRead = AppleTimestamp.column(row.optional("date_read"), unit: dateUnit)
    dateDelivered = AppleTimestamp.column(row.optional("date_delivered"), unit: dateUnit)
    datePlayed = AppleTimestamp.column(row.optional("date_played"), unit: dateUnit)
    dateEdited = AppleTimestamp.column(row.optional("date_edited"), unit: dateUnit)
    dateRetracted = AppleTimestamp.column(row.optional("date_retracted"), unit: dateUnit)
    didNotifyRecipient = row.boolIfPresent("did_notify_recipient")
    error = row.optional("error") ?? 0
  }
}

/// Safe column access: a column absent from this schema reads as nil rather than trapping.
extension Row {
  fileprivate func optional<T: DatabaseValueConvertible>(_ column: String) -> T? {
    guard hasColumn(column) else { return nil }
    return self[column] as T?
  }

  fileprivate func bool(_ column: String) -> Bool {
    guard hasColumn(column) else { return false }
    return (self[column] as Int64?) == 1
  }

  fileprivate func boolIfPresent(_ column: String) -> Bool? {
    guard hasColumn(column) else { return nil }
    guard let value = self[column] as Int64? else { return nil }
    return value == 1
  }
}

public struct IMessageRow: Sendable {

  public let rowID: Int64
  public let guid: String
  /// Frequently NULL — the real content is in `attributedBody`.
  public let text: String?
  public let attributedBody: Data?
  public let subject: String?
  public let handleID: Int64?
  public let otherHandle: Int64?
  public let country: String?
  public let service: String?
  public let error: Int

  public let date: AppleTimestamp?
  public let dateRead: AppleTimestamp?
  public let dateDelivered: AppleTimestamp?
  public let datePlayed: AppleTimestamp?
  public let timeExpressiveSendPlayed: AppleTimestamp?

  public let isDelivered: Bool
  public let isFromMe: Bool
  public let isRead: Bool
  public let isSent: Bool
  public let isEmpty: Bool
  public let isDelayed: Bool
  public let isAutoReply: Bool
  public let isSystemMessage: Bool
  public let isServiceMessage: Bool
  public let isForward: Bool
  public let isArchived: Bool
  public let isAudioMessage: Bool
  public let isPlayed: Bool
  public let isCorrupt: Bool
  public let isSpam: Bool
  public let isExpirable: Bool
  public let hasDDResults: Bool
  public let wasDataDetected: Bool
  public let wasDeduplicated: Bool
  public let cacheHasAttachments: Bool
  public let cacheRoomnames: String?

  public let itemType: Int
  public let groupTitle: String?
  public let groupActionType: Int
  public let shareStatus: Int?
  public let shareDirection: Int?
  public let balloonBundleID: String?
  public let expressiveSendStyleID: String?
  /// Prefixed: `p:0/GUID`, `bp:GUID`, or bare. The prefix is meaningful.
  public let associatedMessageGUID: String?
  public let associatedMessageType: Int
  /// The emoji of an emoji tapback (types 2006 / 3006). Sonoma and later; nil elsewhere.
  public let associatedMessageEmoji: String?
  /// Send Later. 2 means the user scheduled it; 0 means an ordinary message.
  public let scheduleType: Int
  /// Where a scheduled message is in its life. 1 is scheduled and undelivered.
  public let scheduleState: Int
  public let payloadData: Data?
  public let messageSummaryInfo: Data?

  // High Sierra and later.
  public let threadOriginatorGUID: String?
  public let threadOriginatorPart: String?
  public let replyToGUID: String?

  // Ventura and later. nil means the column is absent, so the serializer omits the key.
  public let dateEdited: AppleTimestamp?
  public let dateRetracted: AppleTimestamp?
  public let partCount: Int?

  // Monterey and later.
  public let wasDeliveredQuietly: Bool?
  public let didNotifyRecipient: Bool?

  init(row: Row, dateUnit: AppleTimestamp.Unit) {
    rowID = row["ROWID"]
    guid = row["guid"]
    text = row.optional("text")
    attributedBody = row.optional("attributedBody")
    subject = row.optional("subject")
    handleID = row.optional("handle_id")
    otherHandle = row.optional("other_handle")
    country = row.optional("country")
    service = row.optional("service")
    error = row.optional("error") ?? 0

    date = AppleTimestamp.column(row.optional("date"), unit: dateUnit)
    dateRead = AppleTimestamp.column(row.optional("date_read"), unit: dateUnit)
    dateDelivered = AppleTimestamp.column(row.optional("date_delivered"), unit: dateUnit)
    datePlayed = AppleTimestamp.column(row.optional("date_played"), unit: dateUnit)
    timeExpressiveSendPlayed = AppleTimestamp.column(
      row.optional("time_expressive_send_played"), unit: dateUnit
    )

    isDelivered = row.bool("is_delivered")
    isFromMe = row.bool("is_from_me")
    isRead = row.bool("is_read")
    isSent = row.bool("is_sent")
    isEmpty = row.bool("is_empty")
    isDelayed = row.bool("is_delayed")
    isAutoReply = row.bool("is_auto_reply")
    isSystemMessage = row.bool("is_system_message")
    isServiceMessage = row.bool("is_service_message")
    isForward = row.bool("is_forward")
    isArchived = row.bool("is_archive")
    isAudioMessage = row.bool("is_audio_message")
    isPlayed = row.bool("is_played")
    isCorrupt = row.bool("is_corrupt")
    isSpam = row.bool("is_spam")
    isExpirable = row.bool("is_expirable")
    hasDDResults = row.bool("has_dd_results")
    wasDataDetected = row.bool("was_data_detected")
    wasDeduplicated = row.bool("was_deduplicated")
    cacheHasAttachments = row.bool("cache_has_attachments")
    cacheRoomnames = row.optional("cache_roomnames")

    itemType = row.optional("item_type") ?? 0
    groupTitle = row.optional("group_title")
    groupActionType = row.optional("group_action_type") ?? 0
    shareStatus = row.optional("share_status")
    shareDirection = row.optional("share_direction")
    balloonBundleID = row.optional("balloon_bundle_id")
    expressiveSendStyleID = row.optional("expressive_send_style_id")
    associatedMessageGUID = row.optional("associated_message_guid")
    associatedMessageType = row.optional("associated_message_type") ?? 0
    associatedMessageEmoji = row.optional("associated_message_emoji")
    scheduleType = row.optional("schedule_type") ?? 0
    scheduleState = row.optional("schedule_state") ?? 0
    payloadData = row.optional("payload_data")
    messageSummaryInfo = row.optional("message_summary_info")

    threadOriginatorGUID = row.optional("thread_originator_guid")
    threadOriginatorPart = row.optional("thread_originator_part")
    replyToGUID = row.optional("reply_to_guid")

    dateEdited = AppleTimestamp.column(row.optional("date_edited"), unit: dateUnit)
    dateRetracted = AppleTimestamp.column(row.optional("date_retracted"), unit: dateUnit)
    partCount = row.optional("part_count")

    wasDeliveredQuietly = row.boolIfPresent("was_delivered_quietly")
    didNotifyRecipient = row.boolIfPresent("did_notify_recipient")
  }

  /// The message text, preferring `attributedBody` when `text` is empty.
  ///
  /// Mirrors `universalText(true)`: attachment placeholders stripped, whitespace trimmed.
  public func universalText() -> String? {
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return AttributedBodyDecoder.cleanText(text)
    }
    guard let attributedBody, !attributedBody.isEmpty else { return nil }
    guard let decoded = try? AttributedBodyDecoder.decode(attributedBody) else { return nil }
    return decoded.text.isEmpty ? nil : decoded.text
  }

  /// A reaction targets a message, optionally a specific part.
  ///
  /// `associated_message_guid` carries a prefix that encodes which: `p:0/GUID` means part
  /// 0, `bp:GUID` is the balloon-plugin form, and a bare GUID targets the whole message.
  public var associatedMessageTarget: (guid: String, partIndex: Int)? {
    guard let raw = associatedMessageGUID, !raw.isEmpty else { return nil }
    if raw.hasPrefix("p:") {
      let body = raw.dropFirst(2)
      let pieces = body.split(separator: "/", maxSplits: 1)
      if pieces.count == 2, let index = Int(pieces[0]) {
        return (String(pieces[1]), index)
      }
      return (String(body), 0)
    }
    if raw.hasPrefix("bp:") {
      return (String(raw.dropFirst(3)), 0)
    }
    return (raw, 0)
  }
}

public struct ChatRow: Sendable {
  public let rowID: Int64
  public let guid: String
  /// 43 is a group, 45 a direct message. The serializers branch on this.
  public let style: Int
  public let chatIdentifier: String?
  public let serviceName: String?
  public let displayName: String?
  public let roomName: String?
  public let isArchived: Bool
  public let isFiltered: Bool
  public let groupID: String?
  public let lastAddressedHandle: String?
  public let lastReadMessageTimestamp: Int64?
  /// The raw `properties` blob — a binary plist, decoded by the serializer.
  ///
  /// Kept undecoded here for the same reason `attributedBody` is: decoding belongs at the
  /// wire boundary, where the shim's exception barrier already lives.
  public let properties: Data?

  public var isGroup: Bool { style == 43 }

  init(row: Row) {
    rowID = row["ROWID"]
    guid = row["guid"]
    style = row.optional("style") ?? 45
    chatIdentifier = row.optional("chat_identifier")
    serviceName = row.optional("service_name")
    displayName = row.optional("display_name")
    roomName = row.optional("room_name")
    isArchived = row.bool("is_archived")
    isFiltered = row.bool("is_filtered")
    groupID = row.optional("group_id")
    lastAddressedHandle = row.optional("last_addressed_handle")
    lastReadMessageTimestamp = row.optional("last_read_message_timestamp")
    properties = row.optional("properties")
  }
}

public struct HandleRow: Sendable {
  public let rowID: Int64
  /// The address. Serialized as `address`, not `id` — a rename the wire format requires.
  public let id: String
  public let country: String?
  public let service: String
  public let uncanonicalizedID: String?
  public let personCentricID: String?

  init(row: Row) {
    rowID = row["ROWID"]
    id = row["id"]
    country = row.optional("country")
    service = row.optional("service") ?? "iMessage"
    uncanonicalizedID = row.optional("uncanonicalized_id")
    personCentricID = row.optional("person_centric_id")
  }
}

public struct AttachmentRow: Sendable {
  public let rowID: Int64
  public let guid: String
  /// Uses `~` paths, and the file may be purged to iCloud.
  public let filename: String?
  public let uti: String?
  public let mimeType: String?
  public let transferName: String?
  public let totalBytes: Int64
  public let transferState: Int
  public let isOutgoing: Bool
  public let isSticker: Bool
  public let hideAttachment: Bool
  public let originalGUID: String?
  public let createdDate: AppleTimestamp?

  init(row: Row, dateUnit: AppleTimestamp.Unit) {
    rowID = row["ROWID"]
    guid = row["guid"]
    filename = row.optional("filename")
    uti = row.optional("uti")
    mimeType = row.optional("mime_type")
    transferName = row.optional("transfer_name")
    totalBytes = row.optional("total_bytes") ?? 0
    transferState = row.optional("transfer_state") ?? 0
    isOutgoing = row.bool("is_outgoing")
    isSticker = row.bool("is_sticker")
    hideAttachment = row.bool("hide_attachment")
    originalGUID = row.optional("original_guid")
    createdDate = AppleTimestamp.column(row.optional("created_date"), unit: dateUnit)
  }

  /// Expands the stored `~` path. Absence of the file is a state, not an error — it may
  /// have been purged to iCloud and be re-downloadable through the Private API.
  public var resolvedPath: String? {
    guard let filename else { return nil }
    if filename.hasPrefix("~") {
      return NSString(string: filename).expandingTildeInPath
    }
    return filename
  }
}

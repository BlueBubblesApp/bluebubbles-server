//  Rows
//  Value types over chat.db rows.
//
//  Deliberately dumb: they map columns and nothing else. Business rules live above them, so
//  a schema change touches one layer.
//
//  Every optional here means the column is ABSENT from this schema, not that the value is
//  null, which is the distinction the serializer carries onto the wire, since clients treat
//  a missing key differently from a null one.

import BBCore
import Foundation
import GRDB
import Logging

/// What the change detector compares: a message's identity and the fields that can move
/// after it is written. See `MessageRepository.messageFingerprints`.
public struct MessageFingerprintRow: Sendable, Hashable {
  public let rowID: Int64
  public let guid: String
  /// Converted exactly as `IMessageRow` converts them: a zero column is "not set" and
  /// reads as nil, so a fingerprint taken from either row shape compares equal.
  public let date: AppleTimestamp?
  public let dateRead: AppleTimestamp?
  public let dateDelivered: AppleTimestamp?
  public let datePlayed: AppleTimestamp?
  public let dateEdited: AppleTimestamp?
  public let dateRetracted: AppleTimestamp?
  public let didNotifyRecipient: Bool?
  public let error: Int

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) {
    rowID = r.required("ROWID")
    guid = r.required("guid")
    date = AppleTimestamp.column(r.optional("date"), unit: dateUnit)
    dateRead = AppleTimestamp.column(r.optional("date_read"), unit: dateUnit)
    dateDelivered = AppleTimestamp.column(r.optional("date_delivered"), unit: dateUnit)
    datePlayed = AppleTimestamp.column(r.optional("date_played"), unit: dateUnit)
    dateEdited = AppleTimestamp.column(r.optional("date_edited"), unit: dateUnit)
    dateRetracted = AppleTimestamp.column(r.optional("date_retracted"), unit: dateUnit)
    didNotifyRecipient = r.boolIfPresent("did_notify_recipient")
    error = r.optional("error") ?? 0
  }
}

/// Column positions, resolved once per result set.
///
/// `Row`'s string subscript is a linear scan of the column list, and `hasColumn` is a second
/// one. A message is about seventy columns and every one of them was read through both, so
/// mapping a single row cost thousands of string comparisons: measured at 87ms per thousand
/// rows against 1.8ms positional, which made this — not the SQL, not the decoding — the
/// dominant cost of serving a page of messages.
///
/// The real database has more columns than the fixtures do, and the scan is O(columns) per
/// call, so the measured number understates it.
struct ColumnIndex: Sendable {
  private let positions: [String: Int]

  /// Built from any row of a result set: every row of one statement has the same columns.
  init(_ row: Row) {
    var positions = [String: Int](minimumCapacity: row.count)
    // First occurrence wins, which is what `Row`'s own leftmost-match lookup does when a
    // join puts the same column name in twice.
    for (offset, name) in row.columnNames.enumerated() where positions[name] == nil {
      positions[name] = offset
    }
    self.positions = positions
  }

  @inline(__always)
  func position(_ column: String) -> Int? { positions[column] }
}

/// A row together with its column positions.
///
/// Reads by index when the name is in the index and falls back to the string path when it is
/// not — `Row` matches column names case-insensitively and this does not — so a statement
/// that spells a column differently still maps correctly, only at the old speed. That
/// fallback is what makes this change behaviour-preserving by construction rather than by
/// audit of every SELECT.
struct MappedRow {
  let row: Row
  let columns: ColumnIndex

  /// A column the schema always has. Traps on absence exactly as `Row` does, because a
  /// message with no ROWID is a broken database rather than a missing feature.
  @inline(__always)
  func required<T: DatabaseValueConvertible>(_ column: String) -> T {
    if let index = columns.position(column) { return row[index] }
    return row[column]
  }

  /// Safe column access: a column absent from this schema reads as nil rather than trapping.
  @inline(__always)
  func optional<T: DatabaseValueConvertible>(_ column: String) -> T? {
    if let index = columns.position(column) { return row[index] as T? }
    guard row.hasColumn(column) else { return nil }
    return row[column] as T?
  }

  @inline(__always)
  func bool(_ column: String) -> Bool {
    let value: Int64? = optional(column)
    return value == 1
  }

  @inline(__always)
  func boolIfPresent(_ column: String) -> Bool? {
    guard columns.position(column) != nil || row.hasColumn(column) else { return nil }
    guard let value: Int64 = optional(column) else { return nil }
    return value == 1
  }
}

extension Row {
  /// One row, mapped on its own.
  ///
  /// Builds a `ColumnIndex` for a single row, which is precisely the cost `mapRows` exists to
  /// amortise: right for a fixture or a single-row lookup, wrong inside a loop.
  func mapped<T>(_ transform: (MappedRow) -> T) -> T {
    transform(MappedRow(row: self, columns: ColumnIndex(self)))
  }
}

extension Array where Element == Row {
  /// Maps a whole result set through ONE shared `ColumnIndex`.
  ///
  /// The point of the type is that the index is built once per statement rather than once
  /// per row, so this is the only intended way to build row values in bulk.
  func mapRows<T>(_ transform: (MappedRow) -> T) -> [T] {
    guard let first = first else { return [] }
    let columns = ColumnIndex(first)
    // The precondition, enforced in debug rather than written down and hoped for: every row
    // must have the SAME columns in the same order. True for any result set, because one
    // statement produces one column list -- and false for rows built from a dictionary
    // literal, whose order is arbitrary and varies between processes. A row that disagrees
    // reads another column's value under the name it asked for, which is silent, and the
    // name-miss fallback cannot catch it because the name is present, just elsewhere.
    assert(
      allSatisfy { $0.columnNames.elementsEqual(first.columnNames) },
      "mapRows was given rows from more than one statement; use `Row.mapped` per row instead"
    )
    return map { transform(MappedRow(row: $0, columns: columns)) }
  }
}

public struct IMessageRow: Sendable {

  public let rowID: Int64
  public let guid: String
  /// Frequently NULL; the real content is in `attributedBody`.
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
  /// The emoji of an emoji tapback (types 2006 / 3006). SEQUOIA and later; nil elsewhere.
  ///
  /// This said Sonoma. `SchemaProfile` lists `associated_message_emoji` as a Sequoia
  /// addition, `MessageMutation.checkEmojiReactionSupported` gates on macOS 15, and the
  /// committed fixtures agree: `chat-sonoma.db` has no such column and `chat-sequoia.db`
  /// has it. Three places right and one wrong is the shape that gets believed.
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

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) {
    rowID = r.required("ROWID")
    guid = r.required("guid")
    text = r.optional("text")
    attributedBody = r.optional("attributedBody")
    subject = r.optional("subject")
    handleID = r.optional("handle_id")
    otherHandle = r.optional("other_handle")
    country = r.optional("country")
    service = r.optional("service")
    error = r.optional("error") ?? 0

    date = AppleTimestamp.column(r.optional("date"), unit: dateUnit)
    dateRead = AppleTimestamp.column(r.optional("date_read"), unit: dateUnit)
    dateDelivered = AppleTimestamp.column(r.optional("date_delivered"), unit: dateUnit)
    datePlayed = AppleTimestamp.column(r.optional("date_played"), unit: dateUnit)
    timeExpressiveSendPlayed = AppleTimestamp.column(
      r.optional("time_expressive_send_played"), unit: dateUnit
    )

    isDelivered = r.bool("is_delivered")
    isFromMe = r.bool("is_from_me")
    isRead = r.bool("is_read")
    isSent = r.bool("is_sent")
    isEmpty = r.bool("is_empty")
    isDelayed = r.bool("is_delayed")
    isAutoReply = r.bool("is_auto_reply")
    isSystemMessage = r.bool("is_system_message")
    isServiceMessage = r.bool("is_service_message")
    isForward = r.bool("is_forward")
    isArchived = r.bool("is_archive")
    isAudioMessage = r.bool("is_audio_message")
    isPlayed = r.bool("is_played")
    isCorrupt = r.bool("is_corrupt")
    isSpam = r.bool("is_spam")
    isExpirable = r.bool("is_expirable")
    hasDDResults = r.bool("has_dd_results")
    wasDataDetected = r.bool("was_data_detected")
    wasDeduplicated = r.bool("was_deduplicated")
    cacheHasAttachments = r.bool("cache_has_attachments")
    cacheRoomnames = r.optional("cache_roomnames")

    itemType = r.optional("item_type") ?? 0
    groupTitle = r.optional("group_title")
    groupActionType = r.optional("group_action_type") ?? 0
    shareStatus = r.optional("share_status")
    shareDirection = r.optional("share_direction")
    balloonBundleID = r.optional("balloon_bundle_id")
    expressiveSendStyleID = r.optional("expressive_send_style_id")
    associatedMessageGUID = r.optional("associated_message_guid")
    associatedMessageType = r.optional("associated_message_type") ?? 0
    associatedMessageEmoji = r.optional("associated_message_emoji")
    scheduleType = r.optional("schedule_type") ?? 0
    scheduleState = r.optional("schedule_state") ?? 0
    payloadData = r.optional("payload_data")
    messageSummaryInfo = r.optional("message_summary_info")

    threadOriginatorGUID = r.optional("thread_originator_guid")
    threadOriginatorPart = r.optional("thread_originator_part")
    replyToGUID = r.optional("reply_to_guid")

    dateEdited = AppleTimestamp.column(r.optional("date_edited"), unit: dateUnit)
    dateRetracted = AppleTimestamp.column(r.optional("date_retracted"), unit: dateUnit)
    partCount = r.optional("part_count")

    wasDeliveredQuietly = r.boolIfPresent("was_delivered_quietly")
    didNotifyRecipient = r.boolIfPresent("did_notify_recipient")
  }

  /// The message text, preferring `attributedBody` when `text` is empty.
  ///
  /// Mirrors `universalText(true)`: attachment placeholders stripped, whitespace trimmed.
  public func universalText() -> String? {
    universalText(decoded: nil)
  }

  /// - Parameter decoded: a body the caller has ALREADY decoded, or nil to decode here.
  ///
  /// The serializer decodes `attributedBody` for its own field a few lines after asking for
  /// this, so without somewhere to hand the result the same typedstream was parsed twice for
  /// every row of every page. It is passed rather than returned because the caller only has
  /// one when it needed one anyway: `text` being present means neither path decodes at all.
  public func universalText(decoded: AttributedBody?) -> String? {
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return AttributedBodyDecoder.cleanText(text)
    }
    if let decoded {
      return decoded.text.isEmpty ? nil : decoded.text
    }
    guard let attributedBody, !attributedBody.isEmpty else { return nil }
    // REPORTED, not swallowed. The rule is that a `try?` says where the failure goes, and
    // this one named nowhere and logged nothing: a blob the shim rejects — the torn-row
    // case `BBTypedStreamShim` exists for — became a null body and, through this method, a
    // null `text`. A message with no words, and no trace anywhere of why.
    //
    // The GUID is not personal data and is what makes the line actionable; the error's
    // `reason` is the shim's own and carries no message content.
    do {
      let decoded = try AttributedBodyDecoder.decode(attributedBody)
      return decoded.text.isEmpty ? nil : decoded.text
    } catch {
      Rows.logger.debug(
        "Could not decode an attributedBody; the message will have no text",
        metadata: [
          "messageGuid": .string(guid),
          "reason": .string(String(describing: error)),
        ])
      return nil
    }
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
  /// The raw `properties` blob: a binary plist, decoded by the serializer.
  ///
  /// Kept undecoded here for the same reason `attributedBody` is: decoding belongs at the
  /// wire boundary, where the shim's exception barrier already lives.
  public let properties: Data?

  public var isGroup: Bool { style == 43 }

  init(_ r: MappedRow) {
    rowID = r.required("ROWID")
    guid = r.required("guid")
    style = r.optional("style") ?? 45
    chatIdentifier = r.optional("chat_identifier")
    serviceName = r.optional("service_name")
    displayName = r.optional("display_name")
    roomName = r.optional("room_name")
    isArchived = r.bool("is_archived")
    isFiltered = r.bool("is_filtered")
    groupID = r.optional("group_id")
    lastAddressedHandle = r.optional("last_addressed_handle")
    lastReadMessageTimestamp = r.optional("last_read_message_timestamp")
    properties = r.optional("properties")
  }
}

public struct HandleRow: Sendable {
  public let rowID: Int64
  /// The address. Serialized as `address`, not `id`: a rename the wire format requires.
  public let id: String
  public let country: String?
  public let service: String
  public let uncanonicalizedID: String?
  public let personCentricID: String?

  init(_ r: MappedRow) {
    rowID = r.required("ROWID")
    id = r.required("id")
    country = r.optional("country")
    service = r.optional("service") ?? "iMessage"
    uncanonicalizedID = r.optional("uncanonicalized_id")
    personCentricID = r.optional("person_centric_id")
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

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) {
    rowID = r.required("ROWID")
    guid = r.required("guid")
    filename = r.optional("filename")
    uti = r.optional("uti")
    mimeType = r.optional("mime_type")
    transferName = r.optional("transfer_name")
    totalBytes = r.optional("total_bytes") ?? 0
    transferState = r.optional("transfer_state") ?? 0
    isOutgoing = r.bool("is_outgoing")
    isSticker = r.bool("is_sticker")
    hideAttachment = r.bool("hide_attachment")
    originalGUID = r.optional("original_guid")
    createdDate = AppleTimestamp.column(r.optional("created_date"), unit: dateUnit)
  }

  /// Expands the stored `~` path. Absence of the file is a state, not an error: it may
  /// have been purged to iCloud and be re-downloadable through the Private API.
  public var resolvedPath: String? {
    guard let filename else { return nil }
    if filename.hasPrefix("~") {
      return NSString(string: filename).expandingTildeInPath
    }
    return filename
  }
}

/// Where a row-level decode failure is reported. One logger for the file rather than one per
/// row type, which would be a logger per message.
enum Rows {
  static let logger = Logger(label: "bluebubbles.imessage.rows")
}

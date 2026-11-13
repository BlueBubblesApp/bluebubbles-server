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
import BBPersistence
import Foundation
import GRDB
import Logging

/// The fields of a message that can move after it is written: what the change detector holds
/// for each GUID and compares to decide that a message was updated.
///
/// One type for both row shapes it is taken from, the narrow fingerprint query and a fully
/// hydrated `IMessageRow`, so a field added to one cannot be missing from the other. A
/// fingerprint the detector cached from one shape and compares against the other would then
/// report that field as moved on every tick, or never.
public struct MessageFingerprint: Sendable, Hashable {
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
  /// `associated_message_type`. It moves once in a row's life and only on an app balloon:
  /// Messages rewrites the turn a session update supersedes to 3 when the update lands (the
  /// first turn from 0, a later one from 2), on the sending Mac as well as on the recipient's
  /// device, and nothing else in the row changes. A client drawing a session as one balloon
  /// has to hear that a turn is now superseded, so the rewrite is an update rather than a
  /// silent edit. MEASURED on 27.0.1 with turns this server sent.
  public let associatedMessageType: Int

  public init(
    date: AppleTimestamp?, dateRead: AppleTimestamp?, dateDelivered: AppleTimestamp?,
    datePlayed: AppleTimestamp?, dateEdited: AppleTimestamp?, dateRetracted: AppleTimestamp?,
    didNotifyRecipient: Bool?, error: Int, associatedMessageType: Int
  ) {
    self.date = date
    self.dateRead = dateRead
    self.dateDelivered = dateDelivered
    self.datePlayed = datePlayed
    self.dateEdited = dateEdited
    self.dateRetracted = dateRetracted
    self.didNotifyRecipient = didNotifyRecipient
    self.error = error
    self.associatedMessageType = associatedMessageType
  }

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) {
    self.init(
      date: AppleTimestamp.column(r.optional("date"), unit: dateUnit),
      dateRead: AppleTimestamp.column(r.optional("date_read"), unit: dateUnit),
      dateDelivered: AppleTimestamp.column(r.optional("date_delivered"), unit: dateUnit),
      datePlayed: AppleTimestamp.column(r.optional("date_played"), unit: dateUnit),
      dateEdited: AppleTimestamp.column(r.optional("date_edited"), unit: dateUnit),
      dateRetracted: AppleTimestamp.column(r.optional("date_retracted"), unit: dateUnit),
      didNotifyRecipient: r.boolIfPresent("did_notify_recipient"),
      error: r.optional("error") ?? 0,
      associatedMessageType: r.optional("associated_message_type") ?? 0)
  }

  public init(_ message: IMessageRow) {
    self.init(
      date: message.date, dateRead: message.dateRead, dateDelivered: message.dateDelivered,
      datePlayed: message.datePlayed, dateEdited: message.dateEdited,
      dateRetracted: message.dateRetracted, didNotifyRecipient: message.didNotifyRecipient,
      error: message.error, associatedMessageType: message.associatedMessageType)
  }
}

/// A message's identity and its fingerprint: one row of the change detector's query. See
/// `MessageRepository.messageFingerprints`.
public struct MessageFingerprintRow: Sendable, Hashable {
  public let rowID: Int64
  public let guid: String
  public let fingerprint: MessageFingerprint

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) throws {
    rowID = try r.required("ROWID")
    guid = try r.required("guid")
    fingerprint = MessageFingerprint(r, dateUnit: dateUnit)
  }
}

/// When a chat was last read: one row of the change detector's chat query. See
/// `MessageRepository.chatReadMarks(readAfter:)`.
///
/// Keyed by `rowID`, never by `guid`: the GUID is carried only to be put on the wire, because
/// it is not comparable (`ChatGUID`), and the ROWID is what the detector remembers.
public struct ChatReadMark: Sendable, Hashable {
  public let rowID: Int64
  public let guid: String
  /// `chat.last_read_message_timestamp`, raw. Never nil here: the query selects only rows
  /// whose value is past a floor, and an unset column is zero.
  public let lastRead: AppleTimestamp

  public init(rowID: Int64, guid: String, lastRead: AppleTimestamp) {
    self.rowID = rowID
    self.guid = guid
    self.lastRead = lastRead
  }

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) throws {
    rowID = try r.required("ROWID")
    guid = try r.required("guid")
    lastRead = AppleTimestamp(
      rawValue: try r.required("last_read_message_timestamp"), unit: dateUnit)
  }
}

extension RowSource {
  /// Messages' own database. A bad cell is logged with its row's `ROWID` when the result
  /// carries one.
  static let chatDatabase = RowSource(
    file: "chat.db", summary: "the message database", keyColumn: "ROWID")
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

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) throws {
    rowID = try r.required("ROWID")
    guid = try r.required("guid")
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
    Self.universalText(
      text: text, attributedBody: attributedBody, decoded: decoded,
      logMetadata: ["messageGuid": .string(guid)])
  }

  /// What a message says, from whichever column holds it: THE rule, for the wire `text` and
  /// for the search index alike.
  ///
  /// `text` when it has anything in it, cleaned; otherwise the decoded `attributedBody`,
  /// cleaned the same way. The indexer once resolved this itself, without the trim and from
  /// the decoder's raw `string`, so the index and the response disagreed about what a
  /// message said, and its decode failures vanished. Static, so a caller holding the two
  /// columns rather than a row reaches the same answer.
  ///
  /// `logMetadata` identifies the row in the one line a failed decode writes: a GUID or a
  /// ROWID, neither of them personal data.
  static func universalText(
    text: String?, attributedBody: Data?, decoded: AttributedBody? = nil,
    logMetadata: Logger.Metadata
  ) -> String? {
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
    // The error's `reason` is the shim's own and carries no message content.
    do {
      let decoded = try AttributedBodyDecoder.decode(attributedBody)
      return decoded.text.isEmpty ? nil : decoded.text
    } catch {
      var metadata = logMetadata
      metadata["reason"] = .string(String(describing: error))
      Rows.logger.debug(
        "Could not decode an attributedBody; the message will have no text",
        metadata: metadata)
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
  /// When this chat was last read on any of the account's devices, or nil if it never has been.
  /// Only rises: marking a chat unread leaves it where it was, so it does not say a chat is read.
  public let lastReadMessageTimestamp: AppleTimestamp?
  /// The raw `properties` blob: a binary plist, decoded by the serializer.
  ///
  /// Kept undecoded here for the same reason `attributedBody` is: decoding belongs at the
  /// wire boundary, where the shim's exception barrier already lives.
  public let properties: Data?

  public var isGroup: Bool { style == 43 }

  /// The `style` of a one-to-one chat.
  static let directStyle = 45

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) throws {
    rowID = try r.required("ROWID")
    guid = try r.required("guid")
    // `style` is nullable in every sampled schema (`docs/database/samples/*/chat.sql`), and a
    // NULL is read as a direct chat. That is a DIVERGENCE: the reference passes the column
    // through (`style: chat.style`, from a column it declares `nullable: true`), so it would
    // emit `style: null`. 45 is kept because everything here branches on `isGroup`,
    // and a chat that does not say it is a group is handled as a direct one throughout.
    // `RowLiteralTests` pins it.
    style = r.optional("style") ?? Self.directStyle
    chatIdentifier = r.optional("chat_identifier")
    serviceName = r.optional("service_name")
    displayName = r.optional("display_name")
    roomName = r.optional("room_name")
    isArchived = r.bool("is_archived")
    isFiltered = r.bool("is_filtered")
    groupID = r.optional("group_id")
    lastAddressedHandle = r.optional("last_addressed_handle")
    lastReadMessageTimestamp = (r.optional("last_read_message_timestamp") as Int64?).map {
      AppleTimestamp(rawValue: $0, unit: dateUnit)
    }
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

  init(_ r: MappedRow) throws {
    rowID = try r.required("ROWID")
    id = try r.required("id")
    country = r.optional("country")
    // Unreachable from a real chat.db: `handle.service` is `TEXT NOT NULL` in every sampled
    // schema (`docs/database/samples/*/handle.sql`), and `RowLiteralTests` holds the samples
    // to that. The fallback exists so a schema that broke the rule would degrade rather than
    // trap, and it is the reference's own declared default.
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
  /// Where a placed sticker sits on its parent, from `sticker_user_info`. Nil for anything
  /// that is not a placed sticker; see `StoredStickerPlacement`.
  public let stickerPlacement: StoredStickerPlacement?

  init(_ r: MappedRow, dateUnit: AppleTimestamp.Unit) throws {
    rowID = try r.required("ROWID")
    guid = try r.required("guid")
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
    stickerPlacement = (r.optional("sticker_user_info") as Data?).flatMap {
      StoredStickerPlacement(stickerUserInfo: $0)
    }
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

/// The logger for what goes wrong building a row from cells that did convert. One for the
/// file rather than one per row type, which would be a logger per message. A cell that does
/// not convert is reported by `MappedRow` itself, in BBPersistence.
enum Rows {
  static let logger = Logger(label: "bluebubbles.imessage.rows")
}

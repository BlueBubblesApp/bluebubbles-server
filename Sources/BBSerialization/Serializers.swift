//  Serializers
//  chat.db rows -> the client wire format.
//
//  Field order below follows the existing MessageSerializer.convert so the two can be read
//  side by side during the port. Every macOS-gated field is emitted only when the schema
//  actually has the column, which keeps "absent" distinct from "null".
//
//  See `.claude/docs/api.md` for the full invariant table.

import BBCore
import BBIMessage
import Foundation
import Logging

public struct MessageSerializer: Sendable {

  /// Where a decode failure is reported.
  ///
  /// The `try?` here named no other path and logged nothing, against the rule that a `try?`
  /// says where the failure goes. A blob the shim rejects — the torn-row case
  /// `BBTypedStreamShim` exists for — became `attributedBody: null` with nothing anywhere
  /// saying why, on a field clients read for formatting and mentions.
  ///
  /// Debug rather than warning: a handful of rows in a long history legitimately fail, and
  /// this runs once per message in a page. The GUID is not personal data and is what makes
  /// the line actionable.
  private static let logger = Logger(label: "bluebubbles.serialization.message")

  static func decodeAttributedBody(_ data: Data, guid: String) -> AttributedBody? {
    do {
      return try AttributedBodyDecoder.decode(data)
    } catch {
      logger.debug(
        "Could not decode an attributedBody; the field will be null",
        metadata: [
          "messageGuid": .string(guid),
          "reason": .string(String(describing: error)),
        ])
      return nil
    }
  }

  private let profile: SchemaProfile

  public init(profile: SchemaProfile) {
    self.profile = profile
  }

  public struct Context: Sendable {
    public var handle: HandleRow?
    public var chats: [ChatRow]
    /// Set only through `load(attachments:from:withMetadata:)`, so attachments cannot reach
    /// the serializer without what was read off disk for them.
    public private(set) var attachments: [AttachmentRow] = []
    /// What was read off disk for each attachment, by GUID. Loaded by the interface layer
    /// like every other relation, so the serializer stays free of file I/O; see
    /// `AttachmentMetadataReader`, and `Query.withAttachmentMetadata`, which gates the cost.
    public private(set) var attachmentMetadata: [String: AttachmentMetadata] = [:]
    /// The attachments whose still has a Live Photo video beside it, by GUID.
    public private(set) var livePhotoGUIDs: Set<String> = []
    public var participantsByChatGUID: [String: [HandleRow]]

    public init(
      handle: HandleRow? = nil,
      chats: [ChatRow] = [],
      participantsByChatGUID: [String: [HandleRow]] = [:]
    ) {
      self.handle = handle
      self.chats = chats
      self.participantsByChatGUID = participantsByChatGUID
    }

    /// Attaches these rows, and reads what the wire says about their files.
    ///
    /// `hasLivePhoto` is read for every attachment, because every full serialization emits
    /// it; `metadata` only when asked, because it opens the file. Both through `reader`,
    /// whose cache is what makes a page that repeats an attachment pay once.
    public mutating func load(
      attachments rows: [AttachmentRow],
      from reader: AttachmentMetadataReader,
      withMetadata: Bool
    ) async {
      attachments = rows
      attachmentMetadata = [:]
      livePhotoGUIDs = []
      for row in rows {
        if await reader.hasLivePhoto(for: row) { livePhotoGUIDs.insert(row.guid) }
        if withMetadata { attachmentMetadata[row.guid] = await reader.metadata(for: row) }
      }
    }
  }

  public func serialize(
    _ message: IMessageRow,
    context: Context,
    config: MessageSerializerConfig = .full,
    attachmentConfig: AttachmentSerializerConfig = .default,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    // MARK: Always present

    object.set("originalROWID", .int64(message.rowID))
    object.set(MessageWireKey.guid, .string(message.guid))

    // Decoded AT MOST ONCE, and only when something actually needs it.
    //
    // `universalText()` parses `attributedBody` when `text` is empty -- which the rulebook
    // records as the normal case for an AppleScript send -- and the `attributedBody` field
    // below parsed the same bytes again. Two typedstream parses per row, on every row of
    // every page. Neither runs when `text` is present and the field is switched off, which
    // is why this is lazy rather than hoisted.
    var decodedBody: AttributedBody?
    var hasDecoded = false
    func attributedBody() -> AttributedBody? {
      if hasDecoded { return decodedBody }
      hasDecoded = true
      decodedBody = message.attributedBody.flatMap {
        Self.decodeAttributedBody($0, guid: message.guid)
      }
      return decodedBody
    }

    // Only decodes when `text` is empty; `universalText` asks for it in that case alone.
    let needsBodyForText =
      message.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    object.setOrNull(
      MessageWireKey.text,
      message.universalText(decoded: needsBodyForText ? attributedBody() : nil)
        .map(JSONValue.string))

    // A DECODED STRUCTURE (`[{ string, runs }]`) not base64. Clients index into it.
    //
    // Nulled AFTER conversion rather than skipped, so the Ventura text-extraction path
    // still runs. The key stays present either way.
    object.setOrNull(
      "attributedBody",
      config.parseAttributedBody
        ? attributedBody()
          .map { AttributedBodyWire.encode($0, format: config.attributedBodyFormat) }
        : nil
    )

    object.setOrNull(
      MessageWireKey.handle,
      context.handle.map { HandleSerializer.serialize($0, isForNotification: isForNotification) }
    )
    object.setOrNull("handleId", message.handleID.map(JSONValue.int64))
    object.setOrNull("otherHandle", message.otherHandle.map(JSONValue.int64))

    object.set(
      "attachments",
      .array(
        context.attachments.map {
          AttachmentSerializer.serialize(
            $0, config: attachmentConfig,
            metadata: context.attachmentMetadata[$0.guid],
            hasLivePhoto: context.livePhotoGUIDs.contains($0.guid),
            isForNotification: isForNotification)
        }))

    object.setOrNull("subject", message.subject.map(JSONValue.string))
    object.set("error", .int(message.error))

    // Epoch milliseconds, or null. Never ISO strings.
    object.setOrNull("dateCreated", message.date?.epochMilliseconds.map(JSONValue.int64))
    object.setOrNull("dateRead", message.dateRead?.epochMilliseconds.map(JSONValue.int64))
    object.setOrNull("dateDelivered", message.dateDelivered?.epochMilliseconds.map(JSONValue.int64))

    object.set("isDelivered", .bool(message.isDelivered))
    object.set(MessageWireKey.isFromMe, .bool(message.isFromMe))
    object.set("hasDdResults", .bool(message.hasDDResults))
    object.set("isArchived", .bool(message.isArchived))
    object.set("itemType", .int(message.itemType))
    object.setOrNull("groupTitle", message.groupTitle.map(JSONValue.string))
    object.set("groupActionType", .int(message.groupActionType))
    object.setOrNull("balloonBundleId", message.balloonBundleID.map(JSONValue.string))
    object.setOrNull("associatedMessageGuid", message.associatedMessageGUID.map(JSONValue.string))
    object.setOrNull(
      "associatedMessageType",
      ReactionWireType.name(for: message.associatedMessageType).map(JSONValue.string)
    )
    // OURS, not the reference's: the reference never read this column, so an emoji
    // tapback reached clients as type "2006" with no way to know which emoji. Present
    // only when there is one (never a null key) so a plain message's payload, and the
    // 4000-byte FCM cap, are untouched. Declared in `acceptedDifferences`.
    if let emoji = message.associatedMessageEmoji, !emoji.isEmpty {
      object.set("associatedMessageEmoji", .string(emoji))
    }
    // OURS. Send Later: without these a scheduled message is indistinguishable from one
    // already sent, and a client would show it as delivered. Present only on scheduled
    // rows (every ordinary message has 0/0) so nothing changes for anyone else.
    if message.scheduleType != 0 || message.scheduleState != 0 {
      object.set("scheduleType", .int(message.scheduleType))
      object.set("scheduleState", .int(message.scheduleState))
    }
    object.setOrNull("expressiveSendStyleId", message.expressiveSendStyleID.map(JSONValue.string))
    object.setOrNull("threadOriginatorGuid", message.threadOriginatorGUID.map(JSONValue.string))
    object.set("hasPayloadData", .bool(message.payloadData != nil))

    // MARK: Stripped from the notification variant
    //
    // These ~18 fields are exactly what the FCM and webhook payloads shed.

    if !isForNotification {
      object.setOrNull("country", message.country.map(JSONValue.string))
      object.set("isDelayed", .bool(message.isDelayed))
      object.set("isAutoReply", .bool(message.isAutoReply))
      object.set("isSystemMessage", .bool(message.isSystemMessage))
      object.set("isServiceMessage", .bool(message.isServiceMessage))
      object.set("isForward", .bool(message.isForward))
      object.setOrNull("threadOriginatorPart", message.threadOriginatorPart.map(JSONValue.string))
      object.set("isCorrupt", .bool(message.isCorrupt))
      object.setOrNull("datePlayed", message.datePlayed?.epochMilliseconds.map(JSONValue.int64))
      object.setOrNull("cacheRoomnames", message.cacheRoomnames.map(JSONValue.string))
      object.set("isSpam", .bool(message.isSpam))
      // Renamed on the wire: isExpired reads message.isExpirable.
      object.set("isExpired", .bool(message.isExpirable))
      object.setOrNull(
        "timeExpressiveSendPlayed",
        message.timeExpressiveSendPlayed?.epochMilliseconds.map(JSONValue.int64)
      )
      object.set("isAudioMessage", .bool(message.isAudioMessage))
      object.setOrNull("replyToGuid", message.replyToGUID.map(JSONValue.string))
      object.setOrNull("shareStatus", message.shareStatus.map(JSONValue.int))
      object.setOrNull("shareDirection", message.shareDirection.map(JSONValue.int))

      // Monterey and later. Absent below it, not null.
      object.setIf(
        profile.supportsQuietDelivery, "wasDeliveredQuietly",
        .bool(message.wasDeliveredQuietly ?? false))
      object.setIf(
        profile.supportsQuietDelivery, "didNotifyRecipient",
        .bool(message.didNotifyRecipient ?? false))
    }

    // MARK: Chats

    if config.includeChats {
      object.set(
        MessageWireKey.chats,
        .array(
          context.chats.map { chat in
            ChatSerializer.serialize(
              chat,
              participants: config.loadChatParticipants
                ? (context.participantsByChatGUID[chat.guid] ?? [])
                : [],
              includeParticipants: config.loadChatParticipants,
              isForNotification: isForNotification
            )
          }))
    }

    // MARK: High Sierra and later

    // Both are binary plists, and both go on the wire decoded: same reason as
    // attributedBody above.
    object.setIfOrNull(
      profile.supportsMessageSummaryInfo, "messageSummaryInfo",
      config.parseMessageSummary
        ? PropertyListWire.decode(
          message.messageSummaryInfo, attributedBodyFormat: config.attributedBodyFormat)
        : nil
    )
    object.setIfOrNull(
      profile.supportsPayloadData, "payloadData",
      config.parsePayloadData
        ? PropertyListWire.decode(
          message.payloadData, attributedBodyFormat: config.attributedBodyFormat)
        : nil
    )

    // MARK: Ventura and later

    object.setIfOrNull(
      profile.supportsEditedMessages, "dateEdited",
      message.dateEdited?.epochMilliseconds.map(JSONValue.int64))
    object.setIfOrNull(
      profile.supportsEditedMessages, "dateRetracted",
      message.dateRetracted?.epochMilliseconds.map(JSONValue.int64))
    object.setIfOrNull(
      profile.supportsMessageParts, "partCount",
      message.partCount.map(JSONValue.int))

    return object.build()
  }
}

public enum ChatSerializer {

  public static func serialize(
    _ chat: ChatRow,
    participants: [HandleRow] = [],
    includeParticipants: Bool = true,
    messages: [JSONValue]? = nil,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    object.set("originalROWID", .int64(chat.rowID))
    object.set(ChatWireKey.guid, .string(chat.guid))
    object.set("style", .int(chat.style))
    object.setOrNull("chatIdentifier", chat.chatIdentifier.map(JSONValue.string))
    object.set("isArchived", .bool(chat.isArchived))
    object.setOrNull("displayName", chat.displayName.map(JSONValue.string))

    // The KEY is gated, and its CONTENTS are a separate question: the two get conflated
    // easily and the reference keeps them apart:
    //
    //   - `chat/:guid` and `chat/query` serialize with `DEFAULT_CHAT_CONFIG`, whose
    //     `includeParticipants` is true, so the key is always there. It is `[]` when the
    //     caller did not ask for participants, because the entity was loaded without
    //     them; not because the key was suppressed.
    //   - A chat nested inside a MESSAGE is serialized with
    //     `includeParticipants: loadChatParticipants`, which is false by default, so
    //     there the key is absent entirely.
    //
    // Both directions were measured. Emitting the key unconditionally fails the parity
    // diff on every nested chat; gating it on whether participants were LOADED drops it
    // from `chat/:guid`, where clients read `.participants.length`.
    if includeParticipants {
      object.set(
        "participants",
        .array(
          participants.map {
            HandleSerializer.serialize($0, isForNotification: isForNotification)
          }))
    }
    // `nil` omits the key; a value emits it, empty or not. The same key/contents split as
    // `participants` above, and it has to be expressible both ways because the reference
    // uses both: `chat/query` with `with=lastMessage` serializes a chat it deliberately
    // loaded WITHOUT messages, so the key is present and EMPTY, while `POST /chat/new` and
    // `PUT /chat/:guid` serialize a chat carrying the message the create just sent
    // (`chatInterface.ts` sets `chat.messages = [sentMessage]` on both of its backends).
    //
    // This was a `Bool` that could only ever produce `[]`, which is the "literal in a
    // serializer" failure the root guide names: the shape was right, the diff compares keys
    // and types, and the array was empty on a route whose whole point is handing back the
    // message that was just sent.
    if let messages {
      object.set("messages", .array(messages))
    }

    if !isForNotification {
      object.set("isFiltered", .bool(chat.isFiltered))
      object.setOrNull("groupId", chat.groupID.map(JSONValue.string))
      object.setOrNull("lastAddressedHandle", chat.lastAddressedHandle.map(JSONValue.string))
      // Decoded, not an empty array. This was hardcoded to `[]`, so
      // `lastSeenMessageGuid`, `shouldForceToSMS` and the rest never reached a client:
      // and the key being present made it look like the chat simply had none.
      object.set("properties", PropertyListWire.decode(chat.properties) ?? .array([]))
    }

    return object.build()
  }
}

public enum HandleSerializer {

  /// The handle's own columns, and nothing nested.
  ///
  /// The reference's `HandleSerializer` can nest `chats` and `messages` behind
  /// `config.includeChats` / `config.includeMessages` (`HandleSerializer.ts:58`-`:73`), and
  /// no v1 route turns either on: `DEFAULT_HANDLE_CONFIG` has both false (`constants.ts`),
  /// `ChatSerializer` and `MessageSerializer` pass them false, and the routers pass no config.
  /// So neither key is on any handle the reference sends, and there is no flag for them
  /// here: the two that existed could only ever emit a placeholder `[]`. The one route that
  /// does attach chats to a handle builds them for real; see `HandleInterface.serialize`.
  public static func serialize(
    _ handle: HandleRow,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    object.set("originalROWID", .int64(handle.rowID))
    // Renamed on the wire: address reads handle.id.
    object.set(HandleWireKey.address, .string(handle.id))
    object.set("service", .string(handle.service))

    if !isForNotification {
      object.setOrNull("uncanonicalizedId", handle.uncanonicalizedID.map(JSONValue.string))
      object.setOrNull("country", handle.country.map(JSONValue.string))
    }

    return object.build()
  }
}

public enum AttachmentSerializer {

  /// The attachment, from its row and what was already read off disk for it.
  ///
  /// - Parameter hasLivePhoto: whether a Live Photo video sits beside the still, from
  ///   `AttachmentMetadataReader.hasLivePhoto(for:)`. No default, on purpose: this field was
  ///   once `false` unconditionally while the server served Live Photos, and a client gates
  ///   its request for the video on it, so every caller has to say where its answer came
  ///   from. The parity diff cannot catch a wrong value here; the key and type are right.
  public static func serialize(
    _ attachment: AttachmentRow,
    config: AttachmentSerializerConfig = .default,
    metadata: AttachmentMetadata? = nil,
    hasLivePhoto: Bool,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    object.set("originalROWID", .int64(attachment.rowID))
    object.set("guid", .string(attachment.guid))
    object.setOrNull("uti", attachment.uti.map(JSONValue.string))
    object.setOrNull("mimeType", attachment.mimeType.map(JSONValue.string))
    object.setOrNull("transferName", attachment.transferName.map(JSONValue.string))
    object.set("totalBytes", .int64(attachment.totalBytes))

    if !isForNotification {
      object.set("transferState", .int(attachment.transferState))
      object.set("isOutgoing", .bool(attachment.isOutgoing))
      object.set("hideAttachment", .bool(attachment.hideAttachment))
      object.set("isSticker", .bool(attachment.isSticker))
      object.setOrNull("originalGuid", attachment.originalGUID.map(JSONValue.string))
      object.set("hasLivePhoto", .bool(hasLivePhoto))
    }

    if config.loadMetadata {
      // Zero rather than null when unknown, which is the reference's `?? 0`.
      object.set("height", .int(metadata?.height ?? 0))
      object.set("width", .int(metadata?.width ?? 0))
      // Three states, and they are not interchangeable:
      //
      //   - an object, for a medium that was read;
      //   - `null`, for one whose file is not on disk: the reference initialises its
      //     `metadata` to null and only replaces it once the file is found;
      //   - ABSENT, for an attachment that is not an image, audio or video: the
      //     reference's `getAttachmentMetadata` returns `undefined` for those and
      //     `JSON.stringify` drops the key.
      //
      // The third is easy to lose and a strict client notices: `metadata: null` on a PDF
      // says "we looked and found nothing", where absent says "this kind has none".
      if let metadata {
        object.set("metadata", metadata.json())
      } else if AttachmentMetadataReader.kind(of: attachment) != nil {
        object.set("metadata", .null)
      }
    }

    return object.build()
  }
}

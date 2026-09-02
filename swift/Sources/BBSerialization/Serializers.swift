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

public struct MessageSerializer: Sendable {

  private let profile: SchemaProfile

  public init(profile: SchemaProfile) {
    self.profile = profile
  }

  public struct Context: Sendable {
    public var handle: HandleRow?
    public var otherHandle: HandleRow?
    public var chats: [ChatRow]
    public var attachments: [AttachmentRow]
    public var participantsByChatGUID: [String: [HandleRow]]

    public init(
      handle: HandleRow? = nil,
      otherHandle: HandleRow? = nil,
      chats: [ChatRow] = [],
      attachments: [AttachmentRow] = [],
      participantsByChatGUID: [String: [HandleRow]] = [:]
    ) {
      self.handle = handle
      self.otherHandle = otherHandle
      self.chats = chats
      self.attachments = attachments
      self.participantsByChatGUID = participantsByChatGUID
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
    object.set("guid", .string(message.guid))
    object.setOrNull("text", message.universalText().map(JSONValue.string))

    // A DECODED STRUCTURE — `[{ string, runs }]` — not base64. Clients index into it.
    //
    // Nulled AFTER conversion rather than skipped, so the Ventura text-extraction path
    // still runs. The key stays present either way.
    object.setOrNull(
      "attributedBody",
      config.parseAttributedBody
        ? message.attributedBody
          .flatMap { try? AttributedBodyDecoder.decode($0) }
          .map { AttributedBodyWire.encode($0, format: config.attributedBodyFormat) }
        : nil
    )

    object.setOrNull(
      "handle",
      context.handle.map { HandleSerializer.serialize($0, isForNotification: isForNotification) }
    )
    object.setOrNull("handleId", message.handleID.map(JSONValue.int64))
    object.setOrNull("otherHandle", message.otherHandle.map(JSONValue.int64))

    object.set(
      "attachments",
      .array(
        context.attachments.map {
          AttachmentSerializer.serialize(
            $0, config: attachmentConfig, isForNotification: isForNotification)
        }))

    object.setOrNull("subject", message.subject.map(JSONValue.string))
    object.set("error", .int(message.error))

    // Epoch milliseconds, or null. Never ISO strings.
    object.setOrNull("dateCreated", message.date?.epochMilliseconds.map(JSONValue.int64))
    object.setOrNull("dateRead", message.dateRead?.epochMilliseconds.map(JSONValue.int64))
    object.setOrNull("dateDelivered", message.dateDelivered?.epochMilliseconds.map(JSONValue.int64))

    object.set("isDelivered", .bool(message.isDelivered))
    object.set("isFromMe", .bool(message.isFromMe))
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
        "chats",
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

    // Both are binary plists, and both go on the wire decoded — same reason as
    // attributedBody above.
    object.setIfOrNull(
      profile.supportsMessageSummaryInfo, "messageSummaryInfo",
      config.parseMessageSummary
        ? PropertyListWire.decode(message.messageSummaryInfo)
        : nil
    )
    object.setIfOrNull(
      profile.supportsPayloadData, "payloadData",
      config.parsePayloadData
        ? PropertyListWire.decode(message.payloadData)
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

    // MARK: The FCM size ceiling
    //
    // Last, because it has to measure the WHOLE response. Weighing `chats` alone measures
    // the wrong thing: a message whose text runs to 3.9 KB has a tiny chats array, so the
    // cap never fires, the payload goes over FCM's 4 KB data limit, and Google rejects the
    // send. The user sees one missing notification and nothing anywhere says why.
    //
    // Node measures `JSON.stringify(messageResponses)` — an ARRAY, because the singular
    // `serialize` delegates to `serializeList` with one element. Hence `+ 2`: two bytes
    // of brackets, which only matters at the boundary and is free to get right.
    guard config.enforceMaxSize, config.includeChats else { return object.build() }

    var built = object.build()
    let size = ((try? built.serialize().count) ?? 0) + 2
    guard size > config.maxSizeBytes else { return built }

    // Participants are the concession, matching the current server exactly: they are the
    // largest droppable field, and a notification without them still routes and renders.
    object.set(
      "chats",
      .array(
        context.chats.map {
          ChatSerializer.serialize(
            $0, participants: [], includeParticipants: false,
            isForNotification: isForNotification
          )
        }))
    built = object.build()
    return built
  }
}

public enum ChatSerializer {

  public static func serialize(
    _ chat: ChatRow,
    participants: [HandleRow] = [],
    includeParticipants: Bool = true,
    includeMessages: Bool = false,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    object.set("originalROWID", .int64(chat.rowID))
    object.set("guid", .string(chat.guid))
    object.set("style", .int(chat.style))
    object.setOrNull("chatIdentifier", chat.chatIdentifier.map(JSONValue.string))
    object.set("isArchived", .bool(chat.isArchived))
    object.setOrNull("displayName", chat.displayName.map(JSONValue.string))

    // The KEY is gated, and its CONTENTS are a separate question — the two get conflated
    // easily and the reference keeps them apart:
    //
    //   - `chat/:guid` and `chat/query` serialize with `DEFAULT_CHAT_CONFIG`, whose
    //     `includeParticipants` is true, so the key is always there. It is `[]` when the
    //     caller did not ask for participants, because the entity was loaded without
    //     them — not because the key was suppressed.
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
    if includeMessages {
      object.set("messages", .array([]))
    }

    if !isForNotification {
      object.set("isFiltered", .bool(chat.isFiltered))
      object.setOrNull("groupId", chat.groupID.map(JSONValue.string))
      object.setOrNull("lastAddressedHandle", chat.lastAddressedHandle.map(JSONValue.string))
      // Decoded, not an empty array. This was hardcoded to `[]`, so
      // `lastSeenMessageGuid`, `shouldForceToSMS` and the rest never reached a client —
      // and the key being present made it look like the chat simply had none.
      object.set("properties", PropertyListWire.decode(chat.properties) ?? .array([]))
    }

    return object.build()
  }
}

public enum HandleSerializer {

  public static func serialize(
    _ handle: HandleRow,
    includeChats: Bool = false,
    includeMessages: Bool = false,
    isForNotification: Bool = false
  ) -> JSONValue {
    var object = JSONObjectBuilder()

    object.set("originalROWID", .int64(handle.rowID))
    // Renamed on the wire: address reads handle.id.
    object.set("address", .string(handle.id))
    object.set("service", .string(handle.service))

    if !isForNotification {
      object.setOrNull("uncanonicalizedId", handle.uncanonicalizedID.map(JSONValue.string))
      object.setOrNull("country", handle.country.map(JSONValue.string))
    }
    if includeChats { object.set("chats", .array([])) }
    if includeMessages { object.set("messages", .array([])) }

    return object.build()
  }
}

public enum AttachmentSerializer {

  public static func serialize(
    _ attachment: AttachmentRow,
    config: AttachmentSerializerConfig = .default,
    messageGUIDs: [String] = [],
    data: Data? = nil,
    dimensions: (height: Int, width: Int)? = nil,
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
      object.set("hasLivePhoto", .bool(false))
    }

    if config.includeMessageGUIDs {
      object.set("messages", .array(messageGUIDs.map(JSONValue.string)))
    }

    if config.loadMetadata {
      // Default to 0 rather than null, matching the current serializer.
      object.set("height", .int(dimensions?.height ?? 0))
      object.set("width", .int(dimensions?.width ?? 0))
      object.set("metadata", .object([:]))
    }

    if config.loadData, let data {
      object.set("data", .string(data.base64EncodedString()))
    }

    return object.build()
  }
}

//  MessageSerializerTests
//  The invariants in `.claude/docs/api.md`, asserted rather than assumed.
//
//  Each of these is a documented compatibility rule whose violation is silent: the server
//  keeps answering 200 and clients quietly mis-render. That is the failure mode worth a test.

import BBCore
import BBSerialization
import Foundation
import Testing

@testable import BBIMessage

/// The columns a Ventura-and-later schema has, which is the current floor's shape.
private let modernColumns: Set<String> = [
  "ROWID", "guid", "text", "attributedBody", "subject", "handle_id", "other_handle",
  "country", "service", "error", "date", "date_read", "date_delivered", "date_played",
  "time_expressive_send_played", "is_delivered", "is_from_me", "is_read", "is_sent",
  "is_empty", "is_delayed", "is_auto_reply", "is_system_message", "is_service_message",
  "is_forward", "is_archive", "is_audio_message", "is_played", "is_corrupt", "is_spam",
  "is_expirable", "has_dd_results", "was_data_detected", "was_deduplicated",
  "cache_has_attachments", "cache_roomnames", "item_type", "group_title",
  "group_action_type", "share_status", "share_direction", "balloon_bundle_id",
  "expressive_send_style_id", "associated_message_guid", "associated_message_type",
  "payload_data", "message_summary_info", "thread_originator_guid",
  "thread_originator_part", "reply_to_guid", "date_edited", "date_retracted", "part_count",
  "was_delivered_quietly", "did_notify_recipient",
]

/// High Sierra: threading and payloads exist, but edit/unsend and quiet delivery do not.
private let highSierraColumns: Set<String> = modernColumns.subtracting([
  "date_edited", "date_retracted", "part_count",
  "was_delivered_quietly", "did_notify_recipient",
])

@Suite("Date representation")
struct DateSerializationTests {

  /// Epoch MILLISECONDS or null. Never an ISO string — a client parsing a number gets a
  /// string and fails, or worse, coerces it to NaN and displays 1970.
  @Test("Dates are epoch milliseconds, never ISO strings")
  func datesAreEpochMilliseconds() {
    // 2023-03-08T00:26:40Z expressed in Apple nanoseconds since 2001-01-01.
    let appleNanoseconds: Int64 = 700_000_000_000_000_000
    let row = Rows.message(Rows.messageColumns(date: appleNanoseconds))
    let output = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())

    guard case .int64(let milliseconds)? = output["dateCreated"] else {
      Issue.record(
        "dateCreated was \(String(describing: output["dateCreated"])), expected an integer")
      return
    }
    // The Apple epoch is 2001-01-01; 700e15 ns past it is in 2023.
    let expected = AppleTimestamp(rawValue: appleNanoseconds, unit: .nanoseconds).epochMilliseconds
    #expect(milliseconds == expected)
    #expect(milliseconds > 1_600_000_000_000)
  }

  /// An unset date column stores 0, which is 2001-01-01 if taken literally. Messages
  /// "read" a quarter-century ago is the visible symptom.
  @Test("An unset date is null, not the Apple epoch")
  func unsetDateIsNull() {
    let row = Rows.message(Rows.messageColumns(dateRead: 0))
    let output = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())
    #expect(output["dateRead"] == .null)
  }
}

@Suite("Wire renames")
struct RenameTests {

  /// Two fields are renamed between the column and the wire, and both are load-bearing.
  @Test("address reads handle.id, and isExpired reads message.is_expirable")
  func renamesAreApplied() {
    let row = Rows.message(Rows.messageColumns(isExpirable: true))
    let output = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init(handle: Rows.handle(id: "+12025550143")))

    #expect(output["handle"]?["address"] == .string("+12025550143"))
    #expect(output["handle"]?.objectKeys.contains("id") == false)
    #expect(output["isExpired"] == .bool(true))
    #expect(output.objectKeys.contains("isExpirable") == false)
  }
}

@Suite("macOS gating")
struct SchemaGatingTests {

  /// A field this macOS lacks is ABSENT, not null. Clients distinguish the two: absent
  /// means "this server cannot tell you", null means "there is no value".
  @Test("Ventura-only fields are absent on High Sierra, not null")
  func venturaFieldsAbsentOnOlderSchema() {
    let row = Rows.message(Rows.messageColumns())

    let modern = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())
    let older = MessageSerializer(profile: .baseline(messageColumns: highSierraColumns))
      .serialize(row, context: .init())

    for field in ["dateEdited", "dateRetracted", "partCount"] {
      #expect(modern.objectKeys.contains(field), "\(field) should be present on a Ventura schema")
      #expect(
        !older.objectKeys.contains(field), "\(field) should be ABSENT on High Sierra, not null")
    }
  }

  @Test("Monterey quiet-delivery fields follow the same rule")
  func quietDeliveryGating() {
    let row = Rows.message(Rows.messageColumns())

    let modern = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())
    let older = MessageSerializer(profile: .baseline(messageColumns: highSierraColumns))
      .serialize(row, context: .init())

    for field in ["wasDeliveredQuietly", "didNotifyRecipient"] {
      #expect(modern.objectKeys.contains(field))
      #expect(!older.objectKeys.contains(field))
    }
  }

  /// The capability queries are named after the feature, not the column, so a schema
  /// change touches one place. They must actually track the columns.
  @Test("Capability queries follow the columns, not the OS version")
  func capabilitiesTrackColumns() {
    let modern = SchemaProfile.baseline(messageColumns: modernColumns)
    #expect(modern.supportsEditedMessages)
    #expect(modern.supportsMessageParts)
    #expect(modern.supportsQuietDelivery)

    let older = SchemaProfile.baseline(messageColumns: highSierraColumns)
    #expect(!older.supportsEditedMessages)
    #expect(!older.supportsMessageParts)
    #expect(!older.supportsQuietDelivery)
    // Threading and payloads predate the floor and are always present.
    #expect(older.supportsThreading)
    #expect(older.supportsPayloadData)
  }

  /// Edit and unsend arrived together; one column without the other is not the feature.
  @Test("Edit support requires BOTH of its columns")
  func editSupportNeedsBothColumns() {
    let halfway = modernColumns.subtracting(["date_retracted"])
    #expect(!SchemaProfile.baseline(messageColumns: halfway).supportsEditedMessages)
  }

  /// One query works across schema generations because absent columns are dropped from
  /// the SELECT list. This is also why `SELECT *` is never used.
  @Test("select drops columns this schema does not have")
  func selectDropsAbsentColumns() {
    let profile = SchemaProfile.baseline(messageColumns: highSierraColumns)
    let sql = profile.select(["ROWID", "guid", "date_edited"], from: .message, alias: "m")

    #expect(sql.contains("\"ROWID\""))
    #expect(sql.contains("\"guid\""))
    #expect(!sql.contains("date_edited"))
    #expect(sql.contains("m."))
  }
}

@Suite("Notification variant")
struct NotificationVariantTests {

  /// FCM and webhooks receive a trimmed payload; the socket receives the full one. The
  /// specific fields dropped are a contract, not an optimisation detail.
  @Test("isForNotification strips exactly the documented fields")
  func notificationStripsFields() {
    let row = Rows.message(Rows.messageColumns())
    let serializer = MessageSerializer(profile: .baseline(messageColumns: modernColumns))

    let full = serializer.serialize(row, context: .init(), isForNotification: false)
    let trimmed = serializer.serialize(row, context: .init(), isForNotification: true)

    let stripped: Set<String> = [
      "country", "isDelayed", "isAutoReply", "isSystemMessage", "isServiceMessage",
      "isForward", "threadOriginatorPart", "isCorrupt", "datePlayed", "cacheRoomnames",
      "isSpam", "isExpired", "timeExpressiveSendPlayed", "isAudioMessage",
      "replyToGuid", "shareStatus", "shareDirection",
      "wasDeliveredQuietly", "didNotifyRecipient",
    ]

    #expect(
      stripped.isSubset(of: full.objectKeys), "the full variant should carry every stripped field")
    #expect(
      stripped.isDisjoint(with: trimmed.objectKeys),
      "the notification variant must carry none of them")
  }

  /// The core identifying fields survive trimming — a notification with no guid is not a
  /// notification.
  @Test("The notification variant keeps what identifies the message")
  func notificationKeepsEssentials() {
    let row = Rows.message(Rows.messageColumns())
    let trimmed = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init(), isForNotification: true)

    for field in ["guid", "originalROWID", "text", "isFromMe", "dateCreated"] {
      #expect(trimmed.objectKeys.contains(field), "\(field) must survive trimming")
    }
  }

  /// Handles and attachments are trimmed too, and by the same rule.
  @Test("Nested handles and attachments are trimmed as well")
  func nestedTrimming() {
    let handle = HandleSerializer.serialize(Rows.handle(), isForNotification: true)
    #expect(handle.objectKeys.contains("address"))
    #expect(!handle.objectKeys.contains("country"))
    #expect(!handle.objectKeys.contains("uncanonicalizedId"))

    let attachment = AttachmentSerializer.serialize(Rows.attachment(), isForNotification: true)
    #expect(attachment.objectKeys.contains("guid"))
    #expect(!attachment.objectKeys.contains("isSticker"))
    #expect(!attachment.objectKeys.contains("transferState"))
  }
}

@Suite("Message text")
struct MessageTextTests {

  /// `message.text` is frequently NULL from Ventura onward; the content is in
  /// attributedBody. A message with neither is null text, not an empty string.
  @Test("Text falls back to attributedBody when the text column is empty")
  func textFallsBackToAttributedBody() {
    let row = Rows.message(
      Rows.messageColumns(
        text: nil, attributedBody: Archive.typedStream("Fell back correctly")
      ))
    let output = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())

    #expect(output["text"] == .string("Fell back correctly"))
  }

  @Test("A message with neither text nor attributedBody serializes text as null")
  func noTextIsNull() {
    let row = Rows.message(Rows.messageColumns(text: nil, attributedBody: nil))
    let output = MessageSerializer(profile: .baseline(messageColumns: modernColumns))
      .serialize(row, context: .init())
    #expect(output["text"] == .null)
  }

  /// attributedBody reaches clients DECODED, not as base64 — they index into it. Emitting
  /// base64 here, which the first pass of this port did, breaks every client that reads it.
  @Test("attributedBody is a decoded structure, and null when not requested")
  func attributedBodyEncoding() {
    let row = Rows.message(
      Rows.messageColumns(
        attributedBody: Archive.typedStream("Structured, not base64")
      ))
    let serializer = MessageSerializer(profile: .baseline(messageColumns: modernColumns))

    let parsed = serializer.serialize(row, context: .init(), config: .full)
    guard case .array(let elements)? = parsed["attributedBody"], let first = elements.first
    else {
      Issue.record("attributedBody should be an array of decoded strings")
      return
    }
    #expect(first["string"] == .string("Structured, not base64"))
    #expect(first.objectKeys.contains("runs"))

    // The key stays PRESENT and null — the Ventura text-extraction path still runs.
    let unparsed = serializer.serialize(row, context: .init(), config: .notification)
    #expect(unparsed["attributedBody"] == .null)
  }
}

@Suite("Reaction targets")
struct ReactionTargetTests {

  /// `associated_message_guid` carries a prefix encoding which part it targets. Dropping
  /// the prefix attaches every reaction to the whole message.
  @Test("The associated-message prefix decodes to a part index")
  func prefixDecoding() {
    func target(_ raw: String?) -> (guid: String, partIndex: Int)? {
      Rows.message(
        Rows.messageColumns().merging(["associated_message_guid": raw]) { _, new in new }
      ).associatedMessageTarget
    }

    #expect(target("p:0/ABC")?.guid == "ABC")
    #expect(target("p:0/ABC")?.partIndex == 0)
    #expect(target("p:2/ABC")?.partIndex == 2)
    #expect(target("bp:ABC")?.guid == "ABC")
    #expect(target("bp:ABC")?.partIndex == 0)
    #expect(target("ABC")?.guid == "ABC")
    #expect(target("ABC")?.partIndex == 0)
    #expect(target(nil) == nil)
    #expect(target("") == nil)
  }
}

@Suite("Chat serialization")
struct ChatSerializationTests {

  /// 43 is a group, 45 a direct message, and the serializers branch on it.
  @Test("Style distinguishes a group from a direct message")
  func styleDistinguishesGroups() {
    #expect(Rows.chat(style: 43).isGroup)
    #expect(!Rows.chat(style: 45).isGroup)
  }

  @Test("Participants are included only when asked for")
  func participantsAreConditional() {
    let with = ChatSerializer.serialize(
      Rows.chat(), participants: [Rows.handle()], includeParticipants: true
    )
    #expect(with["participants"] != nil)

    let without = ChatSerializer.serialize(
      Rows.chat(), participants: [Rows.handle()], includeParticipants: false
    )
    #expect(!without.objectKeys.contains("participants"))
  }
}

//  RowBuilders
//  Constructs chat.db rows for the serializer tests.
//
//  Rows are built from a GRDB `Row` rather than a memberwise initializer, deliberately. The
//  row initializers reach for columns through `hasColumn`, and "this schema does not have
//  that column" is the exact distinction the wire format is required to preserve — an absent
//  column must produce an ABSENT key, not a null one. Building rows any other way would test
//  the serializer while stubbing out the thing that makes it hard.
//
//  So: to test a pre-Ventura schema, omit `date_edited` from the dictionary. That is what a
//  pre-Ventura database actually looks like to this code.

import BBCore
import BBSerialization
import Foundation
import GRDB

@testable import BBIMessage

enum Rows {

  /// Columns every supported schema has. Individual tests layer version-gated columns on
  /// top, which is how a schema generation gets expressed here.
  static func messageColumns(
    rowID: Int64 = 1,
    guid: String = "A1B2C3D4-0000-0000-0000-000000000001",
    text: String? = "Hello",
    attributedBody: Data? = nil,
    handleID: Int64? = 7,
    date: Int64? = 700_000_000_000_000_000,
    dateRead: Int64? = 0,
    isFromMe: Bool = false,
    isExpirable: Bool = false
  ) -> [String: (any DatabaseValueConvertible)?] {
    [
      "ROWID": rowID,
      "guid": guid,
      "text": text,
      "attributedBody": attributedBody,
      "subject": nil as String?,
      "handle_id": handleID,
      "other_handle": nil as Int64?,
      "country": "us",
      "service": "iMessage",
      "error": 0,
      "date": date,
      "date_read": dateRead,
      "date_delivered": 0,
      "date_played": 0,
      "time_expressive_send_played": 0,
      "is_delivered": 1,
      "is_from_me": isFromMe ? 1 : 0,
      "is_read": 0,
      "is_sent": 0,
      "is_empty": 0,
      "is_delayed": 0,
      "is_auto_reply": 0,
      "is_system_message": 0,
      "is_service_message": 0,
      "is_forward": 0,
      "is_archive": 0,
      "is_audio_message": 0,
      "is_played": 0,
      "is_corrupt": 0,
      "is_spam": 0,
      // The wire name for this column is `isExpired`; the column is `is_expirable`.
      "is_expirable": isExpirable ? 1 : 0,
      "has_dd_results": 0,
      "was_data_detected": 0,
      "was_deduplicated": 0,
      "cache_has_attachments": 0,
      "cache_roomnames": nil as String?,
      "item_type": 0,
      "group_title": nil as String?,
      "group_action_type": 0,
      "share_status": nil as Int?,
      "share_direction": nil as Int?,
      "balloon_bundle_id": nil as String?,
      "expressive_send_style_id": nil as String?,
      "associated_message_guid": nil as String?,
      "associated_message_type": 0,
      "payload_data": nil as Data?,
    ]
  }

  static func message(
    _ columns: [String: (any DatabaseValueConvertible)?],
    dateUnit: AppleTimestamp.Unit = .nanoseconds
  ) -> IMessageRow {
    IMessageRow(row: Row(columns), dateUnit: dateUnit)
  }

  static func handle(
    rowID: Int64 = 7,
    id: String = "+12025550143",
    service: String = "iMessage",
    country: String? = "us",
    uncanonicalizedID: String? = "2025550143"
  ) -> HandleRow {
    HandleRow(
      row: Row([
        "ROWID": rowID,
        "id": id,
        "service": service,
        "country": country,
        "uncanonicalized_id": uncanonicalizedID,
        "person_centric_id": nil as String?,
      ]))
  }

  static func chat(
    rowID: Int64 = 3,
    guid: String = "iMessage;-;+12025550143",
    style: Int = 45,
    displayName: String? = nil
  ) -> ChatRow {
    ChatRow(
      row: Row([
        "ROWID": rowID,
        "guid": guid,
        "style": style,
        "chat_identifier": "+12025550143",
        "service_name": "iMessage",
        "display_name": displayName,
        "room_name": nil as String?,
        "is_archived": 0,
        "is_filtered": 0,
        "group_id": nil as String?,
        "last_addressed_handle": nil as String?,
      ]))
  }

  static func attachment(
    rowID: Int64 = 11,
    guid: String = "at_0_ABCD",
    mimeType: String? = "image/png",
    totalBytes: Int64 = 2048
  ) -> AttachmentRow {
    AttachmentRow(
      row: Row([
        "ROWID": rowID,
        "guid": guid,
        "filename": "~/Library/Messages/Attachments/a.png",
        "uti": "public.png",
        "mime_type": mimeType,
        "transfer_name": "a.png",
        "total_bytes": totalBytes,
        "transfer_state": 5,
        "is_outgoing": 0,
        "is_sticker": 0,
        "hide_attachment": 0,
        "original_guid": nil as String?,
        "created_date": 0,
      ]),
      dateUnit: .nanoseconds
    )
  }
}

// MARK: - Schema generations

extension SchemaProfile {

  /// A schema with only the columns common to every supported release.
  static func baseline(messageColumns: Set<String>) -> SchemaProfile {
    SchemaProfile(
      tables: ["message", "chat", "handle", "attachment"],
      messageColumns: messageColumns,
      chatColumns: ["ROWID", "guid", "style"],
      handleColumns: ["ROWID", "id", "service"],
      attachmentColumns: ["ROWID", "guid"],
      dateUnit: .nanoseconds
    )
  }
}

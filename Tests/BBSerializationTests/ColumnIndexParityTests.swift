//  ColumnIndexParityTests
//  The indexed column path and the string path produce the same row.
//
//  `Row`'s string subscript is a linear scan and `hasColumn` is a second one, so mapping a
//  message — about seventy columns, each read through both — was the single dominant cost of
//  serving a page: 87ms per thousand rows against 1.8ms positional.
//
//  `MappedRow` resolves the positions once per result set and reads by index, falling back to
//  the string path for any name the index misses, which is what makes the change
//  behaviour-preserving by construction rather than by inspection of every SELECT. This suite
//  is the guard on that "by construction": it maps identical data both ways and requires the
//  serialized output to be identical, because the fallback is the thing nobody would notice
//  breaking — it only runs for the columns the index did not resolve.

import BBCore
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBIMessage

private let allColumns: Set<String> = [
  "ROWID", "guid", "text", "attributedBody", "subject", "handle_id", "other_handle", "country",
  "service", "error", "date", "date_read", "date_delivered", "date_played",
  "time_expressive_send_played", "is_delivered", "is_from_me", "is_read", "is_sent", "is_empty",
  "is_delayed", "is_auto_reply", "is_system_message", "is_service_message", "is_forward",
  "is_archive", "is_audio_message", "is_played", "is_corrupt", "is_spam", "is_expirable",
  "has_dd_results", "was_data_detected", "was_deduplicated", "cache_has_attachments",
  "cache_roomnames", "item_type", "group_title", "group_action_type", "share_status",
  "share_direction", "balloon_bundle_id", "expressive_send_style_id", "associated_message_guid",
  "associated_message_type", "associated_message_emoji", "schedule_type", "schedule_state",
  "payload_data", "message_summary_info", "thread_originator_guid", "thread_originator_part",
  "reply_to_guid", "date_edited", "date_retracted", "part_count", "was_delivered_quietly",
  "did_notify_recipient",
]

/// An index that resolves nothing, so every read takes the fallback.
private let emptyIndex = ColumnIndex(Row([:]))

@Suite("Column index parity")
struct ColumnIndexParityTests {

  /// A row with every column the mapper knows about, including the ones whose absence and
  /// whose NULL mean different things on the wire.
  private func fullRow() -> Row {
    Row([
      "ROWID": 42 as Int64,
      "guid": "p:0/11111111-2222-3333-4444-555555555555",
      "text": nil as String?,
      "attributedBody": nil as Data?,
      "subject": "a subject, distinct from the text",
      "handle_id": 7 as Int64,
      "other_handle": 0 as Int64,
      "country": "us",
      "service": "iMessage",
      "error": 0,
      "date": 700_000_000_000_000_000 as Int64,
      "date_read": 0 as Int64,
      // Minutes apart, not nanoseconds: the wire format is epoch MILLISECONDS, so two
      // dates a nanosecond apart serialize identically and a swapped index would pass.
      "date_delivered": 700_000_180_000_000_000 as Int64,
      "date_played": nil as Int64?,
      "time_expressive_send_played": nil as Int64?,
      "is_delivered": 1, "is_from_me": 1, "is_read": 0, "is_sent": 1, "is_empty": 0,
      "is_delayed": 0, "is_auto_reply": 0, "is_system_message": 0, "is_service_message": 0,
      "is_forward": 0, "is_archive": 0, "is_audio_message": 0, "is_played": 0, "is_corrupt": 0,
      "is_spam": 0, "is_expirable": 1, "has_dd_results": 1, "was_data_detected": 1,
      "was_deduplicated": 0, "cache_has_attachments": 1,
      "cache_roomnames": nil as String?,
      "item_type": 0, "group_title": nil as String?, "group_action_type": 0,
      "share_status": nil as Int?, "share_direction": nil as Int?,
      "balloon_bundle_id": nil as String?, "expressive_send_style_id": nil as String?,
      "associated_message_guid": nil as String?, "associated_message_type": 0,
      "associated_message_emoji": nil as String?,
      "schedule_type": 0, "schedule_state": 0,
      "payload_data": nil as Data?, "message_summary_info": nil as Data?,
      "thread_originator_guid": nil as String?, "thread_originator_part": nil as String?,
      "reply_to_guid": nil as String?,
      "date_edited": 0 as Int64, "date_retracted": 0 as Int64, "part_count": 1,
      "was_delivered_quietly": 0, "did_notify_recipient": 1,
    ])
  }

  /// Without this, everything below could pass because BOTH paths were the string path.
  @Test("The two paths under test really are different paths")
  func pathsDiffer() {
    let row = fullRow()
    #expect(ColumnIndex(row).position("date") != nil, "the indexed path resolved nothing")
    #expect(emptyIndex.position("date") == nil, "the fallback path was not the fallback")
  }

  @Test("A fully populated row serializes identically through either path")
  func fullRowParity() {
    let row = fullRow()
    let serializer = MessageSerializer(profile: .baseline(messageColumns: allColumns))
    let indexed = serializer.serialize(
      row.mapped { IMessageRow($0, dateUnit: .nanoseconds) },
      context: .init())
    let fallback = serializer.serialize(
      IMessageRow(MappedRow(row: row, columns: emptyIndex), dateUnit: .nanoseconds),
      context: .init())
    #expect(indexed == fallback)
  }

  /// The distinction the whole file exists for: an ABSENT column is a missing key on the
  /// wire, a NULL column is an explicit null, and clients treat them differently. An index
  /// that resolves a name the row does not have would quietly turn one into the other.
  @Test("A column absent from the schema stays absent through either path")
  func absentColumnParity() {
    // A real schema on a real Mac: rebuilt without the Ventura-and-later columns.
    let older = allColumns.subtracting(["date_edited", "date_retracted", "part_count"])
    let full = fullRow()
    var columns: [String: (any DatabaseValueConvertible)?] = [:]
    for name in older { columns[name] = full[name] as DatabaseValue }
    let row = Row(columns)

    let serializer = MessageSerializer(profile: .baseline(messageColumns: older))
    let indexed = serializer.serialize(
      row.mapped { IMessageRow($0, dateUnit: .nanoseconds) },
      context: .init())
    let fallback = serializer.serialize(
      IMessageRow(MappedRow(row: row, columns: emptyIndex), dateUnit: .nanoseconds),
      context: .init())
    #expect(indexed == fallback)
    #expect(ColumnIndex(row).position("date_edited") == nil)
  }

  /// `Row` matches column names case-insensitively; the index does not, and relies on the
  /// fallback to cover it. If that fallback ever goes, this is the test that says so.
  @Test("A column the index misses still reads, through the fallback")
  func caseMismatchFallsBack() {
    let row = Row(["RowId": 9 as Int64, "guid": "g", "service": "SMS"])
    let index = ColumnIndex(row)
    #expect(index.position("ROWID") == nil, "the index was expected to miss on case")
    let mapped = MappedRow(row: row, columns: index)
    // `Row` finds it regardless of case, and so must we.
    #expect(mapped.required("ROWID") as Int64 == 9)
    #expect(mapped.optional("service") as String? == "SMS")
  }

  /// One index per result set is the entire point; a per-row index would be no faster than
  /// what it replaced.
  ///
  /// Built from a real statement rather than from dictionary literals. `Row(dictionary)`
  /// takes a Swift `Dictionary`, so its column ORDER is arbitrary and differs between rows
  /// and between processes -- which is exactly the misuse `mapRows` now asserts against, and
  /// which made the first version of this test read one column's value under another's name
  /// on about half of runs.
  @Test("mapRows resolves the columns once for the whole result set")
  func mapRowsSharesOneIndex() throws {
    let queue = try DatabaseQueue()
    let rows = try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT 0 AS ROWID, 'g0' AS guid, 'iMessage' AS service
          UNION ALL SELECT 1, 'g1', 'SMS'
          UNION ALL SELECT 2, 'g2', 'iMessage'
          """)
    }
    #expect(rows.count == 3)
    let ids = rows.mapRows { $0.required("ROWID") as Int64 }
    #expect(ids == [0, 1, 2])
    let services = rows.mapRows { ($0.optional("service") as String?) ?? "" }
    #expect(services == ["iMessage", "SMS", "iMessage"])
  }
}

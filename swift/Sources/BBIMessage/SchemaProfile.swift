//  SchemaProfile
//  What exists in THIS machine's chat.db.
//
//  Apple owns this schema and changes it per release, in both directions. Verified against
//  the dumps in macos/database/samples:
//
//    Sonoma adds 6 message columns  (is_critical, is_kt_verified, is_sos, is_stewie,
//                                    bia_reference_id, fallback_hash)
//    Sequoia adds 6 more            (schedule_state, schedule_type, associated_message_emoji,
//                                    needs_relay, is_pending_satellite_send,
//                                    sent_or_received_off_grid)
//    Sequoia REMOVES message_processing_task, which Sonoma has.
//
//  So a profile cannot be a version number alone, and `SELECT *` is out: a column that
//  vanished takes the query with it. Columns are introspected at runtime and every query
//  names what it wants.
//
//  This also drives the serializer contract: a field absent from the schema must be ABSENT
//  from the JSON, not null. Clients distinguish the two.
//
//  See `.claude/docs/database.md`.

import BBCore
import BBPersistence
import Foundation
import Logging

public struct SchemaProfile: Sendable {

  public let tables: Set<String>
  public let messageColumns: Set<String>
  public let chatColumns: Set<String>
  public let handleColumns: Set<String>
  public let attachmentColumns: Set<String>

  /// Which scale the date columns use. High Sierra switched chat.db from seconds to
  /// nanoseconds; getting this wrong yields dates that look plausible and are decades off.
  public let dateUnit: AppleTimestamp.Unit

  private let logger = Logger(label: "bluebubbles.schema")

  public init(
    tables: Set<String>,
    messageColumns: Set<String>,
    chatColumns: Set<String>,
    handleColumns: Set<String>,
    attachmentColumns: Set<String>,
    dateUnit: AppleTimestamp.Unit
  ) {
    self.tables = tables
    self.messageColumns = messageColumns
    self.chatColumns = chatColumns
    self.handleColumns = handleColumns
    self.attachmentColumns = attachmentColumns
    self.dateUnit = dateUnit
  }

  /// Introspects the live database.
  ///
  /// Deliberately not derived from the OS version: a restored or migrated database can
  /// disagree with the running system, and the schema is the authority on itself.
  public static func detect(
    in database: ReadOnlyDatabase,
    osMajorVersion: Int
  ) async throws -> SchemaProfile {
    let tables = try await database.tables()
    guard tables.contains("message"), tables.contains("chat") else {
      throw ReadOnlyDatabaseError.tableMissing("message/chat")
    }

    return SchemaProfile(
      tables: tables,
      messageColumns: try await database.columns(of: "message"),
      chatColumns: try await database.columns(of: "chat"),
      handleColumns: try await database.columns(of: "handle"),
      attachmentColumns: try await database.columns(of: "attachment"),
      // High Sierra is 10.13; macOS 11+ reports its major directly.
      dateUnit: osMajorVersion >= 11 ? .nanoseconds : .seconds
    )
  }

  // MARK: - Capability queries
  //
  // Named after the FEATURE rather than the column, so call sites read as intent and one
  // schema change touches one place.

  /// Ventura introduced edit and unsend.
  public var supportsEditedMessages: Bool {
    messageColumns.contains("date_edited") && messageColumns.contains("date_retracted")
  }

  /// Ventura: a message can have multiple parts, and reactions target one.
  public var supportsMessageParts: Bool { messageColumns.contains("part_count") }

  /// Monterey: Focus-aware delivery.
  public var supportsQuietDelivery: Bool {
    messageColumns.contains("was_delivered_quietly")
      && messageColumns.contains("did_notify_recipient")
  }

  /// High Sierra: threading and richer payloads.
  public var supportsThreading: Bool { messageColumns.contains("thread_originator_guid") }
  public var supportsPayloadData: Bool { messageColumns.contains("payload_data") }
  public var supportsMessageSummaryInfo: Bool { messageColumns.contains("message_summary_info") }

  /// Ventura soft-deletes rather than removing rows, so absence from a query is not
  /// deletion.
  public var supportsSoftDeletes: Bool { tables.contains("deleted_messages") }

  /// Sequoia moved scheduled messages into chat.db.
  public var supportsScheduledMessages: Bool { messageColumns.contains("schedule_state") }

  public var supportsReadReceiptTimestamps: Bool {
    chatColumns.contains("last_read_message_timestamp")
  }

  // MARK: - Column selection

  /// Builds a SELECT list from the requested columns, keeping only those present.
  ///
  /// This is the mechanism that makes one query work across three schema versions, and
  /// the reason we never write `SELECT *`.
  public func select(
    _ requested: [String],
    from table: SchemaTable,
    alias: String? = nil
  ) -> String {
    let available = columns(for: table)
    let prefix = alias.map { "\($0)." } ?? ""
    let usable = requested.filter { available.contains($0) }
    if usable.count != requested.count {
      let missing = Set(requested).subtracting(available).sorted()
      logger.debug(
        "Columns absent from this schema",
        metadata: [
          "table": .string(table.rawValue),
          "missing": .string(missing.joined(separator: ", ")),
        ])
    }
    return usable.map { "\(prefix)\"\($0)\"" }.joined(separator: ", ")
  }

  public func has(_ column: String, on table: SchemaTable) -> Bool {
    columns(for: table).contains(column)
  }

  private func columns(for table: SchemaTable) -> Set<String> {
    switch table {
    case .message: messageColumns
    case .chat: chatColumns
    case .handle: handleColumns
    case .attachment: attachmentColumns
    }
  }
}

public enum SchemaTable: String, Sendable {
  case message, chat, handle, attachment
}

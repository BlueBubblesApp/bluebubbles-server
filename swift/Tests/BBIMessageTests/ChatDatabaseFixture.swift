//  ChatDatabaseFixture
//  A real SQLite chat.db, built from scratch, for testing the read path.
//
//  Everything here is synthetic. No address, phone number, GUID or message body comes from
//  anyone's real database — phone numbers use the reserved 555-01xx range (NANP) and email
//  addresses use example.com (RFC 2606), both of which are guaranteed never to belong to a
//  real person. See CONTRIBUTING.md on test data.
//
//  Built as a genuine SQLite file rather than mocked, because what is being tested IS the
//  SQL: the shared predicate, the last-message join, the GUID candidate matching. A mock
//  repository would assert that the code calls itself.

import BBIMessage
import BBPersistence
import Foundation
import GRDB

struct ChatDatabaseFixture {

  let path: String
  let database: ReadOnlyDatabase
  let profile: SchemaProfile
  var repository: MessageRepository { MessageRepository(database: database, profile: profile) }

  /// Apple's epoch: 2001-01-01. chat.db stores nanoseconds since then on High Sierra and
  /// later, which is the schema this fixture declares.
  static let appleEpoch = Date(timeIntervalSince1970: 978_307_200)

  static func nanoseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince(appleEpoch) * 1_000_000_000)
  }

  init(macOS26GUIDs: Bool = false) async throws {
    path =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-chat-\(UUID().uuidString).db").path

    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
      try Self.createSchema(db)
      try Self.seed(db, macOS26GUIDs: macOS26GUIDs)
    }
    // Closed before reopening read-only. GRDB holds the file open otherwise, and the
    // read-only connection would see a database another handle is still writing.
    try queue.close()

    database = try ReadOnlyDatabase(path: path)
    // 14 (Sonoma) so the profile uses nanosecond dates, which is what the seed writes.
    // Detection reads the schema, so the version only picks the date unit.
    profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
  }

  func tearDown() {
    try? FileManager.default.removeItem(atPath: path)
  }

  // MARK: - Mutation
  //
  // The change detector is the one thing here that cannot be tested against a static
  // fixture: what it detects is the DIFFERENCE between two reads, so the file has to move
  // underneath it. A second, writable connection to the same file is how a real chat.db
  // behaves — Messages.app writes while we read.

  /// Inserts a message and returns its GUID.
  @discardableResult
  func insertMessage(
    guid: String,
    text: String = "hello",
    at date: Date,
    handle: Int = 1,
    fromMe: Bool = false,
    chat: Int = 1
  ) async throws -> String {
    let stamp = Self.nanoseconds(date)
    try await write { db in
      try db.execute(
        sql: MessageInsert.sql,
        arguments: [guid, text, handle, fromMe ? 1 : 0, stamp, fromMe ? 1 : 0]
      )
      let rowID = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO chat_message_join VALUES (?, ?, ?)",
        arguments: [chat, rowID, stamp]
      )
    }
    return guid
  }

  /// Stamps a read receipt — the update the reconcile pass exists to catch.
  func markRead(guid: String, at date: Date) async throws {
    let stamp = Self.nanoseconds(date)
    try await write { db in
      try db.execute(
        sql: "UPDATE message SET date_read = ?, is_read = 1 WHERE guid = ?",
        arguments: [stamp, guid]
      )
    }
  }

  private func write(_ body: @escaping @Sendable (Database) throws -> Void) async throws {
    let queue = try DatabaseQueue(path: path)
    defer { try? queue.close() }
    try await queue.write { db in try body(db) }
  }

  enum MessageInsert {
    /// Columns only — every other column carries its schema default. Listing the whole
    /// table here would break the moment `createSchema` gained a column, and the
    /// detector reads none of them.
    static let sql = """
      INSERT INTO message
          (guid, text, handle_id, is_from_me, date, date_read, date_delivered,
           date_played, is_read, is_delivered, error, item_type,
           associated_message_type, service, did_notify_recipient)
      VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, ?, 0, 0, 0, 'iMessage', 0)
      """
  }

  // MARK: - Schema
  //
  // A subset of the real chat.db schema: every column the repository selects, and nothing
  // else. Column names and types match Apple's exactly, because `SchemaProfile.select`
  // filters on presence and a renamed column here would silently drop from every query.

  /// Not private: `ReadConcurrencyBenchmark` builds a much larger database from the same
  /// schema, and two copies of Apple's column list would drift.
  static func createSchema(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL,
            country TEXT,
            service TEXT NOT NULL,
            uncanonicalized_id TEXT,
            person_centric_id TEXT
        );
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT NOT NULL UNIQUE,
            style INTEGER,
            state INTEGER,
            account_id TEXT,
            chat_identifier TEXT,
            service_name TEXT,
            room_name TEXT,
            display_name TEXT,
            group_id TEXT,
            is_archived INTEGER DEFAULT 0,
            last_addressed_handle TEXT,
            is_filtered INTEGER DEFAULT 0
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT NOT NULL UNIQUE,
            text TEXT,
            handle_id INTEGER DEFAULT 0,
            subject TEXT,
            country TEXT,
            attributedBody BLOB,
            service TEXT,
            date INTEGER,
            date_read INTEGER,
            date_delivered INTEGER,
            is_delivered INTEGER DEFAULT 0,
            is_from_me INTEGER DEFAULT 0,
            is_read INTEGER DEFAULT 0,
            is_archive INTEGER DEFAULT 0,
            is_spam INTEGER DEFAULT 0,
            is_audio_message INTEGER DEFAULT 0,
            is_delayed INTEGER DEFAULT 0,
            is_auto_reply INTEGER DEFAULT 0,
            is_system_message INTEGER DEFAULT 0,
            is_service_message INTEGER DEFAULT 0,
            is_forward INTEGER DEFAULT 0,
            is_corrupt INTEGER DEFAULT 0,
            is_expirable INTEGER DEFAULT 0,
            is_empty INTEGER DEFAULT 0,
            cache_has_attachments INTEGER DEFAULT 0,
            cache_roomnames TEXT,
            item_type INTEGER DEFAULT 0,
            other_handle INTEGER DEFAULT 0,
            group_title TEXT,
            group_action_type INTEGER DEFAULT 0,
            share_status INTEGER,
            share_direction INTEGER,
            balloon_bundle_id TEXT,
            payload_data BLOB,
            expressive_send_style_id TEXT,
            associated_message_guid TEXT,
            associated_message_type INTEGER DEFAULT 0,
            message_summary_info BLOB,
            thread_originator_guid TEXT,
            thread_originator_part TEXT,
            date_played INTEGER,
            time_expressive_send_played INTEGER,
            error INTEGER DEFAULT 0,
            has_dd_results INTEGER DEFAULT 0,
            reply_to_guid TEXT,
            was_delivered_quietly INTEGER DEFAULT 0,
            did_notify_recipient INTEGER DEFAULT 0,
            date_edited INTEGER,
            date_retracted INTEGER,
            part_count INTEGER
        );
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            guid TEXT NOT NULL UNIQUE,
            created_date INTEGER,
            filename TEXT,
            uti TEXT,
            mime_type TEXT,
            transfer_state INTEGER DEFAULT 0,
            is_outgoing INTEGER DEFAULT 0,
            transfer_name TEXT,
            total_bytes INTEGER DEFAULT 0,
            is_sticker INTEGER DEFAULT 0,
            hide_attachment INTEGER DEFAULT 0,
            original_guid TEXT
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER, message_id INTEGER, message_date INTEGER,
            PRIMARY KEY (chat_id, message_id)
        );
        CREATE TABLE chat_handle_join (
            chat_id INTEGER, handle_id INTEGER,
            PRIMARY KEY (chat_id, handle_id)
        );
        CREATE TABLE message_attachment_join (
            message_id INTEGER, attachment_id INTEGER
        );
        """)
  }

  // MARK: - Seed data
  //
  // Deliberately small and fully enumerable, so every expected count below can be checked
  // by reading this function rather than by running the code under test.

  /// alice and bob are in `groupChat`; alice is also in `directChat`. `emptyChat` has no
  /// messages at all, which is the case the last-message join has to not drop.
  static let aliceAddress = "+15555550101"
  static let bobAddress = "user@example.com"
  static let carolAddress = "+15555550102"

  static func chatGUID(_ identifier: String, service: String, macOS26: Bool) -> String {
    "\(macOS26 ? "any" : service);-;\(identifier)"
  }

  private static func seed(_ db: Database, macOS26GUIDs: Bool) throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    for (address, service) in [
      (aliceAddress, "iMessage"), (bobAddress, "iMessage"), (carolAddress, "SMS"),
      // Handle 4 exists only to give the message-less chat a participant, so adding
      // that chat cannot perturb what any other handle's chat list contains.
      ("empty@example.com", "iMessage"),
    ] {
      try db.execute(
        sql: "INSERT INTO handle (id, service, country) VALUES (?, ?, ?)",
        arguments: [address, service, "us"]
      )
    }

    // style 45 is one-to-one, 43 is a group.
    try db.execute(
      sql: """
        INSERT INTO chat (guid, style, chat_identifier, display_name, is_archived, service_name)
        VALUES (?, 45, ?, NULL, 0, 'iMessage')
        """,
      arguments: [chatGUID(aliceAddress, service: "iMessage", macOS26: macOS26GUIDs), aliceAddress])
    try db.execute(
      sql: """
        INSERT INTO chat (guid, style, chat_identifier, display_name, is_archived, service_name)
        VALUES (?, 43, 'chat900001', 'Team', 0, 'iMessage')
        """, arguments: [chatGUID("chat900001", service: "iMessage", macOS26: macOS26GUIDs)])
    // Archived, so `includeArchived: false` has something to exclude.
    try db.execute(
      sql: """
        INSERT INTO chat (guid, style, chat_identifier, display_name, is_archived, service_name)
        VALUES (?, 45, ?, NULL, 1, 'SMS')
        """,
      arguments: [chatGUID(carolAddress, service: "SMS", macOS26: macOS26GUIDs), carolAddress])
    // Chat 4 — a participant, no messages. The "new conversation" case, which the
    // last-message sort must NOT drop.
    try db.execute(
      sql: """
        INSERT INTO chat (guid, style, chat_identifier, display_name, is_archived, service_name)
        VALUES ('iMessage;-;empty@example.com', 45, 'empty@example.com', NULL, 0, 'iMessage')
        """)
    // Chat 5 — NO participants. Excluded everywhere: there is nobody to send to, so it is
    // not a conversation a client can act on.
    //
    // Deliberately separate from chat 4. One row carrying both properties makes "no
    // messages" and "no participants" indistinguishable, and the test that guards the
    // empty-chat sort then passes for the wrong reason once the participant rule applies.
    try db.execute(
      sql: """
        INSERT INTO chat (guid, style, chat_identifier, display_name, is_archived, service_name)
        VALUES ('iMessage;+;orphan', 43, 'orphan', NULL, 0, 'iMessage')
        """)

    try db.execute(sql: "INSERT INTO chat_handle_join VALUES (1, 1)")
    try db.execute(sql: "INSERT INTO chat_handle_join VALUES (2, 1), (2, 2)")
    try db.execute(sql: "INSERT INTO chat_handle_join VALUES (3, 3)")
    try db.execute(sql: "INSERT INTO chat_handle_join VALUES (4, 4)")

    // Chat 1 (alice, direct): 3 messages, one of them from me.
    // Chat 2 (group):         2 messages, both from me.
    // Chat 3 (carol):         1 message, incoming.
    // Total: 6 messages, 3 from me.
    let messages:
      [(guid: String, text: String, handle: Int, fromMe: Int, chat: Int, offset: Double)] = [
        ("MSG-0001", "first", 1, 0, 1, 0),
        ("MSG-0002", "second", 1, 1, 1, 60),
        ("MSG-0003", "third", 1, 0, 1, 120),
        ("MSG-0004", "group one", 2, 1, 2, 30),
        ("MSG-0005", "group two", 1, 1, 2, 300),
        ("MSG-0006", "sms", 3, 0, 3, 90),
      ]
    for message in messages {
      let date = base.addingTimeInterval(message.offset)
      try db.execute(
        sql: """
          INSERT INTO message
              (guid, text, handle_id, is_from_me, date, date_delivered, date_read, service, error)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'iMessage', 0)
          """,
        arguments: [
          message.guid, message.text, message.handle, message.fromMe,
          nanoseconds(date),
          // Delivered a minute later; read only for the two oldest, so the
          // updated-count window has a boundary to land inside.
          nanoseconds(date.addingTimeInterval(60)),
          message.offset <= 60 ? nanoseconds(date.addingTimeInterval(120)) : 0,
        ])
      try db.execute(
        sql:
          "INSERT INTO chat_message_join VALUES (?, (SELECT ROWID FROM message WHERE guid = ?), 0)",
        arguments: [message.chat, message.guid]
      )
    }

    // One attachment, on MSG-0003.
    try db.execute(
      sql: """
        INSERT INTO attachment (guid, filename, uti, mime_type, transfer_name, total_bytes)
        VALUES ('ATT-0001', '~/Library/Messages/Attachments/photo.jpg',
                'public.jpeg', 'image/jpeg', 'photo.jpg', 2048)
        """)
    try db.execute(
      sql: """
        INSERT INTO message_attachment_join
        VALUES ((SELECT ROWID FROM message WHERE guid = 'MSG-0003'), 1)
        """)
  }
}

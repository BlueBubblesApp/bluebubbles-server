//  InterfaceFixtures
//  The minimum an interface needs to exist, for tests about what it does when Messages fails.
//
//  `MessageInterface` and `ChatInterface` both require a repository and a serializer, and
//  neither is reached by the paths these suites drive; every one of them fails at the
//  backend, before a row is read. So the database here is EMPTY rather than a schema fixture:
//  `IMessageTests` owns the real ones, and copying one over to satisfy a parameter nothing
//  reads would be a second corpus to keep current.

import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import GRDB

public enum InterfaceFixtures {

  /// An empty, readable database at a fresh temporary path.
  ///
  /// Materialised writable first and then reopened: GRDB cannot open a file that does not
  /// exist read-only, and `ReadOnlyDatabase`, correctly, offers no way to create one.
  public static func emptyDatabase() throws -> ReadOnlyDatabase {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("interface-fixture-\(UUID().uuidString).sqlite").path
    _ = try DatabaseQueue(path: path)
    return try ReadOnlyDatabase(path: path)
  }

  /// A profile that claims no tables and no columns.
  ///
  /// Honest for an empty database, and safe because nothing under test reads through it.
  public static let emptyProfile = SchemaProfile(
    tables: [], messageColumns: [], chatColumns: [],
    handleColumns: [], attachmentColumns: [], dateUnit: .nanoseconds
  )

  public static func repository() throws -> MessageRepository {
    MessageRepository(database: try emptyDatabase(), profile: emptyProfile)
  }

  public static var serializer: MessageSerializer { MessageSerializer(profile: emptyProfile) }

  /// A database holding exactly one attachment row, and a profile that declares exactly the
  /// columns needed to read it back.
  ///
  /// Narrow on purpose. `AttachmentInterface.resolvePath` is the one operation in this set
  /// that reads a row before it reaches Messages, so it needs a row to exist, but a copy of
  /// Apple's real `attachment` table would be a second schema corpus, and `SchemaProfile`
  /// selects only the columns it is told about. Three declared and three created is the
  /// smallest thing that makes the query run.
  ///
  /// `ROWID` is one of them and is not optional: `AttachmentRow` reads it unconditionally, so
  /// a profile that omits it produces a row GRDB traps on rather than an error a test can
  /// catch. SQLite supplies the value itself; it only has to be SELECTED.
  ///
  /// `filename` points nowhere, which is the state under test: a row the database has and the
  /// disk does not is an attachment purged to iCloud.
  public static func purgedAttachment(guid: String) throws -> MessageRepository {
    try attachment(guid: guid, filename: "/nonexistent/purged-attachment.heic")
  }

  /// The same one-row database, with the attachment's file wherever the caller says.
  public static func attachment(guid: String, filename: String) throws -> MessageRepository {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("interface-fixture-\(UUID().uuidString).sqlite").path
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE attachment (guid TEXT, filename TEXT)")
      try db.execute(
        sql: "INSERT INTO attachment (guid, filename) VALUES (?, ?)",
        arguments: [guid, filename])
    }

    let profile = SchemaProfile(
      tables: ["attachment"], messageColumns: [], chatColumns: [], handleColumns: [],
      attachmentColumns: ["ROWID", "guid", "filename"], dateUnit: .nanoseconds
    )
    return MessageRepository(database: try ReadOnlyDatabase(path: path), profile: profile)
  }

  /// A database holding one chat (with a participant, which is what makes a chat row visible)
  /// and the messages named, with a profile declaring exactly the columns that reads them.
  ///
  /// For the chat operations that look the chat up before they reach Messages, as the
  /// reference does: against the empty database those answer "Chat does not exist!" before
  /// the backend failure under test is ever reached.
  public static func chat(guid: String, messageGUIDs: [String] = []) throws -> MessageRepository {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("interface-fixture-\(UUID().uuidString).sqlite").path
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE chat (guid TEXT)")
      try db.execute(sql: "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)")
      try db.execute(sql: "CREATE TABLE message (guid TEXT)")
      try db.execute(sql: "INSERT INTO chat (guid) VALUES (?)", arguments: [guid])
      try db.execute(sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")
      for message in messageGUIDs {
        try db.execute(sql: "INSERT INTO message (guid) VALUES (?)", arguments: [message])
      }
    }

    let profile = SchemaProfile(
      tables: ["chat", "chat_handle_join", "message"], messageColumns: ["ROWID", "guid"],
      chatColumns: ["ROWID", "guid"], handleColumns: [], attachmentColumns: [],
      dateUnit: .nanoseconds
    )
    return MessageRepository(database: try ReadOnlyDatabase(path: path), profile: profile)
  }

  /// A real file on disk, for the operations that check one exists before calling Messages.
  public static func temporaryFile() throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("interface-fixture-\(UUID().uuidString).png").path
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
    return path
  }
}

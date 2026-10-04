//  TranscriptInterfaceTests
//  The export, end to end, over a real `chat.db` schema.
//
//  The sonoma fixture is copied and seeded with the row shapes the export has to recognise:
//  words from a contact, words from this Mac, a tapback on them, a rename, a photo, an
//  Apple Pay balloon, and a message past the window. Then each format is written and read
//  back. Names come from a contact index built in memory, which is how the test proves the
//  resolution order: a name the caller supplied beats the index, the index beats the
//  address.
//
//  NO REAL ADDRESSES: the fixture's `+12025550143` is in the reserved 555-01xx range and
//  `person@example.com` is RFC 2606. See CONTRIBUTING.md.

import BBContacts
import BBCore
import BBIMessage
import BBPersistence
import BBSerialization
import BBTranscript
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Transcript interface")
struct TranscriptInterfaceTests {

  static let chatGUID = "iMessage;+;chat-export-test"
  static let alice = "+12025550143"
  static let bob = "person@example.com"
  /// Nanoseconds since 2001, a little after the fixture's own rows.
  static let base: Int64 = 738_940_000_000_000_000
  static let second: Int64 = 1_000_000_000

  private struct Harness {
    let path: String
    let writer: DatabaseQueue
    let directory: ConversationDirectory
    let interface: TranscriptInterface
    let folder: URL
    let photo: URL

    func tearDown() {
      ChatFixtureCopy.remove(path)
      try? FileManager.default.removeItem(at: folder)
    }
  }

  private func harness(contactsEnabled: Bool = true) async throws -> Harness {
    let (path, writer) = try ChatFixtureCopy.make()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let photo = folder.appendingPathComponent("photo.jpg")
    try Data(repeating: 0xAB, count: 4096).write(to: photo)
    try Self.seed(writer, photo: photo)

    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)

    let appDatabase = AppDatabase(queue: try DatabaseQueue())
    try appDatabase.migrate(contributors: [ContactsSchema.self])
    let contacts = ContactIndex(database: appDatabase)
    try await contacts.upsert([
      ContactRecord(
        id: "local:alice", source: .local, firstName: "Alice", lastName: "Example",
        phoneNumbers: [Self.alice])
    ])

    let directory = ConversationDirectory(
      repository: repository, contacts: contacts, contactsEnabled: { contactsEnabled })
    let interface = TranscriptInterface(
      repository: repository, serializer: MessageSerializer(profile: profile),
      attachments: AttachmentInterface(repository: repository), conversations: directory,
      generator: "BlueBubbles Server test")
    return Harness(
      path: path, writer: writer, directory: directory, interface: interface, folder: folder,
      photo: photo)
  }

  /// A group of alice and bob with seven rows, in order: words, a reply, a tapback on the
  /// reply, a rename, a photo, an Apple Pay balloon, and one message past the window.
  private static func seed(_ writer: DatabaseQueue, photo: URL) throws {
    let payload = try AppMessagePayload.encode(
      url: "data:,", sessionID: UUID(), appName: "Apple Pay", appID: nil,
      summary: "Payment", caption: "$20.00")
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO chat (guid, style, state, chat_identifier, service_name, display_name)
          VALUES (?, 43, 3, 'chat-export-test', 'iMessage', 'Export Test')
          """, arguments: [chatGUID])
      let chatID = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, 1), (?, 2)",
        arguments: [chatID, chatID])

      func insert(
        _ guid: String, text: String?, handle: Int, fromMe: Bool, offset: Int64,
        columns: [String: (any DatabaseValueConvertible)?] = [:]
      ) throws {
        var names = ["guid", "text", "handle_id", "is_from_me", "date", "service", "error"]
        var values: [(any DatabaseValueConvertible)?] = [
          guid, text, handle, fromMe ? 1 : 0, base + offset * second, "iMessage", 0,
        ]
        for (name, value) in columns {
          names.append(name)
          values.append(value)
        }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        try db.execute(
          sql: "INSERT INTO message (\(names.joined(separator: ", "))) VALUES (\(placeholders))",
          arguments: StatementArguments(values))
        try db.execute(
          sql: "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)",
          arguments: [chatID, db.lastInsertedRowID, base + offset * second])
      }

      try insert("MSG-EXP-1", text: "hello there", handle: 1, fromMe: false, offset: 0)
      try insert("MSG-EXP-2", text: "hi!", handle: 0, fromMe: true, offset: 60)
      try insert(
        "MSG-EXP-3", text: "Loved “hi!”", handle: 2, fromMe: false, offset: 120,
        columns: ["associated_message_guid": "p:0/MSG-EXP-2", "associated_message_type": 2000])
      try insert(
        "MSG-EXP-4", text: nil, handle: 0, fromMe: true, offset: 180,
        columns: ["item_type": 2, "group_title": "Export Test"])
      try insert(
        "MSG-EXP-5", text: nil, handle: 1, fromMe: false, offset: 240,
        columns: ["cache_has_attachments": 1])
      try db.execute(
        sql: """
          INSERT INTO attachment
            (guid, original_guid, filename, uti, mime_type, transfer_name, total_bytes)
          VALUES ('ATT-EXP-1', 'ATT-EXP-1', ?, 'public.jpeg', 'image/jpeg', 'photo.jpg', 4096)
          """, arguments: [photo.path])
      try db.execute(
        sql: """
          INSERT INTO message_attachment_join (message_id, attachment_id)
          VALUES ((SELECT ROWID FROM message WHERE guid = 'MSG-EXP-5'), last_insert_rowid())
          """)
      try insert(
        "MSG-EXP-6", text: nil, handle: 1, fromMe: false, offset: 300,
        columns: [
          "balloon_bundle_id": "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
            + "com.apple.PassbookUIService.PeerPaymentMessagesExtension",
          "payload_data": payload,
        ])
      try insert("MSG-EXP-7", text: "much later", handle: 1, fromMe: false, offset: 100_000)
    }
  }

  private static func date(offset: Int64) -> Date {
    AppleTimestamp(rawValue: base + offset * second, unit: .nanoseconds).date ?? Date()
  }

  private func json(at url: URL) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    return try #require(object as? [String: Any])
  }

  // MARK: - The conversation

  @Test("The transcript's chat is the directory's row, names and all")
  func chatComesFromTheDirectory() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    let conversation = try await harness.directory.conversation(guid: Self.chatGUID)
    let chat = TranscriptInterface.chat(from: conversation)
    #expect(chat.title == "Export Test")
    #expect(chat.participants.map(\.displayName) == ["Alice Example", Self.bob])
    #expect(chat.participants.map(\.nameSource) == [.contacts, .none])
  }

  @Test("An unknown conversation is a not-found")
  func unknownChat() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    await #expect(throws: InterfaceError.self) {
      _ = try await harness.interface.export(
        TranscriptInterface.ExportRequest(chatGUID: "iMessage;+;chat-no-such"),
        to: harness.folder.appendingPathComponent("never.json"))
    }
  }

  // MARK: - Exporting

  @Test("JSON carries every row in the window, named and typed")
  func exportJSON() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    let destination = harness.folder.appendingPathComponent("out.json")
    let result = try await harness.interface.export(
      TranscriptInterface.ExportRequest(
        chatGUID: Self.chatGUID, format: .json, before: Self.date(offset: 1000),
        attachmentMode: .metadata, participantNames: [Self.bob: "Bob"],
        timeZone: TimeZone(identifier: "UTC")!),
      to: destination)
    #expect(result.summary.messageCount == 6)
    #expect(result.summary.reactionCount == 1)
    #expect(result.summary.attachmentCount == 1)
    #expect(result.filename.hasPrefix("Export-Test-start-"))
    #expect(result.filename.hasSuffix(".json"))

    let root = try json(at: destination)
    let chat = try #require(root["chat"] as? [String: Any])
    #expect(chat["title"] as? String == "Export Test")
    let participants = try #require(chat["participants"] as? [[String: Any]])
    #expect(participants.map { $0["display_name"] as? String } == ["Alice Example", "Bob"])
    #expect(participants.map { $0["name_source"] as? String } == ["contacts", "client"])

    let rows = try #require(root["messages"] as? [[String: Any]])
    #expect(rows.map { $0["guid"] as? String } == (1...6).map { "MSG-EXP-\($0)" })
    #expect(rows[0]["text"] as? String == "hello there")
    #expect((rows[0]["sender"] as? [String: Any])?["name"] as? String == "Alice Example")
    #expect(rows[1]["is_from_me"] as? Bool == true)
    #expect(rows[1]["sender"] is NSNull)

    let reaction = try #require(rows[2]["reaction"] as? [String: Any])
    #expect(rows[2]["kind"] as? String == "reaction")
    #expect(reaction["type"] as? String == "love")
    #expect(reaction["target_guid"] as? String == "MSG-EXP-2")
    #expect(reaction["target_summary"] as? String == "hi!")

    let event = try #require(rows[3]["group_event"] as? [String: Any])
    #expect(event["description"] as? String == "You named the conversation \"Export Test\".")

    let attachments = try #require(rows[4]["attachments"] as? [[String: Any]])
    #expect(attachments.first?["name"] as? String == "photo.jpg")
    #expect(attachments.first?["path"] is NSNull)

    let balloon = try #require(rows[5]["balloon"] as? [String: Any])
    #expect(balloon["description"] as? String == "Apple Pay: $20.00 — Payment")
  }

  @Test("Plain text reads the conversation the way the app shows it")
  func exportText() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    let destination = harness.folder.appendingPathComponent("out.txt")
    _ = try await harness.interface.export(
      TranscriptInterface.ExportRequest(
        chatGUID: Self.chatGUID, format: .txt, after: Self.date(offset: 60),
        before: Self.date(offset: 240), attachmentMode: .none, meLabel: "Zach",
        timeZone: TimeZone(identifier: "UTC")!),
      to: destination)
    let text = try String(contentsOf: destination, encoding: .utf8)
    #expect(text.contains("Conversation: Export Test\n"))
    #expect(text.contains("] Zach: hi!\n"))
    #expect(text.contains("] — \(Self.bob) loved “hi!”\n"))
    #expect(text.contains("] — Zach named the conversation \"Export Test\".\n"))
    #expect(text.contains("] Alice Example: 1 Photo\n"))
    #expect(!text.contains("hello there"), "before the window")
    #expect(!text.contains("Apple Pay"), "after the window")
    #expect(text.contains("Messages: 4\n"))
  }

  @Test("With files the result is a ZIP holding the page and the photo")
  func exportArchive() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    let destination = harness.folder.appendingPathComponent("out.zip")
    let result = try await harness.interface.export(
      TranscriptInterface.ExportRequest(
        chatGUID: Self.chatGUID, format: .html, attachmentMode: .files, archive: true,
        convertAttachments: false),
      to: destination)
    #expect(result.isZip)
    #expect(result.contentType == "application/zip")
    #expect(result.summary.attachmentsCopied == 1)
    #expect(result.summary.attachmentsMissing == 0)
    let listing = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-Z1", destination.path], output: .standardOutputOnly,
      timeout: .seconds(30))
    #expect(listing.text.split(separator: "\n").map(String.init) == [
      "transcript.html", "attachments/ATT-EXP-1/photo.jpg",
    ])
    let check = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-t", destination.path], timeout: .seconds(30))
    #expect(check.succeeded, check.text)
    let page = try Subprocess.runSynchronously(
      "/usr/bin/unzip", ["-p", destination.path, "transcript.html"],
      output: .standardOutputOnly, timeout: .seconds(30))
    #expect(page.text.contains("<img src=\"attachments/ATT-EXP-1/photo.jpg\""))
    // The scratch folder the archive was built from is gone.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.folder.path)
    #expect(!leftovers.contains { $0.hasPrefix(".bb-export-") })
  }

  @Test("A missing file is reported, not fatal")
  func missingAttachment() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    try FileManager.default.removeItem(at: harness.photo)
    let destination = harness.folder.appendingPathComponent("out.json")
    let result = try await harness.interface.export(
      TranscriptInterface.ExportRequest(
        chatGUID: Self.chatGUID, format: .json, attachmentMode: .files),
      to: destination)
    #expect(result.summary.attachmentsMissing == 1)
    #expect(result.summary.attachmentsCopied == 0)
  }

  @Test("With Contacts off, the index is not consulted and the address is shown")
  func contactsOff() async throws {
    let harness = try await harness(contactsEnabled: false)
    defer { harness.tearDown() }
    let found = try await harness.directory.conversation(guid: Self.chatGUID)
    #expect(found.participants.map(\.nameSource) == [.none, .none])
    #expect(found.participants[0].displayName == "+1 (202) 555-0143")
  }

  @Test("A window whose start is after its end is refused before anything is read")
  func invalidWindow() async throws {
    let harness = try await harness()
    defer { harness.tearDown() }
    await #expect(throws: InterfaceError.self) {
      _ = try await harness.interface.export(
        TranscriptInterface.ExportRequest(
          chatGUID: Self.chatGUID, after: Self.date(offset: 100), before: Self.date(offset: 0)),
        to: harness.folder.appendingPathComponent("never.json"))
    }
  }

  // MARK: - Naming

  @Test("The file is named from the title and the window")
  func filenames() {
    let chat = Transcript.Chat(
      guid: "g", displayName: "Weekend Plans!", isGroup: true, participants: [])
    let zone = TimeZone(identifier: "UTC")!
    let whole = TranscriptInterface.ExportRequest(chatGUID: "g", format: .txt, timeZone: zone)
    #expect(TranscriptInterface.filename(for: chat, request: whole) == "Weekend-Plans.txt")
    let windowed = TranscriptInterface.ExportRequest(
      chatGUID: "g", format: .html, after: Date(timeIntervalSince1970: 1_704_067_200),
      before: Date(timeIntervalSince1970: 1_711_929_599), attachmentMode: .files,
      archive: true, timeZone: zone)
    #expect(
      TranscriptInterface.filename(for: chat, request: windowed)
        == "Weekend-Plans-20240101-20240331.zip")
    let untitled = Transcript.Chat(guid: "g", isGroup: false, participants: [])
    #expect(TranscriptInterface.slug(untitled.title) == "g")
    #expect(TranscriptInterface.slug("   ") == "transcript")
    #expect(TranscriptInterface.sanitise("../a/b:c.jpg") == "-a-b-c.jpg")
  }

  @Test("Reaction types beyond the reference's table are spelled")
  func reactionTypes() {
    #expect(TranscriptInterface.reactionType(2000) == "love")
    #expect(TranscriptInterface.reactionType(3001) == "-like")
    #expect(TranscriptInterface.reactionType(2006) == "emoji")
    #expect(TranscriptInterface.reactionType(3006) == "-emoji")
    #expect(TranscriptInterface.reactionType(2007) == "sticker")
    #expect(TranscriptInterface.reactionType(2042) == "2042")
  }
}

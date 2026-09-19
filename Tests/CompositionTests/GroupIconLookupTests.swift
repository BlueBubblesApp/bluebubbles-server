//  GroupIconLookupTests
//  Where a group chat's icon actually lives.
//
//  `GET /chat/:guid/icon` returned 404 for every chat on a macOS 26 host, including the six
//  that have a photo. It probed `~/Library/Messages/Attachments/GroupPhotoImage/<group_id>`
//  for a file named after the chat's `group_id` — a directory that does not exist, and a
//  layout Messages has never used.
//
//  **Its unit test passed the whole time**, because it created that directory in `tmp`,
//  wrote a file named after a fake group id into it, and asserted the probe found it. The
//  test agreed with the code about a world neither had checked. That is why this file drives
//  a REAL `chat.db` through the real repository: the only assertion that could have caught
//  this is one that reads a database Messages wrote.
//
//  What Apple actually does: the icon is an ORDINARY ATTACHMENT, in the usual sharded tree
//  under a `transfer_name` of `GroupPhotoImage`, and the chat row points at it —
//  `chat.properties` is a binary plist carrying `groupPhotoGuid`, which names the
//  `attachment.guid`. That is what the reference reads (`chatInterface.ts:424`), and it
//  resolves correctly on macOS 26 while the directory probe does not.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Group icon lookup")
struct GroupIconLookupTests {

  /// The fixture's own group chat, rather than one inserted here: a chat this repository
  /// will actually resolve, so a "not found" in these tests is about the ICON and not about
  /// the chat. An earlier draft inserted its own row, the row did not resolve, and three of
  /// the four negative tests passed on `Chat does not exist!` — the right answer for the
  /// wrong reason, which is the exact failure this file exists to document.
  private static let chatGUID = "iMessage;+;chat000000000000000001"
  private static let photoGUID = "at_0_11111111-2222-3333-4444-555555555555"

  /// A `chat.db` copy carrying one group chat with a photo, wired the way Messages wires it.
  private func fixture(
    photoPath: String?, properties: Data?
  ) async throws -> (ChatInterface, URL) {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-icon-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let queue = try DatabaseQueue(path: path.path)
    try await queue.write { db in
      try db.execute(
        sql: "UPDATE chat SET properties = ? WHERE guid = ?",
        arguments: [properties, Self.chatGUID])
      if let photoPath {
        try db.execute(
          sql: """
            INSERT INTO attachment (guid, original_guid, filename, transfer_name, total_bytes)
            VALUES (?, ?, ?, 'GroupPhotoImage', 4)
            """,
          arguments: [Self.photoGUID, Self.photoGUID, photoPath])
      }
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 26)
    return (
      ChatInterface(
        repository: MessageRepository(database: database, profile: profile),
        serializer: MessageSerializer(profile: profile)
      ), path
    )
  }

  /// The blob Messages writes: a binary plist with `groupPhotoGuid` among its keys.
  private static func properties(photoGUID: String?) throws -> Data {
    var fields: [String: Any] = ["pv": 37, "supportsEncryption": true]
    if let photoGUID { fields["groupPhotoGuid"] = photoGUID }
    return try PropertyListSerialization.data(
      fromPropertyList: fields, format: .binary, options: 0)
  }

  private func imageOnDisk() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-icon-\(UUID().uuidString)")
      .appendingPathComponent("GroupPhotoImage")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
    return url.path
  }

  @Test("The icon is resolved through groupPhotoGuid to a real attachment")
  func resolvesThroughProperties() async throws {
    let file = try imageOnDisk()
    let (chat, _) = try await fixture(
      photoPath: file, properties: try Self.properties(photoGUID: Self.photoGUID))

    #expect(try await chat.groupIconPath(guid: Self.chatGUID) == file)
  }

  @Test("A chat whose properties name no photo is a 404")
  func noPhotoGUIDIsNotFound() async throws {
    let (chat, _) = try await fixture(
      photoPath: try imageOnDisk(), properties: try Self.properties(photoGUID: nil))

    await expectIconNotFound(chat)
  }

  @Test("A photo named in the database but absent from disk is a 404, not a path")
  func missingFileIsNotFound() async throws {
    // Deliberately not the purged-attachment path, which offers a Private API download:
    // this route is reachable without a helper by design, so it must not promise one.
    let (chat, _) = try await fixture(
      photoPath: "/nonexistent/GroupPhotoImage",
      properties: try Self.properties(photoGUID: Self.photoGUID))

    await expectIconNotFound(chat)
  }

  @Test("A chat with no properties blob at all is a 404")
  func noPropertiesIsNotFound() async throws {
    let (chat, _) = try await fixture(photoPath: try imageOnDisk(), properties: nil)

    await expectIconNotFound(chat)
  }

  /// Asserts the ICON refusal specifically.
  ///
  /// `throws: InterfaceError.self` is not enough: `Chat does not exist!` is an
  /// `InterfaceError` too, and a test that accepts any of them passes when the fixture is
  /// broken rather than when the code is right.
  private func expectIconNotFound(
    _ chat: ChatInterface, _ location: SourceLocation = #_sourceLocation
  ) async {
    do {
      let path = try await chat.groupIconPath(guid: Self.chatGUID)
      Issue.record("expected a refusal, got \(path)", sourceLocation: location)
    } catch let error as InterfaceError {
      #expect(
        error == .notFound(ReferenceMessages.chatIconNotFound),
        "must refuse the ICON, not the chat", sourceLocation: location)
    } catch {
      Issue.record("unexpected \(type(of: error))", sourceLocation: location)
    }
  }

  // MARK: - The blob reader

  @Test("The last non-empty groupPhotoGuid wins, as the reference's loop does")
  func lastEntryWins() throws {
    let blob = try PropertyListSerialization.data(
      fromPropertyList: ["groupPhotoGuid": "at_0_SECOND"], format: .binary, options: 0)
    #expect(ChatInterface.groupPhotoGUID(in: blob) == "at_0_SECOND")
  }

  @Test("An empty or unreadable blob yields nothing rather than throwing")
  func malformedBlobIsNil() throws {
    #expect(ChatInterface.groupPhotoGUID(in: nil) == nil)
    #expect(ChatInterface.groupPhotoGUID(in: Data()) == nil)
    #expect(ChatInterface.groupPhotoGUID(in: Data("not a plist".utf8)) == nil)
    #expect(
      ChatInterface.groupPhotoGUID(
        in: try PropertyListSerialization.data(
          fromPropertyList: ["groupPhotoGuid": ""], format: .binary, options: 0)) == nil)
  }
}

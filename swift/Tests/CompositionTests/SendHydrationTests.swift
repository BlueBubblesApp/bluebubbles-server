//  SendHydrationTests
//  A send answers with the MESSAGE, and this is what proves it.
//
//  All three send routes used to answer `{guid, chatGuid, backend}` — identifiers — where the
//  reference answers the serialised row. A client that read back the text, the date, the
//  handle or the chats of the message it had just sent got none of them and had to go and ask
//  again, and the recorded fixture
//  (`Fixtures/http/post_api_v1_message_text-5baa61-200.json`) has carried the full row the
//  whole time. It is the largest v1 divergence the corpus knows about, and the one the parity
//  replay can never catch: sending routes are deny-listed, because the harness drives a real
//  server and the AppleScript backend needs no helper to put a message in front of a person.
//
//  So the wait and the projection are tested here instead, over a real `chat.db` — the same
//  synthetic fixture `BBIMessageTests` owns. What is NOT tested here is the send itself; that
//  needs Messages.

import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Send hydration")
struct SendHydrationTests {

  /// A real database, read-only, at a throwaway path.
  private func interface() async throws -> MessageInterface {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-send-hydration-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile)
    )
  }

  /// The GUID of a message the account sent, in the group chat.
  private static let sentGUID = "11111111-0000-0000-0000-000000000007"

  @Test("A Private API send answers with the row, its handle and its chats")
  func hydratesByGUID() async throws {
    let interface = try await interface()
    let message = try await interface.awaitSentMessage(guid: Self.sentGUID)
    let hydrated = try #require(message, "the fixture row should be found on the first look")

    let json = interface.serialize(
      MessageInterface.SendOutcome(
        backend: .privateAPI, messageGUID: Self.sentGUID, message: hydrated
      )
    )

    #expect(json["guid"]?.stringValue == Self.sentGUID)
    #expect(json["text"]?.stringValue == "Actually, make it Sunday")
    #expect(json["isFromMe"]?.boolValue == true)
    // The keys a client reads back and could not get from an identifier.
    #expect(json["dateCreated"] != nil)
    #expect(json["chats"]?.arrayValue?.isEmpty == false)
    // `.full` is the reference's send config: the blob columns are parsed here even though
    // they are opt-in on the read routes.
    #expect(json.objectKeys.contains("attributedBody"))
    #expect(json.objectKeys.contains("messageSummaryInfo"))
    #expect(json.objectKeys.contains("payloadData"))
    // Participants are NOT loaded — the reference passes `loadChatParticipants: false`
    // because it just sent to that chat and the caller knows who is in it.
    #expect(json["chats"]?[0]?["participants"] == nil)
  }

  /// `tempGuid` is the client's own correlation token, echoed back — and only when it sent
  /// one. Emitting it as null would be an added key on every send from a client that does
  /// not use them.
  @Test("tempGuid is echoed when the client sent one, and absent when it did not")
  func echoesTempGUID() async throws {
    let interface = try await interface()
    let hydrated = try #require(try await interface.awaitSentMessage(guid: Self.sentGUID))
    let outcome = MessageInterface.SendOutcome(
      backend: .privateAPI, messageGUID: Self.sentGUID, message: hydrated
    )

    #expect(
      interface.serialize(outcome, tempGUID: "TEMP-9")["tempGuid"]?.stringValue == "TEMP-9"
    )
    #expect(interface.serialize(outcome)["tempGuid"] == nil)
  }

  /// The AppleScript path has no GUID, so it matches on what was sent and where.
  @Test("An AppleScript send is found by its chat, its text and the window")
  func hydratesByTextMatch() async throws {
    let interface = try await interface()
    let message = try await interface.awaitSentMessage(
      inChat: "iMessage;+;chat000000000000000001",
      text: "Actually, make it Sunday",
      // The fixture's rows are older than any real send window, so the search has to
      // start before them. `hydrationWindowStart()` is what production uses.
      sentAfter: Date(timeIntervalSince1970: 0)
    )
    #expect(try #require(message).row.guid == Self.sentGUID)
  }

  /// The text match reads `universalText()`, not the `text` COLUMN.
  ///
  /// MEASURED against a live AppleScript send: Messages writes the row with `text` NULL and
  /// the words only in `attributedBody`, and leaves it that way. Matching the column meant
  /// this never matched at all — every AppleScript send waited out the full sixty seconds
  /// and answered with the identifier fallback instead of the message.
  ///
  /// No fixture could have caught it, because a fixture database has `text` populated. So
  /// the row is emptied here first, which is the state a real send is read in.
  @Test("An AppleScript send is found when text lives only in attributedBody")
  func hydratesWhenTextColumnIsNull() async throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-null-text-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)
    defer { try? FileManager.default.removeItem(at: path) }

    // The attributed body for "Actually, make it Sunday", and no `text`. Written through a
    // second connection because that is how Messages does it.
    let writer = try DatabaseQueue(path: path.path)
    // `NSArchiver` is the only writer for this format, which is why the decoder uses
    // `NSUnarchiver` — see `AttributedBodyTests`, which builds its inputs the same way.
    let body = NSArchiver.archivedData(
      withRootObject: NSMutableAttributedString(string: "Actually, make it Sunday")
    )
    try await writer.write { db in
      try db.execute(
        sql: "UPDATE message SET text = NULL, attributedBody = ? WHERE guid = ?",
        arguments: [body, Self.sentGUID])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let interface = MessageInterface(
      repository: MessageRepository(database: database, profile: profile),
      serializer: MessageSerializer(profile: profile)
    )

    let message = try await interface.awaitSentMessage(
      inChat: "iMessage;+;chat000000000000000001",
      text: "Actually, make it Sunday",
      sentAfter: Date(timeIntervalSince1970: 0),
      policy: .init(initialDelay: .milliseconds(1), multiplier: 1, limit: .milliseconds(20))
    )
    #expect(try #require(message).row.guid == Self.sentGUID)
  }

  /// And it survives the GUID being spelled differently from the row.
  ///
  /// This is tenet 3 reaching the send path: AppleScript reports whichever candidate
  /// resolved, macOS 26 rewrote every prefix to `any`, and the row in `chat.db` may carry
  /// either. A lookup that compared the GUID with `=` would find nothing and silently
  /// degrade every AppleScript send to the identifier fallback — a failure that looks like
  /// a slow database rather than like a bug. `MessageRepository` expands through
  /// `ChatGUID.lookupCandidates()`; this pins that the send path inherits it.
  @Test("An AppleScript send is found when the chat GUID is spelled differently")
  func hydratesAcrossGUIDSpellings() async throws {
    let interface = try await interface()
    let message = try await interface.awaitSentMessage(
      inChat: "any;+;chat000000000000000001",
      text: "Actually, make it Sunday",
      sentAfter: Date(timeIntervalSince1970: 0)
    )
    #expect(try #require(message).row.guid == Self.sentGUID)
  }

  /// The wait is for the row AND its chat join, which do not arrive together.
  ///
  /// MEASURED against a live send: Messages writes the `message` row first and joins it to
  /// the chat a moment later, so a wait that stopped at "the row exists" answered with
  /// `chats: []` — and a client reads that to place the message it just sent. Invisible to
  /// every fixture, because a fixture database has its joins already written; reproduced
  /// here by removing the join and putting it back late.
  @Test("A send waits for the chat join, not just for the row")
  func waitsForTheChatJoin() async throws {
    let (interface, writer, path) = try await Self.writableInterface()
    defer { try? FileManager.default.removeItem(atPath: path) }

    let join = try await writer.write { db -> Int64 in
      let id = try #require(
        try Int64.fetchOne(
          db,
          sql: "SELECT chat_id FROM chat_message_join WHERE message_id = "
            + "(SELECT ROWID FROM message WHERE guid = ?)",
          arguments: [Self.sentGUID]))
      try db.execute(
        sql: "DELETE FROM chat_message_join WHERE message_id = "
          + "(SELECT ROWID FROM message WHERE guid = ?)", arguments: [Self.sentGUID])
      return id
    }

    // Put it back while the poll is running, as Messages would.
    Task.detached {
      try? await Task.sleep(for: .milliseconds(300))
      try? await writer.write { db in
        try db.execute(
          sql: "INSERT INTO chat_message_join (chat_id, message_id, message_date) SELECT ?, "
            + "ROWID, date FROM message WHERE guid = ?",
          arguments: [join, Self.sentGUID])
      }
    }

    let message = try await interface.awaitSentMessage(guid: Self.sentGUID)
    #expect(try #require(message).relations.chats.isEmpty == false, "answered before the join")
  }

  /// And if the join never comes, the row is answered anyway.
  ///
  /// A message with no chats is a worse answer than one with them and a far better answer
  /// than none: the send happened either way, and reporting a failure invites a duplicate.
  @Test("A join that never arrives still answers with the row")
  func fallsBackToTheUnjoinedRow() async throws {
    let (interface, writer, path) = try await Self.writableInterface()
    defer { try? FileManager.default.removeItem(atPath: path) }

    try await writer.write { db in
      try db.execute(
        sql: "DELETE FROM chat_message_join WHERE message_id = "
          + "(SELECT ROWID FROM message WHERE guid = ?)", arguments: [Self.sentGUID])
    }

    let message = try await interface.awaitSentMessage(
      guid: Self.sentGUID,
      policy: .init(initialDelay: .milliseconds(1), multiplier: 1, limit: .milliseconds(20))
    )
    let hydrated = try #require(message, "a timed-out join must not lose the row")
    #expect(hydrated.row.guid == Self.sentGUID)
    #expect(hydrated.relations.chats.isEmpty)
  }

  /// A copy of the fixture that a second connection can write to, the way Messages does.
  static func writableInterface() async throws -> (MessageInterface, DatabaseQueue, String) {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-join-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return (
      MessageInterface(
        repository: MessageRepository(database: database, profile: profile),
        serializer: MessageSerializer(profile: profile)
      ),
      try DatabaseQueue(path: path.path),
      path.path
    )
  }

  /// A wait that finds nothing returns nil rather than throwing, and the send still answers
  /// 200. Reporting a failure for a row that was merely slow is how a client is talked into
  /// sending the same message twice.
  @Test("A row that never arrives times out to nil, not to an error")
  func timesOutToNil() async throws {
    let interface = try await interface()
    let policy = MessageInterface.SendHydrationPolicy(
      initialDelay: .milliseconds(1), multiplier: 1, limit: .milliseconds(5)
    )
    let message = try await interface.awaitSentMessage(
      guid: "00000000-0000-0000-0000-00000000dead", policy: policy
    )
    #expect(message == nil)

    let json = interface.serialize(
      MessageInterface.SendOutcome(
        backend: .privateAPI, messageGUID: "00000000-0000-0000-0000-00000000dead"
      )
    )
    #expect(json.objectKeys == ["guid"])
  }

  /// Messages can accept a send and then fail it. The reference reports that as a 500
  /// carrying the message, which is how a client shows a red mark against what it just sent
  /// — a 200 would tell it the send worked.
  @Test("A row with a non-zero error is a failed send")
  func detectsFailedSend() async throws {
    let interface = try await interface()
    let hydrated = try #require(try await interface.awaitSentMessage(guid: Self.sentGUID))
    #expect(
      !MessageInterface.sendFailed(
        MessageInterface.SendOutcome(backend: .privateAPI, message: hydrated)
      ))
    // Nothing to hydrate cannot be a failure: the row is what records one.
    #expect(
      !MessageInterface.sendFailed(
        MessageInterface.SendOutcome(backend: .appleScript, chatGUID: "iMessage;-;x")
      ))
  }
}

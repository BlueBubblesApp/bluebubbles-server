//  ChatHoldEventTests
//  The event a client receives for a message whose chat row landed after it.
//
//  `ChatJoinHoldTests` shows when the detector lets a message go. This shows what that is worth
//  on the wire, by driving the detector and the step the service's pump runs against Apple's
//  schema, written in the order Messages writes it. The client reads `chats.first` on
//  `new-message` without checking, in its action handler, so an empty
//  array loses the notification rather than degrading it.

import BBCore
import BBEvents
import BBPersistence
import BBSerialization
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage
@testable import BlueBubblesServerCore

@Suite("The event for a message that reached its chat late", .removingChatDBCopies)
struct ChatHoldEventTests {

  private func chatCount(_ payload: JSONValue) -> Int? {
    guard case .object(let fields) = payload, case .array(let chats) = fields["chats"] else {
      return nil
    }
    return chats.count
  }

  @Test("new-message names its chat on both payloads when the join lands after the row")
  func eventCarriesItsChat() async throws {
    let path = try CommittedChatDB.copy(.sonoma).path
    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let start = Date()
    let detector = ChangeDetector(repository: repository, startingFrom: start)
    _ = try await detector.tick(now: start)

    // Each write on its own connection and its own commit, as Messages makes them.
    let stamp = AppleTimestamp.from(start.addingTimeInterval(1), unit: .nanoseconds).rawValue
    try await write(to: path) { db in
      try db.execute(
        sql: "INSERT INTO message (guid, text, date, is_from_me) VALUES ('LATE-JOIN', 'x', ?, 0)",
        arguments: [stamp])
    }
    let early = try await detector.tick(now: start.addingTimeInterval(1))
    #expect(early.messages.isEmpty, "announced before its chat, which is `chats: []` on the wire")

    try await write(to: path) { db in
      try db.execute(
        sql: """
          INSERT INTO chat_message_join (chat_id, message_id, message_date)
          SELECT (SELECT MIN(ROWID) FROM chat), m.ROWID, m.date FROM message m
          WHERE m.guid = 'LATE-JOIN'
          """)
    }
    let change = try #require(
      try await detector.tick(now: start.addingTimeInterval(2)).messages.first)
    #expect(change.message.guid == "LATE-JOIN")

    var hydrator = EventHydrator(repository: repository)
    let event = try #require(
      await ChangeDetectionService.event(
        for: change, serializer: MessageSerializer(profile: profile), hydrator: &hydrator))
    #expect(event.name == .newMessage)
    #expect(chatCount(event.fullPayload) == 1)
    #expect(chatCount(event.notificationPayload) == 1)
  }

  /// The unfixed server told a client about a send that failed in the gap with both events,
  /// in this order, on a real send. Holding the row must not cost it the second one.
  @Test("A send that failed during the hold still raises message-send-error")
  func failureStillRaisesItsEvent() async throws {
    let path = try CommittedChatDB.copy(.sonoma).path
    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let start = Date()
    let detector = ChangeDetector(repository: repository, startingFrom: start)
    _ = try await detector.tick(now: start)

    let stamp = AppleTimestamp.from(start.addingTimeInterval(1), unit: .nanoseconds).rawValue
    try await write(to: path) { db in
      try db.execute(
        sql: "INSERT INTO message (guid, text, date, is_from_me) VALUES ('FAILS', 'x', ?, 1)",
        arguments: [stamp])
    }
    #expect(try await detector.tick(now: start.addingTimeInterval(1)).messages.isEmpty)

    try await write(to: path) { db in
      try db.execute(sql: "UPDATE message SET error = 22 WHERE guid = 'FAILS'")
      try db.execute(
        sql: """
          INSERT INTO chat_message_join (chat_id, message_id, message_date)
          SELECT (SELECT MIN(ROWID) FROM chat), m.ROWID, m.date FROM message m
          WHERE m.guid = 'FAILS'
          """)
    }
    let changes = try await detector.tick(now: start.addingTimeInterval(2)).messages

    var hydrator = EventHydrator(repository: repository)
    let serializer = MessageSerializer(profile: profile)
    var names: [EventName] = []
    for change in changes {
      let event = try #require(
        await ChangeDetectionService.event(
          for: change, serializer: serializer, hydrator: &hydrator))
      names.append(event.name)
      #expect(chatCount(event.fullPayload) == 1)
    }
    #expect(names == [.newMessage, .messageSendError])
  }

  /// The client throws on `chats: []`, so an event carrying one reaches nobody, and the
  /// reference's poll never returns a message without a chat.
  @Test(
    "A message whose chats cannot be read, or that has none, gets no event",
    arguments: [
      "ALTER TABLE chat_message_join RENAME TO chat_message_join_gone",
      "DELETE FROM chat_message_join WHERE message_id = (SELECT ROWID FROM message WHERE guid = 'LOST')",
    ])
  func noChatNoEvent(breakage: String) async throws {
    let path = try CommittedChatDB.copy(.sonoma).path
    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let start = Date()
    let detector = ChangeDetector(repository: repository, startingFrom: start)
    _ = try await detector.tick(now: start)

    let stamp = AppleTimestamp.from(start.addingTimeInterval(1), unit: .nanoseconds).rawValue
    try await write(to: path) { db in
      try db.execute(
        sql: "INSERT INTO message (guid, text, date, is_from_me) VALUES ('LOST', 'x', ?, 0)",
        arguments: [stamp])
      try db.execute(
        sql: """
          INSERT INTO chat_message_join (chat_id, message_id, message_date)
          SELECT (SELECT MIN(ROWID) FROM chat), m.ROWID, m.date FROM message m
          WHERE m.guid = 'LOST'
          """)
    }
    let change = try #require(
      try await detector.tick(now: start.addingTimeInterval(1)).messages.first)

    try await write(to: path) { db in try db.execute(sql: breakage) }

    var hydrator = EventHydrator(repository: repository)
    let event = await ChangeDetectionService.event(
      for: change, serializer: MessageSerializer(profile: profile), hydrator: &hydrator)
    #expect(event == nil)
  }

  private func write(
    to path: String, _ body: @escaping @Sendable (Database) throws -> Void
  ) async throws {
    let writer = try DatabaseQueue(path: path)
    try await writer.write(body)
    try writer.close()
  }
}

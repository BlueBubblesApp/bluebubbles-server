//  MessageCountParityTests
//  The parameters the three count routes accept, and the date boundaries they compare with.
//
//  **Why this suite exists.** `GET /message/count`, `/count/me` and `/count/updated`
//  destructure one identical parameter list in the reference (`after`, `before`, `chatGuid`,
//  `minRowId`, `maxRowId`), and this server read a different subset on each: `chatGuid` on
//  the first and neither of the others, the row-id window on none of the three. A client
//  asking "how many have I sent IN THIS CHAT" was answered for every chat.
//
//  `/count/updated` had its own hand-written statement, which is WHY it could not honour any
//  of them: there was nothing on that path to parse them into. It is a mode on the shared
//  query now, so the three cannot drift apart again.
//
//  The date boundary is the other half. The reference compares `>=` and `<=`; this compared
//  `>` and `<`, so a message whose timestamp is exactly the boundary was dropped — and the
//  incremental sync passes its last sync time as `after`, which makes that the message that
//  is never sent and never asked for again.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Message count parity")
struct MessageCountParityTests {

  /// The fixture seeds six messages at +0, +30, +60, +90, +120 and +300 from this instant,
  /// three of them from me, spread over three chats.
  private let base = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeFixture() async throws -> ChatDatabaseFixture {
    try await ChatDatabaseFixture()
  }

  // MARK: - Inclusive boundaries

  @Test("after and before are inclusive, as the reference's are")
  func inclusiveDateBounds() async throws {
    let fixture = try await makeFixture()
    defer { fixture.tearDown() }
    let query = MessageRepository.MessageQuery(after: base.addingTimeInterval(300))
    // The +300 message is AT the boundary. Exclusive, it was invisible to a sync that
    // asked for everything after its own last run.
    #expect(try await fixture.repository.messageCount(query) == 1)
    #expect(try await fixture.repository.messages(query).map(\.guid) == ["MSG-0005"])

    let upper = MessageRepository.MessageQuery(before: base)
    #expect(try await fixture.repository.messageCount(upper) == 1)
    #expect(try await fixture.repository.messages(upper).map(\.guid) == ["MSG-0001"])
  }

  // MARK: - The shared parameter list

  @Test("chatGuid narrows every count, not just the plain one")
  func chatGUIDOnAllThree() async throws {
    let fixture = try await makeFixture()
    defer { fixture.tearDown() }
    let chat = ChatDatabaseFixture.chatGUID(ChatDatabaseFixture.aliceAddress)

    // Plain: chat 1 holds three of the six.
    #expect(
      try await fixture.repository.messageCount(.init(chatGUID: chat)) == 3)
    // Sent-by-me: one of those three. This route ignored `chatGuid` entirely and would
    // have answered 3, the count for the whole database.
    #expect(
      try await fixture.repository.messageCount(.init(chatGUID: chat, onlyFromMe: true)) == 1)
    // Updated: the fixture delivers every message, so the window is what narrows it.
    #expect(
      try await fixture.repository.updatedMessageCount(
        .init(chatGUID: chat, after: base)) == 3)
  }

  @Test("the row-id window is inclusive at both ends")
  func rowIDWindow() async throws {
    let fixture = try await makeFixture()
    defer { fixture.tearDown() }
    // ROWIDs 1...6 in seed order. `minRowId` is `>=` and `maxRowId` is `<=`, which is
    // what the reference binds; both were ignored on all three routes.
    #expect(try await fixture.repository.messageCount(.init(minRowID: 4)) == 3)
    #expect(try await fixture.repository.messageCount(.init(maxRowID: 2)) == 2)
    #expect(try await fixture.repository.messageCount(.init(minRowID: 2, maxRowID: 4)) == 3)
    // And it composes with the rest of the list rather than replacing it.
    #expect(
      try await fixture.repository.messageCount(.init(onlyFromMe: true, minRowID: 2)) == 3)
  }

  @Test("the updated count still asks about delivery and reading")
  func updatedCountUsesTheRightColumns() async throws {
    let fixture = try await makeFixture()
    defer { fixture.tearDown() }
    // Every message is delivered 60s after its own date, so a window opening after the
    // last delivery holds nothing — which is only true if this reads `date_delivered`
    // and `date_read` rather than `date`.
    #expect(
      try await fixture.repository.updatedMessageCount(
        .init(after: base.addingTimeInterval(3600))) == 0)
    #expect(try await fixture.repository.updatedMessageCount(.init(after: base)) == 6)
    // The plain count over the same window disagrees, which is the point of the mode.
    #expect(
      try await fixture.repository.messageCount(
        .init(after: base.addingTimeInterval(3600))) == 0)
  }

  /// The reference's bracketing, which is not the obvious one.
  @Test("an updated window brackets each column on its own")
  func updatedWindowBracketing() async throws {
    let fixture = try await makeFixture()
    defer { fixture.tearDown() }
    // `(delivered in window) OR (read in window)`, not `(either after) AND (either
    // before)`. The second form is what this used to do and it over-matches badly, because
    // an unread message carries `date_read = 0`: zero fails `>= after` but SATISFIES
    // `<= before`, so any message delivered after the window passed the second test on its
    // empty read column and was counted.
    //
    // The fixture delivers each message 60s after its own date (+60, +90, +120, +150, +180
    // and +360) and records a read 120s after it for the three sent within the first minute
    // (+120, +150 and +180). A window of [+130, +170] therefore holds exactly two things:
    // MSG-0006's delivery at +150 and MSG-0004's read at +150.
    //
    // Under the old bracketing it held five. MSG-0002 qualified on a read at +180 paired
    // with a delivery at +120 — neither inside the window — and MSG-0003 and MSG-0005 on
    // `date_read = 0` alone.
    let window = MessageRepository.MessageQuery(
      after: base.addingTimeInterval(130), before: base.addingTimeInterval(170))
    let rows = try await fixture.repository.messages(
      MessageRepository.MessageQuery(
        after: base.addingTimeInterval(130), before: base.addingTimeInterval(170),
        dateField: .updated))
    // Newest first, so the delivery before the read.
    #expect(rows.map(\.guid) == ["MSG-0006", "MSG-0004"])
    let count = try await fixture.repository.updatedMessageCount(window)
    #expect(count == 2)
  }
}

//  MessageRepositoryTests
//  The read path against a real SQLite database.
//
//  This is the first test of the repository's SQL. Everything before it tested the layers
//  around the queries — serialization, timestamps, GUID parsing — while the queries
//  themselves were only ever exercised by hand against a live chat.db, which cannot be
//  asserted on and cannot run in CI.

import BBIMessage
import Foundation
import Testing

@Suite("MessageRepository")
struct MessageRepositoryTests {

  // MARK: - Messages

  @Test("returns messages newest first by default")
  func ordering() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let rows = try await fixture.repository.messages(.init())
    #expect(rows.count == 6)
    // Seeded offsets are 0, 30, 60, 90, 120, 300 seconds.
    #expect(
      rows.map(\.guid) == ["MSG-0005", "MSG-0003", "MSG-0006", "MSG-0002", "MSG-0004", "MSG-0001"])

    let ascending = try await fixture.repository.messages(.init(ascending: true))
    #expect(ascending.map(\.guid) == rows.map(\.guid).reversed())
  }

  @Test("scopes to a chat")
  func chatScope() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let guid = ChatDatabaseFixture.chatGUID(
      ChatDatabaseFixture.aliceAddress, service: "iMessage", macOS26: false
    )
    let rows = try await fixture.repository.messages(.init(chatGUID: guid))
    #expect(Set(rows.map(\.guid)) == ["MSG-0001", "MSG-0002", "MSG-0003"])
  }

  /// The macOS 26 migration rewrote every `chat.guid` to the `any;-;` form, historical rows
  /// included. A client that cached `iMessage;-;X` must still resolve the chat, or its
  /// entire history appears to vanish after an OS update.
  @Test("resolves a chat GUID across the macOS 26 prefix change")
  func guidTolerance() async throws {
    for databaseIsMacOS26 in [true, false] {
      let fixture = try await ChatDatabaseFixture(macOS26GUIDs: databaseIsMacOS26)
      defer { fixture.tearDown() }

      // Ask with BOTH spellings regardless of what the database holds.
      for clientSpelling in ["iMessage", "any"] {
        let guid = "\(clientSpelling);-;\(ChatDatabaseFixture.aliceAddress)"
        let rows = try await fixture.repository.messages(.init(chatGUID: guid))
        #expect(
          rows.count == 3,
          "asked for \(guid) against a \(databaseIsMacOS26 ? "macOS 26" : "legacy") database"
        )
      }
    }
  }

  @Test("filters by date window")
  func dateWindow() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // Strictly after +60 and strictly before +300 leaves the +90 and +120 messages.
    let rows = try await fixture.repository.messages(
      .init(
        after: base.addingTimeInterval(60), before: base.addingTimeInterval(300)
      ))
    #expect(Set(rows.map(\.guid)) == ["MSG-0006", "MSG-0003"])
  }

  @Test("paginates without overlap or gaps")
  func pagination() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    var seen: [String] = []
    for offset in stride(from: 0, to: 6, by: 2) {
      let page = try await fixture.repository.messages(.init(limit: 2, offset: offset))
      #expect(page.count == 2)
      seen += page.map(\.guid)
    }
    #expect(Set(seen).count == 6)
  }

  // MARK: - Counts
  //
  // The count and the listing share one predicate builder. These check they actually
  // agree, which is the bug the sharing exists to prevent.

  @Test("count agrees with the listing it counts")
  func countMatchesListing() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let queries: [MessageRepository.MessageQuery] = [
      .init(),
      .init(
        chatGUID: ChatDatabaseFixture.chatGUID(
          ChatDatabaseFixture.aliceAddress, service: "iMessage", macOS26: false)),
      .init(after: base.addingTimeInterval(60)),
      .init(before: base.addingTimeInterval(100)),
      .init(onlyFromMe: true),
    ]
    for query in queries {
      // limit is capped at 1000 and the fixture has 6 rows, so a full listing is one page.
      let listed = try await fixture.repository.messages(query).count
      let counted = try await fixture.repository.messageCount(query)
      #expect(listed == counted, "predicate disagreement")
    }
  }

  @Test("counts only what the account sent")
  func sentCount() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    // MSG-0002, MSG-0004, MSG-0005 are seeded is_from_me = 1.
    #expect(try await fixture.repository.messageCount(.init(onlyFromMe: true)) == 3)
    #expect(try await fixture.repository.messageCount() == 6)
  }

  /// The updated count filters on delivery and read timestamps, not on `date`. A receipt
  /// arriving today for a message sent last week moves `date_delivered` and leaves `date`
  /// alone — counting on `date` would miss exactly what this is asked for.
  @Test("updated count follows receipts, not creation")
  func updatedCount() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    // Every message is delivered 60s after its own date; the latest is at +300, so
    // +360 is the last delivery. Everything is after base.
    #expect(try await fixture.repository.updatedMessageCount(after: base) == 6)
    // After +240: only MSG-0005 (delivered at +360) qualifies.
    #expect(
      try await fixture.repository.updatedMessageCount(
        after: base.addingTimeInterval(240)
      ) == 1)
    #expect(
      try await fixture.repository.updatedMessageCount(
        after: base.addingTimeInterval(3600)
      ) == 0)
  }

  // MARK: - Chats

  /// Keyed by SERVICE NAME, which is what `GET /chat/count` puts under `breakdown`. It used
  /// to be keyed by style (43/45) — two different questions, and only one of them is the one
  /// clients ask.
  @Test("chat totals break down by service")
  func chatServices() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let counts = try await fixture.repository.chatCountsByService()
    // alice, the group and the empty chat are iMessage; carol is SMS. The orphan chat has
    // no participants and is counted nowhere.
    #expect(counts["iMessage"] == 3)
    #expect(counts["SMS"] == 1)
    #expect(counts.values.reduce(0, +) == 4)
  }

  /// A chat nobody is in is not a conversation, so it is excluded from the listing and from
  /// both counts — matching the reference, whose `getChats` inner-joins participants.
  ///
  /// Asserted on the LISTING as well as the count, because a total that disagrees with the
  /// rows it counts is the pagination bug this repository has a shared predicate to avoid.
  @Test("a chat with no participants is excluded everywhere")
  func participantlessChatsAreExcluded() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let listed = try await fixture.repository.chats()
    #expect(!listed.contains { $0.guid.contains("orphan") })
    #expect(try await fixture.repository.chatCount() == listed.count)
  }

  @Test("archived chats are excluded on request")
  func archived() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // Four chats have participants; the fifth is the orphan and never counts.
    #expect(try await fixture.repository.chatCount(includeArchived: true) == 4)
    #expect(try await fixture.repository.chatCount(includeArchived: false) == 3)
    let visible = try await fixture.repository.chats(includeArchived: false)
    #expect(!visible.contains { $0.guid.contains(ChatDatabaseFixture.carolAddress) })
  }

  /// The last-message sort uses a LEFT JOIN specifically so a chat with no messages is not
  /// dropped. An inner join here would silently lose the empty chat, and "my new
  /// conversation disappeared" is a report nobody would connect to a sort order.
  @Test("sorting by last message keeps empty chats")
  func lastMessageSort() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let sorted = try await fixture.repository.chats(sortByLastMessage: true)
    #expect(sorted.count == 4, "an empty chat was dropped by the join")

    // The group chat holds MSG-0005 at +300, the newest message anywhere.
    #expect(sorted.first?.chatIdentifier == "chat900001")
    // The empty chat has a NULL last date, which sorts last under DESC.
    #expect(sorted.last?.chatIdentifier == "empty@example.com")
  }

  @Test("finds one chat by GUID")
  func findChat() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let guid = ChatDatabaseFixture.chatGUID(
      ChatDatabaseFixture.aliceAddress, service: "iMessage", macOS26: false
    )
    let chat = try await fixture.repository.chat(guid: guid)
    #expect(chat?.chatIdentifier == ChatDatabaseFixture.aliceAddress)
    #expect(try await fixture.repository.chat(guid: "iMessage;-;nobody@example.com") == nil)
  }

  // MARK: - Handles and participants

  @Test("finds a handle by exact address")
  func handleLookup() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let handle = try await fixture.repository.handle(address: ChatDatabaseFixture.bobAddress)
    #expect(handle?.service == "iMessage")

    // Deliberately NOT a suffix match. `ser@example.com` is a suffix of
    // `user@example.com`, and matching it would resolve one person's address to
    // another's — the exact bug found in ContactIndex.
    #expect(try await fixture.repository.handle(address: "ser@example.com") == nil)
  }

  @Test("lists a handle's chats")
  func handleChats() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let alice = try #require(
      try await fixture.repository.handle(address: ChatDatabaseFixture.aliceAddress)
    )
    let chats = try await fixture.repository.chats(forHandleRowID: alice.rowID)
    // alice is in the direct chat and the group.
    #expect(chats.count == 2)
  }

  @Test("lists participants of a chat")
  func participants() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let group = ChatDatabaseFixture.chatGUID("chat900001", service: "iMessage", macOS26: false)
    let people = try await fixture.repository.participants(chatGUID: group)
    #expect(
      Set(people.map(\.id)) == [
        ChatDatabaseFixture.aliceAddress, ChatDatabaseFixture.bobAddress,
      ])
  }

  // MARK: - Attachments

  @Test("finds an attachment and its message")
  func attachments() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    #expect(try await fixture.repository.attachmentCount() == 1)
    let attachment = try await fixture.repository.attachment(guid: "ATT-0001")
    #expect(attachment?.mimeType == "image/jpeg")
    #expect(attachment?.totalBytes == 2048)

    let onMessage = try await fixture.repository.attachments(forMessageGUID: "MSG-0003")
    #expect(onMessage.map(\.guid) == ["ATT-0001"])
    #expect(try await fixture.repository.attachments(forMessageGUID: "MSG-0001").isEmpty)
  }

  @Test("lists the chats a message belongs to")
  func messageChats() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let chats = try await fixture.repository.chats(forMessageGUID: "MSG-0004")
    #expect(chats.map(\.chatIdentifier) == ["chat900001"])
  }
}

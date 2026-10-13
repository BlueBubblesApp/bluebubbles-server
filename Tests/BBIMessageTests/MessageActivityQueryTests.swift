//  MessageActivityQueryTests
//  The counts behind Home's message-flow charts, against a real SQLite database.
//
//  Rows AND totals, per the rule for `/message/query` filters: a chart that draws the right
//  shape from the wrong rows looks exactly like a correct one.

import BBIMessage
import Foundation
import Testing

@Suite("Message activity queries")
struct MessageActivityQueryTests {

  /// The seed's messages sit between 22:13:20 and 22:18:20 UTC on this day.
  private static let base = Date(timeIntervalSince1970: 1_700_000_000)
  private static let dayStart = Date(timeIntervalSince1970: 1_699_920_000)  // 2023-11-14 UTC
  private static let dayEnd = dayStart.addingTimeInterval(86_400)

  private static func day(offset: Int = 0) -> MessageRepository.ActivityDay {
    .init(start: dayStart, end: dayEnd, utcOffset: offset)
  }

  @Test("Every seeded message is counted once, split by direction, in its UTC hour")
  func countsTheSeed() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let cells = try await fixture.repository.messageActivity(days: [Self.day()])
    #expect(
      Set(cells.map { "\($0.day)/\($0.hour)/\($0.isFromMe)/\($0.service)/\($0.count)" }) == [
        "0/22/true/iMessage/3", "0/22/false/iMessage/3",
      ])
    #expect(cells.reduce(0) { $0 + $1.count } == 6)
  }

  @Test("The day's offset moves a message into its local hour, not its UTC one")
  func offsetPlacesTheHour() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // +05:30. 22:13 UTC is 03:43 local; a zone with a half-hour offset is the one that
    // would catch a query rounding the offset to whole hours.
    let cells = try await fixture.repository.messageActivity(days: [Self.day(offset: 19_800)])
    #expect(Set(cells.map(\.hour)) == [3])
    #expect(cells.reduce(0) { $0 + $1.count } == 6)
  }

  @Test("Start is inclusive, end is exclusive, and a tapback is not a message")
  func boundariesAndTapbacks() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    try await fixture.insertMessage(guid: "AT-START", at: Self.dayStart)
    try await fixture.insertMessage(guid: "AT-END", at: Self.dayEnd)
    try await fixture.insertMessage(
      guid: "TAPBACK", at: Self.base.addingTimeInterval(10), associatedMessageType: 2000)

    let cells = try await fixture.repository.messageActivity(days: [Self.day()])
    #expect(cells.reduce(0) { $0 + $1.count } == 7)
    #expect(cells.first { $0.hour == 0 }?.count == 1)
  }

  @Test("Each service is its own cell")
  func splitsByService() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    try await fixture.insertMessage(
      guid: "SMS-1", at: Self.base.addingTimeInterval(20), handle: 3, chat: 3, service: "SMS")

    let cells = try await fixture.repository.messageActivity(days: [Self.day()])
    #expect(cells.filter { $0.service == "SMS" }.map(\.count) == [1])
    #expect(cells.filter { $0.service == "iMessage" }.reduce(0) { $0 + $1.count } == 6)
  }

  @Test("Several days are counted into their own index, and empty ones produce no cells")
  func severalDays() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let before = MessageRepository.ActivityDay(
      start: Self.dayStart.addingTimeInterval(-86_400), end: Self.dayStart, utcOffset: 0)
    let cells = try await fixture.repository.messageActivity(days: [before, Self.day()])
    #expect(Set(cells.map(\.day)) == [1])
  }

  @Test("The busiest chats come back busiest first, with their participants")
  func busiestChats() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let chats = try await fixture.repository.busiestChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 2)
    #expect(chats.map(\.count) == [3, 2])
    #expect(chats.first?.participants == [ChatDatabaseFixture.aliceAddress])
    #expect(chats.last?.displayName == "Team")
    #expect(chats.last?.isGroup == true)
  }

  @Test("One conversation under two service prefixes is one entry with both counts")
  func mergesPrefixSpellings() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let second = try await fixture.insertChat(
      guid: "SMS;-;\(ChatDatabaseFixture.aliceAddress)", participant: 1)
    try await fixture.insertMessage(
      guid: "SMS-ALICE", at: Self.base.addingTimeInterval(5), chat: Int(second))

    let chats = try await fixture.repository.busiestChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 3)
    #expect(chats.map(\.count) == [4, 2, 1])
    #expect(chats.first?.participants == [ChatDatabaseFixture.aliceAddress])
  }

  @Test("A twin's empty display name is no name, in both window queries")
  func emptyTwinNameIsNoName() async throws {
    // Alice's chat has a NULL name and its twin stores `''`. An empty name is read as none
    // before the merge, so the merge falls through to nil rather than adopting `''`: a
    // merge that took the twin's value as stored would answer `""` here.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let twin = try await fixture.insertChat(
      guid: "SMS;-;\(ChatDatabaseFixture.aliceAddress)", participant: 1, displayName: "")
    try await fixture.insertMessage(
      guid: "SMS-ALICE", at: Self.base.addingTimeInterval(5), chat: Int(twin))

    let busiest = try await fixture.repository.busiestChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 3)
    let alice = try #require(busiest.first { $0.chatRowID == 1 })
    #expect(alice.count == 4)
    #expect(alice.displayName == nil)

    let new = try await fixture.repository.newChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 5)
    let aliceNew = try #require(new.first { $0.chatRowID == 1 })
    #expect(aliceNew.count == 4)
    #expect(aliceNew.displayName == nil)
  }

  @Test("A twin's name fills an unnamed conversation")
  func twinNameFillsTheGap() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let twin = try await fixture.insertChat(
      guid: "SMS;-;\(ChatDatabaseFixture.aliceAddress)", participant: 1, displayName: "Al")
    try await fixture.insertMessage(
      guid: "SMS-ALICE", at: Self.base.addingTimeInterval(5), chat: Int(twin))

    let busiest = try await fixture.repository.busiestChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 3)
    #expect(busiest.first { $0.chatRowID == 1 }?.displayName == "Al")
    let new = try await fixture.repository.newChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 5)
    #expect(new.first { $0.chatRowID == 1 }?.displayName == "Al")
  }

  @Test("A conversation is new when nothing in it predates the window, newest first")
  func newChats() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // Every seeded chat begins on the seed day, so a window covering the whole day lists
    // them all: carol (+90s), the group (+30s), alice (+0s).
    let whole = try await fixture.repository.newChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 5)
    #expect(whole.map(\.chatRowID) == [3, 2, 1])
    #expect(whole.map(\.count) == [1, 2, 3])
    #expect(whole.first?.started == Self.base.addingTimeInterval(90))
    #expect(whole.last?.participants == [ChatDatabaseFixture.aliceAddress])
    #expect(whole[1].displayName == "Team")
    #expect(whole[1].isGroup == true)

    // A window opening at +50s: alice and the group have earlier messages, so only carol
    // began inside it. Alice is still ACTIVE in the window, which is what an unmerged
    // "first message in range" would have mistaken for new.
    let later = try await fixture.repository.newChats(
      from: Self.base.addingTimeInterval(50), to: Self.dayEnd, limit: 5)
    #expect(later.map(\.chatRowID) == [3])

    // The limit applies after the newest-first sort.
    let one = try await fixture.repository.newChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 1)
    #expect(one.map(\.chatRowID) == [3])
  }

  @Test("An old conversation's new service twin is not a new conversation")
  func newChatsMergeTwins() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // Alice's iMessage chat has messages from +0s. Her SMS twin appears at +200s.
    let twin = try await fixture.insertChat(
      guid: "SMS;-;\(ChatDatabaseFixture.aliceAddress)", participant: 1)
    try await fixture.insertMessage(
      guid: "SMS-ALICE", at: Self.base.addingTimeInterval(200), chat: Int(twin))

    let later = try await fixture.repository.newChats(
      from: Self.base.addingTimeInterval(150), to: Self.dayEnd, limit: 5)
    #expect(later.isEmpty)

    // With the whole day in the window the pair is ONE new conversation, counted together.
    let whole = try await fixture.repository.newChats(
      from: Self.dayStart, to: Self.dayEnd, limit: 5)
    #expect(whole.map(\.chatRowID) == [3, 2, 1])
    #expect(whole.last?.count == 4)
  }

  @Test("A tapback does not begin a conversation")
  func newChatsIgnoreTapbacks() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // A tapback on carol's chat before the window, then her only message inside it.
    try await fixture.insertMessage(
      guid: "TAPBACK-EARLY", at: Self.base.addingTimeInterval(-3_600), chat: 3,
      associatedMessageType: 2000)
    let later = try await fixture.repository.newChats(
      from: Self.base.addingTimeInterval(50), to: Self.dayEnd, limit: 5)
    #expect(later.map(\.chatRowID) == [3])
  }
}

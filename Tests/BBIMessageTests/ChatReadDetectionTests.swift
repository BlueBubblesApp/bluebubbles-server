//  ChatReadDetectionTests
//  `chat-read-status-changed` is detected from `chat.last_read_message_timestamp`.
//
//  Nothing else reports a chat being read, so a read the detector misses is a badge that never
//  clears on the client, and a read it invents is one cleared that should not have been. Both
//  directions are pinned here: what moves the column must be announced once, and what only
//  LOOKS new to a window — the baseline, a reconcile pass, a clock stepped backwards — must
//  not be announced at all.
//
//  Driven through `tick(now:)`, like `ChangeDetectorTests`, so time is a parameter.

import BBCore
import Foundation
import Testing

@testable import BBIMessage

@Suite("Chat read detection", .serialized)
struct ChatReadDetectionTests {

  private static let now = Date(timeIntervalSince1970: 1_700_010_000)
  /// The seed's direct chat with alice, and its group chat.
  private static let directChat: Int64 = 1
  private static let groupChat: Int64 = 2

  private func detector(_ fixture: ChatDatabaseFixture) -> ChangeDetector {
    ChangeDetector(repository: fixture.repository, startingFrom: Self.now)
  }

  @Test("A chat read after the baseline is announced once, with the GUID chat.db stores")
  func readIsAnnouncedOnce() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(1))
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(2))

    #expect(batch.chatReads.map(\.rowID) == [Self.directChat])
    #expect(
      batch.chatReads.first?.guid
        == ChatDatabaseFixture.chatGUID(ChatDatabaseFixture.aliceAddress))
    #expect(batch.messages.isEmpty, "a read is not a message change")
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(3)).chatReads.isEmpty)
  }

  @Test("A chat read before startup is history, not news")
  func baselineIsSilent() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(-60))
    let detector = detector(fixture)

    #expect(try await detector.tick(now: Self.now).isEmpty)
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(2)).chatReads.isEmpty)
  }

  @Test("Reading a chat again is announced again")
  func secondReadIsAnnounced() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(-60))
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(5))
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(6))
    #expect(batch.chatReads.map(\.rowID) == [Self.directChat])
  }

  @Test("A read time that goes backwards is not a read, and the higher one still counts")
  func backwardsIsNotARead() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(10))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(11)).chatReads.count == 1)

    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(5))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(12)).chatReads.isEmpty)

    // Past the earlier value, not merely past the lowered one.
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(8))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(13)).chatReads.isEmpty)
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(14))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(15)).chatReads.count == 1)
  }

  @Test("Two chats read in one tick are both announced, oldest read first")
  func severalReadsInOneTick() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    try await fixture.markChatRead(rowID: Self.groupChat, at: Self.now.addingTimeInterval(3))
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(1))
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(4))
    #expect(batch.chatReads.map(\.rowID) == [Self.directChat, Self.groupChat])
  }

  /// The reconcile pass widens the MESSAGE window to seven days. If the chat window widened
  /// with it, every chat read this week but not in the last half hour would be offered with
  /// no ledger entry, and announced as a read that just happened. The floor that never falls
  /// is what prevents it, as it prevents the stepped clock below.
  @Test("The reconcile pass does not re-announce chats read earlier in the week")
  func reconcileDoesNotReplayTheWeek() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(
      rowID: Self.directChat, at: Self.now.addingTimeInterval(-2 * 86_400))
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    // A commit, so the next pass past the interval is a reconcile.
    try await fixture.insertMessage(guid: "AFTER-BASELINE", at: Self.now.addingTimeInterval(1))
    let reconcilesBefore = await detector.reconcileCount
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(400))

    #expect(await detector.reconcileCount == reconcilesBefore + 1, "not a reconcile pass")
    #expect(batch.chatReads.isEmpty)
  }

  /// The ledger forgets a chat once its read falls below the window, and is safe to only
  /// because the window's floor never falls. A wall clock stepped back would drop it, and a
  /// chat the ledger had forgotten would come back looking unseen.
  @Test("A clock stepped backwards does not re-announce a forgotten read")
  func backwardsClockDoesNotReplay() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(-600))
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    // An hour on. A window's floor trails the previous tick, so it is the tick after this
    // one that leaves the read behind and forgets it.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(3600))
    // Back to the start: this tick forgets the read, and the one after it is the first whose
    // window would reach it again.
    _ = try await detector.tick(now: Self.now)
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(1))
    #expect(batch.chatReads.isEmpty)
  }

  @Test("A chat that falls out of the window and is read again is announced")
  func forgottenChatReadAgain() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(-60))
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)
    // Two ticks: a window's floor trails the PREVIOUS tick, so the second is the one whose
    // window has left the read behind.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(3600))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(7200))

    try await fixture.markChatRead(
      rowID: Self.directChat, at: Self.now.addingTimeInterval(7201))
    let batch = try await detector.tick(now: Self.now.addingTimeInterval(7202))
    #expect(batch.chatReads.map(\.rowID) == [Self.directChat])
  }

  @Test("The chat-read query reads three columns, past the floor, oldest read first")
  func queryShape() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.markChatRead(rowID: Self.groupChat, at: Self.now.addingTimeInterval(-10))
    try await fixture.markChatRead(rowID: Self.directChat, at: Self.now.addingTimeInterval(-20))
    try await fixture.markChatRead(rowID: 3, at: Self.now.addingTimeInterval(-7200))

    let marks = try await fixture.repository.chatReadMarks(
      readAfter: Self.now.addingTimeInterval(-60))
    #expect(marks.map(\.rowID) == [Self.directChat, Self.groupChat])
    #expect(
      marks.first?.lastRead.rawValue
        == ChatDatabaseFixture.nanoseconds(Self.now.addingTimeInterval(-20)))

    let sql = try #require(fixture.repository.chatReadQuery(readAfter: Self.now)).sql
    #expect(!sql.contains("properties"), "the chat row's blob is not what is compared")
    #expect(!sql.contains("*"))
  }
}

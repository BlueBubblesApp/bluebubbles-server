//  ChatJoinHoldTests
//  A new message is not announced until its `chat_message_join` row exists.
//
//  These tests write in the order Messages does, measured against live sends: the message row
//  in one commit, then the join in a later one. `ChatDatabaseFixture.insertMessage` commits
//  both at once by default, which is why the rest of the detector's suite could never see the
//  gap. A real send through a server without this hold went out as `new-message` with
//  `chats: []`, and the client's handler reads `chats.first` without checking.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Holding a message until it reaches a chat", .serialized, .removingChatDBCopies)
struct ChatJoinHoldTests {

  private static let now = Date(timeIntervalSince1970: 1_700_010_000)

  private func at(_ seconds: TimeInterval) -> Date { Self.now.addingTimeInterval(seconds) }

  /// A detector past its silent first pass, so whatever a test writes next is news.
  private func baselined(
    _ fixture: ChatDatabaseFixture,
    configuration: ChangeDetectorConfiguration = ChangeDetectorConfiguration()
  ) async throws -> ChangeDetector {
    let detector = ChangeDetector(
      repository: fixture.repository, configuration: configuration, startingFrom: Self.now)
    _ = try await detector.tick(now: Self.now)
    return detector
  }

  // MARK: - The gap

  @Test("A message row with no chat yet is held, then announced once when the join lands")
  func joinAfterTheRow() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "GAP", at: at(1), joinedToChat: false)
    #expect(try await fixture.repository.chats(forMessageGUID: "GAP").isEmpty)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1)

    try await fixture.joinToChat(guid: "GAP")
    let changes = try await detector.tick(now: at(2)).messages

    #expect(changes.map(\.message.guid) == ["GAP"])
    #expect(changes.first?.isNew == true)
    #expect(try await fixture.repository.chats(forMessageGUID: "GAP").count == 1)
    #expect(await detector.heldArrivalCount == 0)
    // Once. The fingerprint and the mark both already have it.
    #expect(try await detector.tick(now: at(3)).messages.isEmpty)
    #expect(try await detector.tick(now: at(400)).messages.isEmpty)
  }

  /// The attachment link was measured landing between the two, so what the hold waits for is
  /// also what makes the attachments complete. Announcing on the row alone sent both short.
  @Test("An attachment linked before the join is in place when the message is released")
  func attachmentLinkBeforeTheJoin() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "STICKER", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)

    try await fixture.linkAttachment(guid: "STICKER")
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1)

    try await fixture.joinToChat(guid: "STICKER")
    let changes = try await detector.tick(now: at(3)).messages

    #expect(changes.map(\.message.guid) == ["STICKER"])
    #expect(try await fixture.repository.attachments(forMessageGUID: "STICKER").count == 1)
  }

  // MARK: - Nothing else waits, and the mark stays honest

  @Test("A held row does not stall the rows behind it, and the mark moves past it")
  func laterRowsAreNotStalled() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "SLOW", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    let slowMark = await detector.highWaterRowID

    try await fixture.insertMessage(guid: "FAST", at: at(2))
    let first = try await detector.tick(now: at(2)).messages
    #expect(first.map(\.message.guid) == ["FAST"])
    let fastMark = await detector.highWaterRowID
    #expect(fastMark > slowMark, "the mark must move over a held row, not wait behind it")

    try await fixture.joinToChat(guid: "SLOW")
    let second = try await detector.tick(now: at(3)).messages
    #expect(second.map(\.message.guid) == ["SLOW"])
    #expect(second.first?.isNew == true)
    #expect(await detector.highWaterRowID == fastMark, "a release must not move the mark back")
    #expect(try await detector.tick(now: at(4)).messages.isEmpty, "neither is announced again")
  }

  @Test("A receipt on a held row is carried by its new-message, not announced ahead of it")
  func receiptWhileHeld() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "EARLY-READ", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)

    try await fixture.markRead(guid: "EARLY-READ", at: at(2))
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)

    try await fixture.joinToChat(guid: "EARLY-READ")
    let changes = try await detector.tick(now: at(3)).messages
    #expect(changes.count == 1)
    #expect(changes.first?.isNew == true)
    #expect(changes.first?.message.dateRead != nil)
    #expect(try await detector.tick(now: at(4)).messages.isEmpty, "the receipt is not said twice")
  }

  /// A live send that failed inside the gap lost its `message-send-error` to an earlier
  /// version of this hold, which treated the error as one more field the row would carry.
  @Test("A send that fails while held reports the failure after its new-message")
  func failureWhileHeld() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "FAILS", at: at(1), fromMe: true, joinedToChat: false)
    try await fixture.insertMessage(guid: "AFTER", at: at(1.5), fromMe: true, joinedToChat: false)
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)

    try await fixture.setError(guid: "FAILS", to: 22)
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)

    try await fixture.joinToChat(guid: "FAILS")
    try await fixture.joinToChat(guid: "AFTER")
    let changes = try await detector.tick(now: at(3)).messages

    #expect(changes.map(\.message.guid) == ["FAILS", "FAILS", "AFTER"])
    #expect(changes.map(\.isNew) == [true, false, true])
    #expect(changes[1].changedFields == [.error])
    #expect(changes[1].message.error == 22)
    #expect(try await detector.tick(now: at(4)).messages.isEmpty, "the failure is said once")
  }

  // MARK: - The bound

  @Test("A row that never reaches a chat is given up on, and is not announced after that")
  func neverGetsAChat() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumHold: .seconds(60)))

    try await fixture.insertMessage(guid: "ORPHAN", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    #expect(try await detector.tick(now: at(60)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1, "inside the bound it is still waiting")

    #expect(try await detector.tick(now: at(61)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0)

    // Too late to be news, and not a re-announce either.
    try await fixture.joinToChat(guid: "ORPHAN")
    #expect(try await detector.tick(now: at(62)).messages.isEmpty)

    // Still cached: with a chat to name, a receipt on it is an ordinary update.
    try await fixture.markRead(guid: "ORPHAN", at: at(63))
    let later = try await detector.tick(now: at(64)).messages
    #expect(later.map(\.message.guid) == ["ORPHAN"])
    #expect(later.first?.isNew == false)
    #expect(later.first?.changedFields == [.read])
  }

  /// Where the backup pass is the only signal, ticks are thirty seconds apart or more, and a
  /// Mac can sleep between two. Expiring first would discard a message that is fine.
  @Test("A join found on a tick past the bound still releases the message")
  func joinIsCheckedBeforeTheBound() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumHold: .seconds(60)))

    try await fixture.insertMessage(guid: "LATE-TICK", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    try await fixture.joinToChat(guid: "LATE-TICK")

    let changes = try await detector.tick(now: at(600)).messages
    #expect(changes.map(\.message.guid) == ["LATE-TICK"])
    #expect(changes.first?.isNew == true)
  }

  // MARK: - Chatless rows that are not new

  @Test("A row with no chat is neither held at the baseline nor updated afterwards")
  func chatlessHistory() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.insertMessage(guid: "OLD-ORPHAN", at: at(-60), joinedToChat: false)
    let detector = try await baselined(fixture)
    #expect(await detector.heldArrivalCount == 0, "what is there at startup is history")

    // `updated-message` reads `chats.first` as well, and this row has none to name.
    try await fixture.markRead(guid: "OLD-ORPHAN", at: at(1))
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0, "an update is dropped, not held as if new")
  }

  // MARK: - What bounds the hold

  @Test("A burst above the cap is cached rather than held, whether or not it has chats")
  func burstIsNotHeld() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumAnnouncedPerTick: 3))

    for index in 0..<4 {
      try await fixture.insertMessage(
        guid: "BURST-\(index)", at: at(Double(index) + 1), joinedToChat: false)
    }
    #expect(try await detector.tick(now: at(5)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0)

    try await fixture.joinToChat(guid: "BURST-0")
    #expect(try await detector.tick(now: at(6)).messages.isEmpty, "demoted to history for good")
  }

  @Test("What is held counts toward the cap, so the hold cannot outgrow it")
  func heldCountsTowardTheCap() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumAnnouncedPerTick: 3))

    for index in 0..<3 {
      try await fixture.insertMessage(
        guid: "STEP-\(index)", at: at(Double(index) + 1), joinedToChat: false)
      #expect(try await detector.tick(now: at(Double(index) + 1)).messages.isEmpty)
    }
    #expect(await detector.heldArrivalCount == 3, "at the cap, not over it")

    try await fixture.insertMessage(guid: "STEP-3", at: at(4), joinedToChat: false)
    #expect(try await detector.tick(now: at(4)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0)
  }

  @Test("A chat.db whose ROWIDs went backwards forgets what it was holding")
  func rebaselineClearsTheHold() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "HELD", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1)

    await detector.setHighWater(9_000_000)
    try await fixture.insertMessage(guid: "AFTER", at: at(400))
    _ = try await detector.tick(now: at(400))
    #expect(await detector.highWaterRowID < 9_000_000, "the guard has to have run")
    #expect(await detector.heldArrivalCount == 0, "its ROWIDs name other rows in a new file")
  }

  // MARK: - A failed read

  /// `compare` has cached the row and the mark has moved by the time this read runs, so
  /// failing the tick here would lose the message for good.
  @Test("A failed read of the join table holds new rows and still reports updates")
  func failedReadLosesNothing() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.insertMessage(guid: "OLDER", at: at(-60))
    let detector = try await baselined(fixture)

    try await fixture.dropChatJoinTable()
    try await fixture.insertMessage(guid: "UNREADABLE", at: at(1), joinedToChat: false)
    try await fixture.markRead(guid: "OLDER", at: at(1))
    let during = try await detector.tick(now: at(2)).messages
    #expect(during.map(\.message.guid) == ["OLDER"])
    #expect(during.first?.isNew == false)
    #expect(await detector.heldArrivalCount == 1)

    try await fixture.restoreChatJoinTable()
    try await fixture.joinToChat(guid: "UNREADABLE")
    let after = try await detector.tick(now: at(3)).messages
    #expect(after.map(\.message.guid) == ["UNREADABLE"])
    #expect(after.first?.isNew == true)
  }

  /// The same reasoning one read later: everything has been cached by the time the rows are
  /// fetched, so this used to throw the batch away and the chat reads with it.
  @Test("A failed read of the rows keeps new messages, and each is announced once it recovers")
  func failedHydrationKeepsNewMessages() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "RETRIED", at: at(1))
    try await fixture.breakMessageHydration()
    let during = try await detector.tick(now: at(1)).messages
    #expect(during.isEmpty)
    #expect(await detector.heldArrivalCount == 1)

    try await fixture.restoreMessageHydration()
    let after = try await detector.tick(now: at(2)).messages
    #expect(after.map(\.message.guid) == ["RETRIED"])
    #expect(after.first?.isNew == true)
    #expect(await detector.heldArrivalCount == 0)
    #expect(try await detector.tick(now: at(3)).messages.isEmpty, "once")
  }

  /// Holding afresh after each failed read would restart the clock, and with reads that never
  /// recover the row would be retried for as long as the server ran.
  @Test("A read that never recovers gives up at the bound, counted from the first hold")
  func failedHydrationHasATimeLimit() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumHold: .seconds(60)))

    try await fixture.insertMessage(guid: "STUCK", at: at(1))
    try await fixture.breakMessageHydration()
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    #expect(try await detector.tick(now: at(30)).messages.isEmpty)
    #expect(try await detector.tick(now: at(60)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1, "inside the bound it is still being retried")

    #expect(try await detector.tick(now: at(61)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0)

    try await fixture.restoreMessageHydration()
    #expect(try await detector.tick(now: at(62)).messages.isEmpty, "given up on is for good")
  }

  @Test("A failed read of the join table gives up at the bound too")
  func failedJoinReadHasATimeLimit() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(
      fixture, configuration: ChangeDetectorConfiguration(maximumHold: .seconds(60)))

    try await fixture.dropChatJoinTable()
    try await fixture.insertMessage(guid: "NO-JOIN-TABLE", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 1)
    #expect(try await detector.tick(now: at(61)).messages.isEmpty)
    #expect(await detector.heldArrivalCount == 0)
  }

  /// A failed send's event is told apart only by the hold, so the retry must not forget it.
  @Test("A failed send on a held row survives a failed read of the rows")
  func failedHydrationKeepsTheFailedSend() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = try await baselined(fixture)

    try await fixture.insertMessage(guid: "FAILS", at: at(1), joinedToChat: false)
    #expect(try await detector.tick(now: at(1)).messages.isEmpty)

    try await fixture.setError(guid: "FAILS", to: 22)
    try await fixture.joinToChat(guid: "FAILS")
    try await fixture.breakMessageHydration()
    #expect(try await detector.tick(now: at(2)).messages.isEmpty)

    try await fixture.restoreMessageHydration()
    let after = try await detector.tick(now: at(3)).messages
    #expect(after.map(\.isNew) == [true, false])
    #expect(after.last?.changedFields == [.error])
  }

  // MARK: - Through the stream

  /// The join's own commit is what has to wake the detector, or the message waits out the
  /// backup pass. The clock moves past the floor and never near the backup interval: at a step
  /// of 500ms every 100ms, the two waits take six seconds of real time to get there.
  @Test("Through a real watcher, the join's commit releases the message without the backup")
  func streamReleasesOnTheJoinsCommit() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let clock = TestClock()
    let floor = Duration.milliseconds(500)
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(pollInterval: floor, backupInterval: .seconds(30)),
      clock: clock)
    let stream = await detector.changes(watching: fixture.path)
    let received = Locked<[MessageChange]>([])
    let drain = Task {
      for await batch in stream { received.withLock { $0.append(contentsOf: batch.messages) } }
    }
    defer { drain.cancel() }
    try await clock.waitForSleepers(2)
    clock.advance(by: floor)

    try await fixture.insertMessage(guid: "VIA-JOIN", at: Date(), joinedToChat: false)
    try await waitUntil("the row to be held", interval: .milliseconds(100)) {
      clock.advance(by: floor)
      return await detector.heldArrivalCount == 1
    }
    #expect(received.value.isEmpty)

    try await fixture.joinToChat(guid: "VIA-JOIN")
    try await waitUntil("the join to release it", interval: .milliseconds(100)) {
      clock.advance(by: floor)
      return !received.value.isEmpty
    }
    await detector.stop()

    #expect(received.value.map(\.message.guid) == ["VIA-JOIN"])
    #expect(received.value.first?.isNew == true)
    #expect(clock.now.offset < .seconds(30), "the backup interval was reached")
  }

  // MARK: - What it costs

  /// Runs on every tick that found a change, so it may not scan. Asked of Apple's schemas: the
  /// synthetic fixture's join table has only its primary key.
  @Test(
    "The gate reads Apple's message-id index and touches nothing else",
    arguments: CommittedChatDB.Release.allCases)
  func gatePlan(release: CommittedChatDB.Release) async throws {
    let database = try ReadOnlyDatabase(path: CommittedChatDB.copy(release).path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)

    let (sql, arguments) = repository.chatJoinQuery(rowIDs: [1, 2, 3])
    let plan = try await database.explainQueryPlan(
      sql: sql, arguments: StatementArguments(arguments))
    #expect(
      plan.contains { $0.contains("COVERING INDEX chat_message_join_idx_message_id_only") },
      "\(plan)")
    #expect(!plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
  }

  @Test("The gate answers per row, and a chunked list is not cut short")
  func gateAnswers() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await fixture.insertMessage(guid: "IN", at: at(1))
    try await fixture.insertMessage(guid: "OUT", at: at(2), joinedToChat: false)
    let rows = try await fixture.repository.messageFingerprints(after: at(0), limit: 10)
    let rowIn = try #require(rows.first { $0.guid == "IN" }).rowID
    let rowOut = try #require(rows.first { $0.guid == "OUT" }).rowID

    #expect(try await fixture.repository.messageRowIDsWithChat(among: []).isEmpty)
    #expect(
      try await fixture.repository.messageRowIDsWithChat(among: [rowIn, rowOut]) == [rowIn])
    // Past one chunk, with the row that matches on the far side of the boundary.
    let padding = (0..<Int64(2000)).map { 10_000_000 + $0 }
    #expect(
      try await fixture.repository.messageRowIDsWithChat(among: padding + [rowIn]) == [rowIn])
  }
}

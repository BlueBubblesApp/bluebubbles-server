//  ChangeDetectorTests
//  The component with the least margin for error and, until now, no tests.
//
//  Everything a client sees arrives through here: a message the detector misses is a message
//  that never reaches a phone, and nothing reports it. The failure is silent by construction,
//  which is exactly why it needs tests that move the database underneath a running detector
//  rather than tests that check the diffing function in isolation.
//
//  Driven through `tick(now:)` rather than the stream, so time is a parameter instead of a
//  sleep. The few tests of the stream itself hand the detector a `TestClock` and advance it,
//  so its backup timer and floor cost no wall-clock time either.

import BBCore
import BBIMessage
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Change detection", .serialized)
struct ChangeDetectorTests {

  /// Well after the fixture's seeded messages, so a test starts from a quiet database.
  private static let now = Date(timeIntervalSince1970: 1_700_010_000)

  private func detector(
    _ fixture: ChatDatabaseFixture,
    configuration: ChangeDetectorConfiguration = ChangeDetectorConfiguration(),
    startingFrom: Date = ChangeDetectorTests.now,
    maximumAnnouncedPerTick: Int? = nil
  ) -> ChangeDetector {
    var configuration = configuration
    if let maximumAnnouncedPerTick {
      configuration.maximumAnnouncedPerTick = maximumAnnouncedPerTick
    }
    return makeDetector(fixture, configuration, startingFrom)
  }

  private func makeDetector(
    _ fixture: ChatDatabaseFixture,
    _ configuration: ChangeDetectorConfiguration,
    _ startingFrom: Date
  ) -> ChangeDetector {
    ChangeDetector(
      repository: fixture.repository,
      configuration: configuration,
      startingFrom: startingFrom
    )
  }

  // MARK: - New messages

  @Test("A message written after the cursor is reported as new")
  func newMessageIsDetected() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    // First tick establishes the baseline; everything already in the file is old.
    _ = try await detector.tick(now: Self.now).messages

    try await fixture.insertMessage(guid: "NEW-1", at: Self.now.addingTimeInterval(1))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(2)).messages

    #expect(changes.count == 1)
    #expect(changes.first?.message.guid == "NEW-1")
    #expect(changes.first?.isNew == true)
  }

  @Test("A message is announced once, not on every tick")
  func newMessageIsNotRepeated() async throws {
    // The lookback deliberately reaches back past the cursor to catch updates, so most
    // of what each tick returns is old. Re-announcing it would send every recent message
    // to every client once a second.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now).messages

    try await fixture.insertMessage(guid: "NEW-1", at: Self.now.addingTimeInterval(1))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(2)).messages.count == 1)
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(3)).messages.isEmpty)
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(4)).messages.isEmpty)
  }

  @Test("Messages already in the database on startup are not replayed")
  func existingMessagesAreNotReplayed() async throws {
    // Otherwise every restart floods every connected client with the last half hour.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    let changes = try await detector.tick(now: Self.now).messages
    #expect(changes.isEmpty)
  }

  // MARK: - Updates

  @Test("A read receipt on an existing message is reported as an update")
  func readReceiptIsDetected() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    try await fixture.insertMessage(guid: "MSG-R", at: Self.now.addingTimeInterval(1))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(2)).messages

    try await fixture.markRead(guid: "MSG-R", at: Self.now.addingTimeInterval(3))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(4)).messages

    #expect(changes.count == 1)
    #expect(changes.first?.isNew == false)
    #expect(changes.first?.changedFields == [.read])
  }

  @Test("A receipt on a message older than the fast window is caught by the reconcile pass")
  func reconcileCatchesOlderReceipts() async throws {
    // The reason the dual lookback exists. The fast pass only looks back 30 minutes;
    // read receipts arrive on much older messages, and only the wide pass sees them.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    // Two hours old: outside the 30-minute fast window, inside the 7-day wide one.
    let old = Self.now.addingTimeInterval(-7200)
    try await fixture.insertMessage(guid: "MSG-OLD", at: old)

    // A reconcile tick to take the baseline, then far enough ahead for another.
    _ = try await detector.tick(now: Self.now).messages
    try await fixture.markRead(guid: "MSG-OLD", at: Self.now)

    // A fast tick cannot see it.
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(10)).messages.isEmpty)

    // The reconcile tick can.
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(400)).messages
    #expect(changes.contains { $0.message.guid == "MSG-OLD" && $0.changedFields == [.read] })
  }

  /// THE regression this suite was written for.
  ///
  /// `MessageQuery` caps `limit` at 1000 and the detector took a single ASCENDING page, so
  /// a window holding more than 1000 messages was only ever examined from its oldest end.
  /// On any account with more than a thousand messages a week, the seven-day reconcile pass
  /// therefore never reached anything recent, and receipts on messages between 30 minutes
  /// and 7 days old silently stopped being detected, on the busiest accounts first.
  @Test("A window larger than one page is examined to its end")
  func windowLargerThanOnePageIsPaged() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // Just over one page, all inside the fast window so a single tick must see them all.
    let count = ChangeDetector.pageSize + 25
    let start = Self.now.addingTimeInterval(-600)
    // A detector whose cursor predates the bulk, baselined before it lands, so every one
    // of them is new to the tick under test.
    //
    // The burst cap is lifted here deliberately. This test's subject is PAGING — that a
    // window wider than one page is walked to its end — and 1,025 messages at once would
    // otherwise be demoted to history by the sync rule, which has its own test. Leaving the
    // cap in would make a paging regression and a working cap look identical.
    let detector = detector(
      fixture, startingFrom: start.addingTimeInterval(-1),
      maximumAnnouncedPerTick: count + 1)
    _ = try await detector.tick(now: start.addingTimeInterval(-1)).messages
    for index in 0..<count {
      try await fixture.insertMessage(
        guid: "BULK-\(index)",
        at: start.addingTimeInterval(Double(index) / 10)
      )
    }

    let changes = try await detector.tick(now: Self.now).messages

    #expect(
      changes.count == count,
      "saw \(changes.count) of \(count): the window was truncated at a page boundary"
    )
    // Specifically the NEWEST one, which is what a single ascending page loses.
    #expect(changes.contains { $0.message.guid == "BULK-\(count - 1)" })
  }

  // MARK: - Field diffing

  private func stamp(_ raw: Int64) -> AppleTimestamp {
    AppleTimestamp(rawValue: raw, unit: .nanoseconds)
  }

  @Test("A fingerprint read narrowly equals one taken from the hydrated row")
  func fingerprintShapesAgree() async throws {
    // The detector caches a fingerprint from either shape (`prime` takes hydrated rows, a
    // tick takes the narrow query) and compares it against the other. A field the two read
    // differently would be reported as moved on every tick.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let at = Self.now.addingTimeInterval(-60)
    try await fixture.insertMessage(guid: "SHAPE-1", at: at)
    try await fixture.markRead(guid: "SHAPE-1", at: at.addingTimeInterval(5))

    let narrow = try await fixture.repository.messageFingerprints(
      after: at.addingTimeInterval(-1), limit: 10)
    let row = try #require(narrow.first { $0.guid == "SHAPE-1" })
    let hydrated = try #require(try await fixture.repository.messages(rowIDs: [row.rowID]).first)
    #expect(row.fingerprint.dateRead != nil)
    #expect(MessageFingerprint(hydrated) == row.fingerprint)
  }

  @Test("Only the fields that moved are reported")
  func diffNamesTheChangedFields() {
    let before = MessageFingerprint(
      date: stamp(1), dateRead: nil, dateDelivered: nil, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: false, error: 0
    )
    var after = before
    after = MessageFingerprint(
      date: stamp(1), dateRead: stamp(99), dateDelivered: stamp(42), datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: false, error: 0
    )
    #expect(ChangeDetector.difference(from: before, to: after) == [.read, .delivered])
  }

  @Test("didNotifyRecipient is one-way")
  func notificationFlagIsOneWay() {
    // false -> true is the notification firing. The reverse would be Apple rewriting
    // history, and treating it as a change emits an update nothing asked for.
    let notified = MessageFingerprint(
      date: stamp(1), dateRead: nil, dateDelivered: nil, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: true, error: 0
    )
    let notNotified = MessageFingerprint(
      date: stamp(1), dateRead: nil, dateDelivered: nil, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: false, error: 0
    )
    #expect(ChangeDetector.difference(from: notNotified, to: notified) == [.notifiedRecipient])
    #expect(ChangeDetector.difference(from: notified, to: notNotified).isEmpty)
  }

  // MARK: - Startup and late arrivals

  @Test("The first tick announces nothing, whatever the window holds")
  func firstTickIsSilent() async throws {
    // On restart the cache is empty and everything in the window is unseen. All of it is
    // history; announcing the last half hour again on every restart is the bug users
    // notice.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    // Cursor an hour back, so the window is full of rows that postdate it.
    let detector = detector(fixture, startingFrom: Self.now.addingTimeInterval(-3600))
    for index in 0..<5 {
      try await fixture.insertMessage(
        guid: "BEFORE-START-\(index)", at: Self.now.addingTimeInterval(Double(-60 * index))
      )
    }

    #expect(try await detector.tick(now: Self.now).messages.isEmpty)

    // And the cache was populated, not skipped: a receipt on one of them is an update.
    try await fixture.markRead(guid: "BEFORE-START-2", at: Self.now)
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(2)).messages
    #expect(changes.map(\.message.guid) == ["BEFORE-START-2"])
    #expect(changes.first?.isNew == false)
  }

  @Test("A message that arrives late is still announced as new")
  func lateArrivalIsNew() async throws {
    // The row carries the time it was SENT. When the network was down for ten minutes the
    // messages arrive together, each dated somewhere in that gap and all of them older
    // than the cursor. They are new to every client and must be announced.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now).messages

    // Ticks kept running through the outage; nothing arrived.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(300)).messages
    _ = try await detector.tick(now: Self.now.addingTimeInterval(600)).messages

    // Then the backlog lands, dated inside the gap.
    try await fixture.insertMessage(guid: "LATE-1", at: Self.now.addingTimeInterval(120))
    try await fixture.insertMessage(guid: "LATE-2", at: Self.now.addingTimeInterval(480))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(601)).messages

    #expect(changes.filter(\.isNew).map(\.message.guid).sorted() == ["LATE-1", "LATE-2"])
  }

  /// Backfill is told from an outage by VOLUME, not by age.
  ///
  /// This test used to insert ONE row dated two hours ago and assert silence, which the
  /// 30-minute window delivered. That row is indistinguishable from an outage backlog —
  /// same age, same freshly-assigned ROWID, same everything — so the old rule bought its
  /// protection by discarding every late arrival, which is the defect in `../TODO.md`.
  ///
  /// What actually harms a user is a thousand notifications at once, and that is a property
  /// of the batch rather than of any row in it. So the assertion moved to the property the
  /// rule is really defending.
  @Test("A backfill large enough to be a sync is cached, not announced")
  func backfillIsSilent() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture, maximumAnnouncedPerTick: 10)
    _ = try await detector.tick(now: Self.now).messages

    // iCloud restoring a device: many rows, fresh ROWIDs, dates across the past.
    for index in 0..<40 {
      try await fixture.insertMessage(
        guid: "BACKFILL-\(index)",
        at: Self.now.addingTimeInterval(-7200 - Double(index) * 60))
    }
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(400)).messages
    #expect(!changes.contains { $0.message.guid.hasPrefix("BACKFILL") })

    // Cached, not skipped: a later receipt on one of them is still an update.
    try await fixture.markRead(guid: "BACKFILL-0", at: Self.now.addingTimeInterval(401))
    let later = try await detector.tick(now: Self.now.addingTimeInterval(800)).messages
    #expect(later.contains { $0.message.guid == "BACKFILL-0" && $0.changedFields == [.read] })
  }

  /// The other side of the same rule, and the one the outage report was about.
  @Test("A handful of messages from a long outage are announced, however old they are")
  func longOutageBacklogIsAnnounced() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now).messages

    // Two hours offline. Ticks kept running against a local chat.db that gained nothing.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(3600)).messages
    _ = try await detector.tick(now: Self.now.addingTimeInterval(7200)).messages

    // The backlog lands at once, each row dated when it was SENT: well outside the old
    // 30-minute window, which cached all three silently.
    try await fixture.insertMessage(guid: "OUT-1", at: Self.now.addingTimeInterval(600))
    try await fixture.insertMessage(guid: "OUT-2", at: Self.now.addingTimeInterval(3000))
    try await fixture.insertMessage(guid: "OUT-3", at: Self.now.addingTimeInterval(7100))

    let changes = try await detector.tick(now: Self.now.addingTimeInterval(7260)).messages
    #expect(
      changes.filter(\.isNew).map(\.message.guid).sorted() == ["OUT-1", "OUT-2", "OUT-3"],
      "a message sent more than the fast window ago must still be news when it lands")
  }

  /// A replaced `chat.db` reassigns ROWIDs from 1. A mark carried over from the old file
  /// would sit above every row in the new one and silence the detector for ever.
  @Test("A chat.db whose ROWIDs went backwards re-baselines instead of going silent")
  func rowIDResetReBaselines() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    try await fixture.insertMessage(guid: "OLD-1", at: Self.now)
    _ = try await detector.tick(now: Self.now).messages

    // The database was replaced underneath us: the mark is from the old file and sits far
    // above anything in the new one.
    await detector.setHighWater(9_000_000)
    #expect(await detector.highWaterRowID == 9_000_000)

    // The guard runs on a reconcile pass, which needs the interval AND a commit.
    try await fixture.insertMessage(guid: "AFTER-RESET", at: Self.now.addingTimeInterval(400))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(400)).messages

    #expect(
      await detector.highWaterRowID < 9_000_000,
      "a stale mark above every row silences the detector permanently")
  }

  // MARK: - Clamping

  @Test("Waking after a long sleep does not replay the whole gap as new")
  func catchUpIsClamped() async throws {
    // A Mac that slept for a week comes back with a cursor a week old. Without the clamp
    // the next tick queries a week of history and announces all of it as new messages,
    // which on a phone is a week of notifications at once.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let weekAgo = Self.now.addingTimeInterval(-604_800)
    let detector = detector(fixture, startingFrom: weekAgo)
    _ = try await detector.tick(now: weekAgo).messages

    // Three days old: inside the week-long gap, outside the 24-hour catch-up clamp.
    try await fixture.insertMessage(
      guid: "SLEPT-THROUGH", at: Self.now.addingTimeInterval(-259_200)
    )

    let changes = try await detector.tick(now: Self.now).messages
    #expect(
      !changes.contains { $0.message.guid == "SLEPT-THROUGH" && $0.isNew },
      "a message from before the clamp was announced as new"
    )
  }

  // MARK: - The backup pass

  @Test("The backup check asks SQLite, and only a commit makes it query")
  func backupChecksTheChangeTokenBeforeQuerying() async throws {
    // The whole point of the backup pass: a quiet Mac must cost a shared-memory read
    // every 30 seconds, not a query. `hasCommittedSinceLastTick` is that read.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    // Nothing has been read yet, so the answer has to be "look".
    #expect(await detector.hasCommittedSinceLastTick())

    _ = try await detector.tick(now: Self.now).messages
    #expect(await detector.hasCommittedSinceLastTick() == false)
    #expect(await detector.hasCommittedSinceLastTick() == false, "stable across repeated asks")

    try await fixture.insertMessage(guid: "COMMITTED", at: Self.now.addingTimeInterval(1))
    #expect(await detector.hasCommittedSinceLastTick())

    // And the tick that follows resets it.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(2)).messages
    #expect(await detector.hasCommittedSinceLastTick() == false)
  }

  @Test("A pooled database answers the change token on one fixed connection")
  func pooledChangeTokenIsComparable() async throws {
    // `data_version` is per connection. A pool hands `read` whichever reader is free, so
    // two asks could land on two connections and differ with nothing committed, which
    // would make the backup pass query every time. The pooled reader keeps one connection
    // aside for exactly this question.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let pooled = try ReadOnlyDatabase(path: fixture.path, maximumReaders: 4)

    let first = try await pooled.changeToken()
    for _ in 0..<8 {
      #expect(try await pooled.changeToken() == first)
    }
    try await fixture.insertMessage(guid: "POOLED", at: Self.now)
    #expect(try await pooled.changeToken() != first)
  }

  @Test("The wide pass is skipped while nothing has been committed")
  func reconcileIsSkippedWithoutCommits() async throws {
    // The seven-day window is the expensive read. A receipt on an old message is a commit
    // like any other, so an unchanged token means the window holds exactly what it held
    // last time and the pass is pure cost.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    _ = try await detector.tick(now: Self.now).messages
    #expect(await detector.reconcileCount == 1, "the first tick seeds with a wide pass")

    // Well past the reconcile interval, with no writes in between.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(400)).messages
    _ = try await detector.tick(now: Self.now.addingTimeInterval(800)).messages
    #expect(await detector.reconcileCount == 1)

    // A commit, then the next tick past the interval widens again.
    try await fixture.insertMessage(guid: "LATER", at: Self.now.addingTimeInterval(801))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(1200)).messages
    #expect(await detector.reconcileCount == 2)
  }

  @Test("Through the stream, the backup pass delivers a commit without a file watcher")
  func streamBackupDeliversWithoutWatcher() async throws {
    // No `watching:` path, so the timer is the only thing that can notice the write:
    // the situation on a Mac whose file events have stopped arriving. The stream sleeps on
    // a test clock, so the backup passes run as fast as time is advanced; the assertion on
    // `tickCount` is what shows the timer checked several times and queried only once for
    // the commit.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let clock = TestClock()
    let backup = Duration.milliseconds(100)
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: .milliseconds(500), backupInterval: backup
      ),
      clock: clock
    )
    let delivered = Delivered(await detector.changes(watching: nil))
    defer { delivered.cancel() }

    // The seeding tick is done once the floor after it and the backup timer are both parked.
    try await clock.waitForSleepers(2)
    // A few empty backup passes, past the floor.
    for _ in 0..<6 {
      clock.advance(by: backup)
      try await clock.waitForSleepers(1)
    }
    try await fixture.insertMessage(guid: "VIA-BACKUP", at: Date())

    let change = try await waitFor("the commit, through the backup pass") {
      clock.advance(by: backup)
      return delivered.changes.first { $0.message.guid == "VIA-BACKUP" }
    }
    await detector.stop()

    #expect(change.isNew)
    let ticks = await detector.tickCount
    #expect(ticks <= 2, "queried \(ticks) times; backup passes without a commit must not query")
  }

  /// The arrival query must SEEK the primary key, and must never grow a date predicate.
  ///
  /// **This is the guard on a 2,500x regression, not a style check.** Measured on a real
  /// 421,941-row `chat.db`: `WHERE date > ? ORDER BY date, ROWID` plans as
  /// `SEARCH … USING INDEX message_idx_date` at 0.005 ms, and `WHERE ROWID > ?` plans as
  /// `SEARCH … USING INTEGER PRIMARY KEY` at 0.002 ms — but the obvious way to combine
  /// them, `WHERE date > ? OR ROWID > ?`, cannot seek two columns through one index and
  /// degrades to `SCAN`, walking all 421,941 entries at 12.478 ms. At a 500 ms tick that
  /// is 25 ms of SQLite per second on an M3 Max, and this server targets Macs an order of
  /// magnitude slower with disks to match.
  ///
  /// So the two questions stay two queries, and this asserts the cheap plan of the one that
  /// is easiest to "simplify" into the expensive one.
  @Test("The arrival query seeks the primary key and never scans")
  func arrivalQuerySeeksTheRowIDIndex() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let (sql, arguments) = fixture.repository.fingerprintQuery(afterRowID: 1, limit: 10)
    let plan = try await fixture.database.explainQueryPlan(
      sql: sql, arguments: StatementArguments(arguments)
    )
    #expect(plan.contains { $0.contains("USING INTEGER PRIMARY KEY") }, "\(plan)")
    #expect(!plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
    #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    // The predicate itself, because a date clause is what costs the seek and a plan taken
    // on an empty fixture is not always sensitive enough to catch one. Only the clauses
    // after WHERE are checked: `date` belongs in the SELECT list, which is how `compare`
    // applies the catch-up bound without a second query.
    let predicate = sql.components(separatedBy: " WHERE ").last ?? sql
    #expect(
      !predicate.contains("date"),
      "the arrival query must not filter or sort on date: \(predicate)")
  }

  @Test("The fingerprint query walks the date index on both page shapes")
  func fingerprintQueryUsesTheDateIndex() async throws {
    // The whole reason detection queries by `date`: it is the one timestamp Apple indexes.
    // Both the first page and a resumed page must be a range scan on that index, and the
    // (date, ROWID) order must come off the index rather than a sort.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let repository = fixture.repository

    let shapes: [MessageRepository.FingerprintCursor?] = [
      nil, MessageRepository.FingerprintCursor(date: 1, rowID: 1),
    ]
    for cursor in shapes {
      let (sql, arguments) = repository.fingerprintQuery(
        after: Self.now, resumingFrom: cursor, limit: 10
      )
      let plan = try await fixture.database.explainQueryPlan(
        sql: sql, arguments: StatementArguments(arguments)
      )
      #expect(plan.contains { $0.contains("USING INDEX message_idx_date") }, "\(plan)")
      #expect(!plan.contains { $0.hasPrefix("SCAN") }, "\(plan)")
      #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }
  }

  @Test("Keyset paging is stable when a row lands between pages")
  func keysetPagingSurvivesAnInsertBetweenPages() async throws {
    // OFFSET paging shifted every later page when Messages inserted a row mid-walk, so a
    // row was duplicated or skipped. Resuming from the last (date, ROWID) seen is not
    // affected by what lands ahead of it.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let repository = fixture.repository
    let start = Self.now.addingTimeInterval(-600)
    for index in 0..<6 {
      try await fixture.insertMessage(
        guid: "PAGE-\(index)", at: start.addingTimeInterval(Double(index))
      )
    }

    let first = try await repository.messageFingerprints(
      after: start.addingTimeInterval(-1), limit: 3
    )
    #expect(first.map(\.guid) == ["PAGE-0", "PAGE-1", "PAGE-2"])

    // A row older than everything on the next page, inserted after the first page.
    try await fixture.insertMessage(guid: "PAGE-EARLY", at: start.addingTimeInterval(-0.5))

    let last = try #require(first.last)
    let cursor = MessageRepository.FingerprintCursor(
      date: try #require(last.fingerprint.date?.rawValue), rowID: last.rowID
    )
    let second = try await repository.messageFingerprints(
      after: start.addingTimeInterval(-1), resumingFrom: cursor, limit: 3
    )
    #expect(second.map(\.guid) == ["PAGE-3", "PAGE-4", "PAGE-5"], "no duplicate, no skip")
  }

  @Test("A watcher that never fires while commits keep arriving is re-armed")
  func deafWatcherIsReset() async throws {
    // Watching a file that is not the database is the cheapest deaf watcher there is:
    // it is armed, it is healthy, and it will never see a write. Three backup passes that
    // each find a commit it did not announce must tear it down and re-arm it.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let decoy = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-decoy-\(UUID().uuidString)").path
    FileManager.default.createFile(atPath: decoy, contents: Data("x".utf8))
    defer { try? FileManager.default.removeItem(atPath: decoy) }

    let clock = TestClock()
    let backup = Duration.milliseconds(150)
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: .milliseconds(500), backupInterval: backup
      ),
      clock: clock
    )
    let delivered = Delivered(await detector.changes(watching: decoy))
    defer { delivered.cancel() }
    try await clock.waitForSleepers(2)

    // One commit per backup pass, well past the threshold. Each is waited for until a pass
    // has queried for it, so no two commits share a pass.
    for index in 0..<ChangeDetector.deafWatcherThreshold + 1 {
      let ticks = await detector.tickCount
      try await fixture.insertMessage(guid: "UNANNOUNCED-\(index)", at: Date())
      try await waitUntil("a backup pass to query for commit \(index)") {
        clock.advance(by: backup)
        return await detector.tickCount > ticks
      }
    }
    await detector.stop()

    #expect(await detector.watcherResets >= 1)
  }

  @Test("Through a real watcher, a commit is delivered without waiting for the backup")
  func streamPrimaryPathDelivers() async throws {
    // The primary path end to end: a write to the fixture file raises a vnode event, the
    // detector ticks, and the change arrives. The test clock is moved past the floor and
    // never near the 30-second backup, so the backup pass cannot be what delivered it.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let clock = TestClock()
    let floor = Duration.milliseconds(500)
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: floor, backupInterval: .seconds(30)
      ),
      clock: clock
    )
    let stream = await detector.changes(watching: fixture.path)
    // The seeding tick is done once its floor and the backup timer are parked; then its
    // floor elapses.
    try await clock.waitForSleepers(2)
    clock.advance(by: floor)

    let started = ContinuousClock.now
    try await fixture.insertMessage(guid: "VIA-KQUEUE", at: Date())

    // `for await` returns nil when `withTimeout` cancels it, so a timeout is a thrown
    // `TimedOut` rather than a race between two iterators.
    let delivered = try await withTimeout(.seconds(5)) { () -> [MessageChange]? in
      for await batch in stream { return batch.messages }
      return nil
    }
    let elapsed = ContinuousClock.now - started
    await detector.stop()

    #expect(delivered?.contains { $0.message.guid == "VIA-KQUEUE" && $0.isNew } == true)
    #expect(elapsed < .seconds(3), "took \(elapsed); that is the backup pass, not the watcher")
    #expect(clock.now.offset < .seconds(30), "the backup interval was reached")
  }

  @Test("The poll interval has a floor")
  func pollIntervalIsFloored() {
    // Below 500ms a busy conversation produces more polls than messages.
    let configuration = ChangeDetectorConfiguration(pollInterval: .milliseconds(1))
    #expect(configuration.pollInterval == .milliseconds(500))
  }

  // MARK: - Bookkeeping

  @Test("Priming the cache suppresses the first announcement")
  func primingSuppressesReplay() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture, startingFrom: Self.now.addingTimeInterval(-3600))

    try await fixture.insertMessage(guid: "PRIMED", at: Self.now.addingTimeInterval(-60))
    let existing = try await fixture.repository.messages(
      MessageRepository.MessageQuery(limit: 100)
    )
    await detector.prime(with: existing)

    let changes = try await detector.tick(now: Self.now).messages
    #expect(!changes.contains { $0.message.guid == "PRIMED" })
    #expect(await detector.trackedCount == existing.count)
  }
}

/// Drains a detector's stream into a list the test can poll, so a wait that also advances the
/// clock can ask "has it arrived yet" without holding an iterator across tasks.
private final class Delivered: Sendable {
  private let received = Locked<[MessageChange]>([])
  private let drain: Task<Void, Never>

  init(_ stream: AsyncStream<ChangeBatch>) {
    let received = self.received
    drain = Task {
      for await batch in stream { received.withLock { $0.append(contentsOf: batch.messages) } }
    }
  }

  var changes: [MessageChange] { received.value }

  func cancel() { drain.cancel() }
}

/// The fingerprint cache: how big it is, and whether it ever gives anything back.
///
/// The capacity used to be 25,000 because a comment said "20,000 rows of fingerprints is a
/// few megabytes". It is 756 bytes an entry -- 18.5MB at that capacity, a third of the whole
/// stated idle budget, in one always-populated cache on the always-on path. Worse,
/// `BoundedCache.trim()` had no callers anywhere in the source, so the seven-day TTL never
/// reclaimed anything and a quiet server held every fingerprint it had ever taken.
@Suite("Fingerprint cache")
struct FingerprintCacheTests {

  /// Derived from what a reconcile pass can produce, not chosen. A capacity below that
  /// evicts inside a single wide pass, and every fingerprint it forgets is an update the
  /// detector can no longer detect.
  @Test("The capacity is the reconcile window's own ceiling")
  func capacityMatchesTheWindow() {
    #expect(
      ChangeDetector.defaultCacheCapacity
        == ChangeDetector.maximumWindowPages * ChangeDetector.pageSize)
    #expect(ChangeDetector.defaultCacheCapacity == 20_000)
  }

  /// The TTL has to actually expire something, which it never did.
  @Test("A cache with a TTL drops what has aged out when it is trimmed")
  func trimReclaims() async throws {
    var cache = BoundedCache<String, Int>(capacity: 1000, ttl: .milliseconds(50))
    for i in 0..<100 { cache[String(i)] = i }
    #expect(cache.count == 100)

    try await Task.sleep(for: .milliseconds(120))
    // Non-vacuity: the count cap alone reclaims nothing here, so without the sweep the
    // entries are still present however long they have been there.
    #expect(cache.count == 100, "nothing should have been reclaimed without a trim")

    cache.trim()
    #expect(cache.count == 0)
  }

  /// And the detector asks for one. Counting ticks rather than trimming on every tick,
  /// because the sweep is O(entries) and a tick can be half a second apart.
  @Test("The detector sweeps its cache on a schedule, not on every tick")
  func detectorTrimsPeriodically() {
    #expect(ChangeDetector.ticksBetweenTrims > 1)
    // About a minute at the fastest tick rate, which is the floor `pollInterval` allows.
    #expect(ChangeDetector.ticksBetweenTrims * 500 >= 30_000)
  }
}

//  ChangeDetectorTests
//  The component with the least margin for error and, until now, no tests.
//
//  Everything a client sees arrives through here: a message the detector misses is a message
//  that never reaches a phone, and nothing reports it. The failure is silent by construction,
//  which is exactly why it needs tests that move the database underneath a running detector
//  rather than tests that check the diffing function in isolation.
//
//  Driven through `tick(now:)` rather than the stream, so time is a parameter instead of a
//  sleep. The stream's own scheduling is the part that would make these slow and flaky.

import BBIMessage
import BBPersistence
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
    startingFrom: Date = ChangeDetectorTests.now
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
    _ = try await detector.tick(now: Self.now)

    try await fixture.insertMessage(guid: "NEW-1", at: Self.now.addingTimeInterval(1))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(2))

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
    _ = try await detector.tick(now: Self.now)

    try await fixture.insertMessage(guid: "NEW-1", at: Self.now.addingTimeInterval(1))
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(2)).count == 1)
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(3)).isEmpty)
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(4)).isEmpty)
  }

  @Test("Messages already in the database on startup are not replayed")
  func existingMessagesAreNotReplayed() async throws {
    // Otherwise every restart floods every connected client with the last half hour.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    let changes = try await detector.tick(now: Self.now)
    #expect(changes.isEmpty)
  }

  // MARK: - Updates

  @Test("A read receipt on an existing message is reported as an update")
  func readReceiptIsDetected() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)

    try await fixture.insertMessage(guid: "MSG-R", at: Self.now.addingTimeInterval(1))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(2))

    try await fixture.markRead(guid: "MSG-R", at: Self.now.addingTimeInterval(3))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(4))

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

    // Two hours old — outside the 30-minute fast window, inside the 7-day wide one.
    let old = Self.now.addingTimeInterval(-7200)
    try await fixture.insertMessage(guid: "MSG-OLD", at: old)

    // A reconcile tick to take the baseline, then far enough ahead for another.
    _ = try await detector.tick(now: Self.now)
    try await fixture.markRead(guid: "MSG-OLD", at: Self.now)

    // A fast tick cannot see it.
    #expect(try await detector.tick(now: Self.now.addingTimeInterval(10)).isEmpty)

    // The reconcile tick can.
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(400))
    #expect(changes.contains { $0.message.guid == "MSG-OLD" && $0.changedFields == [.read] })
  }

  /// THE regression this suite was written for.
  ///
  /// `MessageQuery` caps `limit` at 1000 and the detector took a single ASCENDING page, so
  /// a window holding more than 1000 messages was only ever examined from its oldest end.
  /// On any account with more than a thousand messages a week, the seven-day reconcile pass
  /// therefore never reached anything recent, and receipts on messages between 30 minutes
  /// and 7 days old silently stopped being detected — on the busiest accounts first.
  @Test("A window larger than one page is examined to its end")
  func windowLargerThanOnePageIsPaged() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    // Just over one page, all inside the fast window so a single tick must see them all.
    let count = ChangeDetector.pageSize + 25
    let start = Self.now.addingTimeInterval(-600)
    // A detector whose cursor predates the bulk, baselined before it lands, so every one
    // of them is new to the tick under test.
    let detector = detector(fixture, startingFrom: start.addingTimeInterval(-1))
    _ = try await detector.tick(now: start.addingTimeInterval(-1))
    for index in 0..<count {
      try await fixture.insertMessage(
        guid: "BULK-\(index)",
        at: start.addingTimeInterval(Double(index) / 10)
      )
    }

    let changes = try await detector.tick(now: Self.now)

    #expect(
      changes.count == count,
      "saw \(changes.count) of \(count) — the window was truncated at a page boundary"
    )
    // Specifically the NEWEST one, which is what a single ascending page loses.
    #expect(changes.contains { $0.message.guid == "BULK-\(count - 1)" })
  }

  // MARK: - Field diffing

  @Test("Only the fields that moved are reported")
  func diffNamesTheChangedFields() {
    let before = ChangeDetector.MessageFingerprint(
      date: 1, dateRead: nil, dateDelivered: nil, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: false, error: 0
    )
    var after = before
    after = ChangeDetector.MessageFingerprint(
      date: 1, dateRead: 99, dateDelivered: 42, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: false, error: 0
    )
    #expect(ChangeDetector.difference(from: before, to: after) == [.read, .delivered])
  }

  @Test("didNotifyRecipient is one-way")
  func notificationFlagIsOneWay() {
    // false -> true is the notification firing. The reverse would be Apple rewriting
    // history, and treating it as a change emits an update nothing asked for.
    let notified = ChangeDetector.MessageFingerprint(
      date: 1, dateRead: nil, dateDelivered: nil, datePlayed: nil,
      dateEdited: nil, dateRetracted: nil, didNotifyRecipient: true, error: 0
    )
    let notNotified = ChangeDetector.MessageFingerprint(
      date: 1, dateRead: nil, dateDelivered: nil, datePlayed: nil,
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

    #expect(try await detector.tick(now: Self.now).isEmpty)

    // And the cache was populated, not skipped: a receipt on one of them is an update.
    try await fixture.markRead(guid: "BEFORE-START-2", at: Self.now)
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(2))
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
    _ = try await detector.tick(now: Self.now)

    // Ticks kept running through the outage; nothing arrived.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(300))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(600))

    // Then the backlog lands, dated inside the gap.
    try await fixture.insertMessage(guid: "LATE-1", at: Self.now.addingTimeInterval(120))
    try await fixture.insertMessage(guid: "LATE-2", at: Self.now.addingTimeInterval(480))
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(601))

    #expect(changes.filter(\.isNew).map(\.message.guid).sorted() == ["LATE-1", "LATE-2"])
  }

  @Test("Backfilled history older than the fast window is cached, not announced")
  func backfillIsSilent() async throws {
    // iCloud syncing a device's history inserts rows with fresh ROWIDs and old dates.
    // Thousands of those must not become thousands of notifications.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = detector(fixture)
    _ = try await detector.tick(now: Self.now)

    try await fixture.insertMessage(guid: "BACKFILL", at: Self.now.addingTimeInterval(-7200))
    // A reconcile tick, so the two-hour-old row is inside the window.
    let changes = try await detector.tick(now: Self.now.addingTimeInterval(400))
    #expect(!changes.contains { $0.message.guid == "BACKFILL" })

    // Cached, though: a later receipt on it is an update.
    try await fixture.markRead(guid: "BACKFILL", at: Self.now.addingTimeInterval(401))
    let later = try await detector.tick(now: Self.now.addingTimeInterval(800))
    #expect(later.contains { $0.message.guid == "BACKFILL" && $0.changedFields == [.read] })
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
    _ = try await detector.tick(now: weekAgo)

    // Three days old: inside the week-long gap, outside the 24-hour catch-up clamp.
    try await fixture.insertMessage(
      guid: "SLEPT-THROUGH", at: Self.now.addingTimeInterval(-259_200)
    )

    let changes = try await detector.tick(now: Self.now)
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

    _ = try await detector.tick(now: Self.now)
    #expect(await detector.hasCommittedSinceLastTick() == false)
    #expect(await detector.hasCommittedSinceLastTick() == false, "stable across repeated asks")

    try await fixture.insertMessage(guid: "COMMITTED", at: Self.now.addingTimeInterval(1))
    #expect(await detector.hasCommittedSinceLastTick())

    // And the tick that follows resets it.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(2))
    #expect(await detector.hasCommittedSinceLastTick() == false)
  }

  @Test("A pooled database answers the change token on one fixed connection")
  func pooledChangeTokenIsComparable() async throws {
    // `data_version` is per connection. A pool hands `read` whichever reader is free, so
    // two asks could land on two connections and differ with nothing committed — which
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

    _ = try await detector.tick(now: Self.now)
    #expect(await detector.reconcileCount == 1, "the first tick seeds with a wide pass")

    // Well past the reconcile interval, with no writes in between.
    _ = try await detector.tick(now: Self.now.addingTimeInterval(400))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(800))
    #expect(await detector.reconcileCount == 1)

    // A commit, then the next tick past the interval widens again.
    try await fixture.insertMessage(guid: "LATER", at: Self.now.addingTimeInterval(801))
    _ = try await detector.tick(now: Self.now.addingTimeInterval(1200))
    #expect(await detector.reconcileCount == 2)
  }

  @Test("Through the stream, the backup pass delivers a commit without a file watcher")
  func streamBackupDeliversWithoutWatcher() async throws {
    // No `watching:` path, so the timer is the only thing that can notice the write —
    // the situation on a Mac whose file events have stopped arriving. Short intervals
    // so the test is not a 30-second wait; the assertion on `tickCount` is what shows
    // the timer checked several times and queried only once for the commit.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: .milliseconds(500), backupInterval: .milliseconds(100)
      )
    )
    let stream = await detector.changes(watching: nil)

    // Let the seeding tick and a few empty backup passes go by.
    try await Task.sleep(for: .milliseconds(600))
    try await fixture.insertMessage(guid: "VIA-BACKUP", at: Date())

    // `for await` on the stream returns nil when the task is cancelled, so a timeout is
    // a cancellation rather than a race between two iterators.
    let waiter = Task { () -> [MessageChange]? in
      for await batch in stream { return batch }
      return nil
    }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))
      waiter.cancel()
    }
    let delivered = await waiter.value
    timeout.cancel()
    await detector.stop()

    #expect(delivered?.contains { $0.message.guid == "VIA-BACKUP" && $0.isNew } == true)
    let ticks = await detector.tickCount
    #expect(ticks <= 2, "queried \(ticks) times; backup passes without a commit must not query")
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
      date: try #require(last.date?.rawValue), rowID: last.rowID
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

    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: .milliseconds(500), backupInterval: .milliseconds(150)
      )
    )
    let stream = await detector.changes(watching: decoy)
    let drain = Task { for await _ in stream {} }
    defer { drain.cancel() }

    // One commit per backup interval, well past the threshold, with time for the
    // floor sleep between ticks.
    for index in 0..<ChangeDetector.deafWatcherThreshold + 1 {
      try await Task.sleep(for: .milliseconds(800))
      try await fixture.insertMessage(guid: "UNANNOUNCED-\(index)", at: Date())
    }
    try await Task.sleep(for: .milliseconds(800))
    await detector.stop()

    #expect(await detector.watcherResets >= 1)
  }

  @Test("Through a real watcher, a commit is delivered without waiting for the backup")
  func streamPrimaryPathDelivers() async throws {
    // The primary path end to end: a write to the fixture file raises a vnode event, the
    // detector ticks, and the change arrives long before a 30-second backup would run.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let detector = ChangeDetector(
      repository: fixture.repository,
      configuration: ChangeDetectorConfiguration(
        pollInterval: .milliseconds(500), backupInterval: .seconds(30)
      )
    )
    let stream = await detector.changes(watching: fixture.path)
    // Let the seeding tick finish and its floor elapse.
    try await Task.sleep(for: .milliseconds(700))

    let started = ContinuousClock.now
    try await fixture.insertMessage(guid: "VIA-KQUEUE", at: Date())

    let waiter = Task { () -> [MessageChange]? in
      for await batch in stream { return batch }
      return nil
    }
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))
      waiter.cancel()
    }
    let delivered = await waiter.value
    timeout.cancel()
    let elapsed = ContinuousClock.now - started
    await detector.stop()

    #expect(delivered?.contains { $0.message.guid == "VIA-KQUEUE" && $0.isNew } == true)
    #expect(elapsed < .seconds(3), "took \(elapsed); that is the backup pass, not the watcher")
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

    let changes = try await detector.tick(now: Self.now)
    #expect(!changes.contains { $0.message.guid == "PRIMED" })
    #expect(await detector.trackedCount == existing.count)
  }
}

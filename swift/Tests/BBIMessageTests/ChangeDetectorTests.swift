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
    for index in 0..<count {
      try await fixture.insertMessage(
        guid: "BULK-\(index)",
        at: start.addingTimeInterval(Double(index) / 10)
      )
    }

    // A detector whose cursor predates the bulk, so every one of them is new.
    let detector = detector(fixture, startingFrom: start.addingTimeInterval(-1))
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

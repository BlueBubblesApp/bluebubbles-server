//  AlertPersistenceTests
//  Alerts outlive the process that raised them.
//
//  They did not. `AlertCenter` held `private var alerts: [UserAlert] = []` and nothing else,
//  so every alert died with the process — while applying a THIRTY-DAY retention window and
//  counting occurrences, both of which are policies written for a store that persists. The
//  `alert` table had been in the migrations since `createAlerts`, with `occurrence_count`,
//  `read_at` and `dismissed_at` columns that only mean anything across a restart, and no
//  code had ever read or written a row.
//
//  "A restart" here is a second `AlertCenter` over the same database, which is exactly what
//  the next launch is.

import BBCore
import BBDiagnostics
import BBPersistence
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Alert persistence")
struct AlertPersistenceTests {

  private func centre(
    on database: AppDatabase,
    clock: any BBClock = SystemClock(),
    capacity: Int = AlertCenter.defaultCapacity,
    retention: Duration = AlertCenter.defaultRetention
  ) async -> AlertCenter {
    let centre = AlertCenter(capacity: capacity, retention: retention, clock: clock)
    await centre.attach(store: AlertRepository(database: database))
    return centre
  }

  @Test("A durable alert survives a restart, unread")
  func durableAlertSurvives() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(
      UserAlert(
        severity: .error, title: "The Keychain could not be read",
        body: "Your server password may be unavailable.", source: "Settings",
        dedupeKey: "settings.keychain_unavailable"
      ))

    let restarted = await centre(on: database)
    let restored = await restarted.all()
    #expect(restored.count == 1)
    #expect(restored.first?.title == "The Keychain could not be read")
    // Still unread, so it is still in front of the user — the whole point of persisting a
    // fact that a restart does not make untrue.
    #expect(restored.first?.readAt == nil)
    #expect(await restarted.badgeCount() == 1)
  }

  @Test("A transient alert is kept but restored already read")
  func transientAlertDoesNotClamour() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(
      UserAlert(
        severity: .error, title: "The tunnel has stopped",
        body: "It gave up after ten attempts.", source: "Connection",
        dedupeKey: "proxy.gave-up.ngrok",
        isDurable: false
      ))

    let restarted = await centre(on: database)
    // Present — the history and the occurrence count are worth keeping.
    #expect(await restarted.all().count == 1)
    // But not shouting: the condition is re-derived at start-up, and the tunnel may well
    // be up again.
    #expect(await restarted.all().first?.readAt != nil)
    #expect(await restarted.badgeCount() == 0)
  }

  @Test("Occurrence counts accumulate across restarts")
  func occurrencesAccumulate() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    for _ in 1...3 {
      await first.raise(
        UserAlert(
          severity: .warning, title: "A permission was revoked",
          body: "Contacts is no longer granted.", source: "Permissions",
          dedupeKey: "permission.contacts"
        ))
    }
    #expect(await first.all().first?.occurrenceCount == 3)

    let restarted = await centre(on: database)
    await restarted.raise(
      UserAlert(
        severity: .warning, title: "A permission was revoked",
        body: "Contacts is no longer granted.", source: "Permissions",
        dedupeKey: "permission.contacts"
      ))

    // Four, not one. "This has happened four times" is the thing `occurrence_count` was
    // put in the schema to be able to say, and it could not say it before.
    let restored = await restarted.all()
    #expect(restored.count == 1)
    #expect(restored.first?.occurrenceCount == 4)
  }

  @Test("Reading an alert sticks across a restart")
  func readStatePersists() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(
      UserAlert(
        severity: .warning, title: "A tool failed its signature check",
        body: "cloudflared was signed by a different team.", source: "Tools",
        dedupeKey: "tool.signature_team_changed"
      ))
    await first.markAllRead()

    let restarted = await centre(on: database)
    #expect(await restarted.all().first?.readAt != nil)
    #expect(await restarted.badgeCount() == 0, "a read alert must not come back unread")
  }

  @Test("Marking an alert unread again sticks across a restart")
  func unreadStatePersists() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(
      UserAlert(
        severity: .warning, title: "A tool failed its signature check",
        body: "cloudflared was signed by a different team.", source: "Tools",
        dedupeKey: "tool.signature_team_changed"
      ))
    await first.markAllRead()
    let id = try #require(await first.all().first?.id)
    await first.markUnread([id])

    // The undo has to reach the database, not just the in-memory copy. `update` writes
    // `read_at` unconditionally, so a nil has to land as NULL rather than being skipped —
    // otherwise un-reading something appears to work until the next launch, which is the
    // worst shape a bug like this can take.
    let restarted = await centre(on: database)
    #expect(await restarted.all().first?.readAt == nil)
    #expect(await restarted.badgeCount() == 1, "an un-read alert must count again")
  }

  @Test("Dismissing removes it for good")
  func dismissalPersists() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(
      UserAlert(severity: .info, title: "Gone", body: "b", source: "s")
    )
    let id = try #require(await first.all().first?.id)
    await first.dismiss(id)

    let restarted = await centre(on: database)
    #expect(await restarted.all().isEmpty, "a dismissed alert must not return on restart")
  }

  @Test("Sequence numbers keep climbing across restarts")
  func sequencesDoNotRepeat() async throws {
    let database = try AppDatabase.inMemory()

    let first = await centre(on: database)
    await first.raise(UserAlert(severity: .info, title: "One", body: "b", source: "s"))
    let firstSequence = try #require(await first.all().first?.sequence)

    let restarted = await centre(on: database)
    await restarted.raise(UserAlert(severity: .info, title: "Two", body: "b", source: "s"))
    let second = try #require(await restarted.all().first { $0.title == "Two" }?.sequence)

    // Reusing a number would let a client's stale id address a different alert — the same
    // hazard the in-memory counter documents and avoids within one process.
    #expect(second > firstSequence)
  }

  @Test("Alerts past the retention window are not restored")
  func retentionIsHonoured() async throws {
    let database = try AppDatabase.inMemory()
    let clock = ManualClock(Date(timeIntervalSince1970: 1_700_000_000))

    let first = await centre(on: database, clock: clock, retention: .seconds(60 * 60))
    await first.raise(UserAlert(severity: .info, title: "Old", body: "b", source: "s"))

    // Two hours later, on a one-hour window.
    let later = ManualClock(clock.now.addingTimeInterval(2 * 60 * 60))
    let restarted = await centre(on: database, clock: later, retention: .seconds(60 * 60))
    #expect(await restarted.all().isEmpty)
  }

  @Test("A centre with no store behaves exactly as it did before")
  func storeIsOptional() async throws {
    // The window during start-up before storage is open, and every test that raises an
    // alert without a database.
    let centre = AlertCenter()
    await centre.raise(UserAlert(severity: .info, title: "One", body: "b", source: "s"))
    #expect(await centre.all().count == 1)
    #expect(await centre.all().first?.sequence == 1)
  }
}

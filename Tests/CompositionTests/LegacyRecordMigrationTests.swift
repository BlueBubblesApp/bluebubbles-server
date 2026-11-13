//  LegacyRecordMigrationTests
//  Adopting the two Electron tables that hold things a person made.
//
//  **The first suite is the one that matters, and it is about not sending messages.**
//  `ScheduledMessageRepository.due(at:)` selects `status = pending AND scheduled_for <= now`,
//  so a pending row imported with a date in the past is DUE, and the next sweep delivers it.
//  Without the placement rule, adopting a server months after someone scheduled something
//  would have sent it to a real person at the moment of the upgrade. Every case below is
//  ultimately asserting the same property: after an import, no pending row is in the past.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAppStore
import BBPersistence
import Foundation
import GRDB
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Legacy record migration")
struct LegacyRecordMigrationTests {

  private let logger = Logger(label: "bluebubbles.test.records")

  /// An Electron `config.db` with the two tables and nothing else.
  private func legacyDatabase(in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(
        sql: """
          CREATE TABLE "device" ("name" text NOT NULL, "identifier" text NOT NULL,
            "last_active" integer, PRIMARY KEY ("name","identifier"))
          """)
      try db.execute(
        sql: """
          CREATE TABLE "webhook" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "url" text NOT NULL UNIQUE, "events" text NOT NULL,
            "created" datetime NOT NULL DEFAULT (datetime('now')))
          """)
      try db.execute(
        sql: """
          CREATE TABLE "scheduled_message" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
            "type" text NOT NULL, "payload" text NOT NULL, "scheduled_for" date NOT NULL,
            "schedule" text NOT NULL, "status" text NOT NULL DEFAULT ('pending'),
            "error" text, "sent_at" date,
            "created" datetime NOT NULL DEFAULT (datetime('now')))
          """)
    }
    try queue.close()
    return url
  }

  private func insertScheduled(
    at url: URL, message: String, offset: TimeInterval, status: String,
    schedule: String = #"{"type":"once"}"#
  ) throws {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    // Milliseconds, which is what Electron's `EpochDateTransformer` writes.
    let epoch = Date().addingTimeInterval(offset).timeIntervalSince1970 * 1000
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO scheduled_message (type,payload,scheduled_for,schedule,status)
          VALUES ('send-message',?,?,?,?)
          """,
        arguments: [#"{"message":"\#(message)"}"#, epoch, schedule, status])
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-records-\(UUID().uuidString)", isDirectory: true)
  }

  private func appDatabase() throws -> AppDatabase {
    try AppDatabase.inMemory(contributors: AppSchema.contributors)
  }

  // MARK: Nothing may be sent by the act of migrating

  @Test("A pending message whose time has passed is recorded, never left due")
  func overdueOneShotIsNotDue() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "overdue", offset: -864_000, status: "pending")

    let database = try appDatabase()
    let result = try await LegacyRecordMigration().run(
      from: legacy, into: database, logger: logger)
    #expect(result.scheduledImported == 1)
    #expect(result.scheduledLapsed == 1)

    let records = try await ScheduledMessageRepository(database: database).all()
    let record = try #require(records.first)
    #expect(record.status == ScheduledMessageStatus.failed.rawValue)
    #expect(record.error != nil, "a lapsed message must say why it was not sent")

    // The property the whole rule exists for.
    let due = try await ScheduledMessageRepository(database: database).due(at: Date())
    #expect(due.isEmpty, "the import left a message that the next sweep would deliver")
  }

  @Test("A recurring message whose occurrence passed is advanced, not fired")
  func overdueRecurringIsAdvanced() async throws {
    // A daily series that has been waiting ten days must not send ten messages, and must
    // not send one either: the occurrence was missed while the server was being upgraded.
    // `ScheduledMessageService.nextOccurrence` already answers "the next one after now".
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(
      at: legacy, message: "daily", offset: -864_000, status: "pending",
      schedule: #"{"type":"recurring","intervalType":"daily","interval":1}"#)

    let database = try appDatabase()
    let result = try await LegacyRecordMigration().run(
      from: legacy, into: database, logger: logger)
    #expect(result.scheduledLapsed == 0, "a recurring series is not lapsed, it is advanced")

    let record = try #require(try await ScheduledMessageRepository(database: database).all().first)
    #expect(record.status == ScheduledMessageStatus.pending.rawValue)
    #expect(record.scheduledFor > Date(), "the series was left in the past")
    let stillDue = try await ScheduledMessageRepository(database: database).due(at: Date())
    #expect(stillDue.isEmpty)
  }

  @Test("A message still in the future keeps its time and stays pending")
  func futureMessageIsUntouched() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "later", offset: 86_400, status: "pending")

    let database = try appDatabase()
    _ = try await LegacyRecordMigration().run(from: legacy, into: database, logger: logger)

    let record = try #require(try await ScheduledMessageRepository(database: database).all().first)
    #expect(record.status == ScheduledMessageStatus.pending.rawValue)
    #expect(record.scheduledFor > Date(), "a future message must still fire when they meant")
  }

  @Test("Sent and cancelled messages come across as history and are never due")
  func finishedMessagesAreHistory() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "sent", offset: -172_800, status: "sent")
    try insertScheduled(at: legacy, message: "stopped", offset: -172_800, status: "cancelled")

    let database = try appDatabase()
    _ = try await LegacyRecordMigration().run(from: legacy, into: database, logger: logger)

    let records = try await ScheduledMessageRepository(database: database).all()
    #expect(records.count == 2)
    #expect(Set(records.map(\.status)) == ["sent", "cancelled"])
    let stillDue = try await ScheduledMessageRepository(database: database).due(at: Date())
    #expect(stillDue.isEmpty)
  }

  @Test("A status this version does not know cannot become a send")
  func unknownStatusIsNotPending() async throws {
    // The rule is that nothing the import fails to understand may cause a delivery, so an
    // unrecognised status is taken as finished rather than as pending.
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "odd", offset: -86_400, status: "some-new-state")

    let database = try appDatabase()
    _ = try await LegacyRecordMigration().run(from: legacy, into: database, logger: logger)
    let stillDue = try await ScheduledMessageRepository(database: database).due(at: Date())
    #expect(stillDue.isEmpty)
  }

  // MARK: Webhooks

  @Test("Webhooks come across with their events, and keep following redirects")
  func webhooksAreImported() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    let queue = try DatabaseQueue(path: legacy.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO webhook (url, events) VALUES (?, ?), (?, ?)",
        arguments: [
          "https://hooks.example.com/a", #"["new-message"]"#,
          "https://hooks.example.org/b", #"["*"]"#,
        ])
    }
    try queue.close()

    let database = try appDatabase()
    let result = try await LegacyRecordMigration().run(
      from: legacy, into: database, logger: logger)
    #expect(result.webhooksImported == 2)

    let webhooks = try await WebhookRepository(database: database).all()
    #expect(
      Set(webhooks.map(\.url)) == ["https://hooks.example.com/a", "https://hooks.example.org/b"])
    let allFollow = webhooks.allSatisfy(\.followRedirects)
    #expect(allFollow, "an adopted webhook stopped following redirects")
    let specific = try #require(webhooks.first { $0.url.hasSuffix("/a") })
    #expect(specific.subscribedEvents == ["new-message"])
  }

  @Test("Running twice adds nothing and overwrites nothing")
  func importIsIdempotent() async throws {
    // A second `--migrate`, or a wizard step run again after a failure elsewhere, must not
    // duplicate a person's webhooks or re-create a message they have since cancelled.
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "later", offset: 86_400, status: "pending")
    let queue = try DatabaseQueue(path: legacy.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO webhook (url, events) VALUES (?, ?)",
        arguments: ["https://hooks.example.com/a", #"["new-message"]"#])
    }
    try queue.close()

    let database = try appDatabase()
    let migration = LegacyRecordMigration()
    _ = try await migration.run(from: legacy, into: database, logger: logger)
    let second = try await migration.run(from: legacy, into: database, logger: logger)

    #expect(second.webhooksImported == 0)
    #expect(second.webhooksAlreadyPresent == 1)
    #expect(second.scheduledImported == 0)
    let hooks = try await WebhookRepository(database: database).all()
    let messages = try await ScheduledMessageRepository(database: database).all()
    #expect(hooks.count == 1)
    #expect(messages.count == 1)
  }

  /// The case the idempotence test above cannot see. An overdue recurring row is placed at
  /// its NEXT occurrence, so the date it sits at no longer matches the legacy row's, and a
  /// re-run keyed on where the row sits imported the series a second time.
  @Test("Running twice does not duplicate an overdue recurring series")
  func advancedSeriesIsNotImportedTwice() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(
      at: legacy, message: "daily", offset: -864_000, status: "pending",
      schedule: #"{"type":"recurring","intervalType":"daily","interval":1}"#)

    let database = try appDatabase()
    let migration = LegacyRecordMigration()
    _ = try await migration.run(from: legacy, into: database, logger: logger)
    let second = try await migration.run(from: legacy, into: database, logger: logger)

    #expect(second.scheduledImported == 0)
    #expect(try await ScheduledMessageRepository(database: database).all().count == 1)
  }

  /// The key is the payload's bytes and the millisecond. It was the payload's `hashValue`,
  /// which Swift seeds per process, so the "already imported" check matched nothing on any
  /// run after the first and every scheduled message was imported, and fired, again.
  @Test("A row's identity is its bytes and its millisecond, nothing process-seeded")
  func fingerprintIsStructural() {
    let moment = Date(timeIntervalSince1970: 1_700_000_000.123)
    let payload = Data(#"{"message":"BB test"}"#.utf8)
    let key = LegacyRecordMigration.Fingerprint(payload: payload, at: moment)
    #expect(key.payload == payload)
    #expect(key.milliseconds == 1_700_000_000_123)
    // A value read back from the store a hair either side is the same row.
    #expect(
      key
        == LegacyRecordMigration.Fingerprint(
          payload: payload, at: moment.addingTimeInterval(0.0004)))
    #expect(
      key != LegacyRecordMigration.Fingerprint(payload: Data("other".utf8), at: moment))
  }

  // MARK: Detection

  @Test("An Electron install older than these tables is not an artifact to import")
  func emptyTablesAreNotAnArtifact() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    // The tables exist and are empty, which is what a person who never made a webhook has.
    #expect(!LegacyRecordMigration().hasLegacyRecords(at: legacy))
  }

  @Test("A config.db with rows is an artifact")
  func populatedTablesAreAnArtifact() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    try insertScheduled(at: legacy, message: "later", offset: 86_400, status: "pending")
    #expect(LegacyRecordMigration().hasLegacyRecords(at: legacy))
  }

  /// REGRESSION. The check opened `config.db` read-write, and a read-write open creates the
  /// file: asking whether an Electron install existed left an empty database behind where
  /// there had been none.
  @Test("Looking for an install that is not there creates nothing")
  func detectionDoesNotCreateTheFile() throws {
    let root = temporaryRoot()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("config.db")

    #expect(!LegacyRecordMigration().hasLegacyRecords(at: missing))
    #expect(
      !FileManager.default.fileExists(atPath: missing.path),
      "checking for a legacy install created its database")
  }

  @Test("No config.db at all is not a failure")
  func absentDatabaseIsSilent() async throws {
    let root = temporaryRoot()
    let missing = root.appendingPathComponent("config.db")
    let result = try await LegacyRecordMigration().run(
      from: missing, into: try appDatabase(), logger: logger)
    #expect(result.isEmpty)
  }

  // MARK: Devices

  @Test("Push registrations come across, so notifications work before a client reopens")
  func devicesAreImported() async throws {
    // The first version of this migration deliberately skipped devices, on the grounds
    // that every client re-registers on launch. What that missed is WHEN: the tokens stay
    // valid because the Firebase project migrates with them, so a server that imports can
    // notify immediately, and one that does not is silent until the person next opens the
    // app — which is what they do instead of reading a notification.
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    let queue = try DatabaseQueue(path: legacy.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO device (name, identifier, last_active) VALUES (?, ?, ?), (?, ?, ?)",
        arguments: [
          "Pixel 8 Pro", "fcm-token-simulated-0001", Int64(1_714_500_000_000),
          "Galaxy S23", "fcm-token-simulated-0002", Int64(1_714_400_000_000),
        ])
    }
    try queue.close()

    let database = try appDatabase()
    let result = try await LegacyRecordMigration().run(
      from: legacy, into: database, logger: logger)
    #expect(result.devicesImported == 2)

    let tokens = try await DeviceRepository(database: database, logger: logger).tokens()
    #expect(Set(tokens) == ["fcm-token-simulated-0001", "fcm-token-simulated-0002"])
  }

  @Test("Importing devices twice leaves one row each")
  func deviceImportIsIdempotent() async throws {
    // `DeviceRepository.register` upserts on the identifier, which is also what makes a
    // client that has already re-registered on the new server update its row rather than
    // gain a second one.
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try legacyDatabase(in: root)
    let queue = try DatabaseQueue(path: legacy.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO device (name, identifier, last_active) VALUES (?, ?, ?)",
        arguments: ["Pixel 8 Pro", "fcm-token-simulated-0001", Int64(1_714_500_000_000)])
    }
    try queue.close()

    let database = try appDatabase()
    let migration = LegacyRecordMigration()
    _ = try await migration.run(from: legacy, into: database, logger: logger)
    _ = try await migration.run(from: legacy, into: database, logger: logger)
    let devices = try await DeviceRepository(database: database, logger: logger).all()
    #expect(devices.count == 1)
  }
}

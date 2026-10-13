//  LegacyRecordMigration
//  The two tables in an Electron `config.db` that hold things a person made: the webhook
//  endpoints they registered, and the messages they scheduled.
//
//  **Why this exists at all.** The settings import reads the `config` table and nothing else,
//  so adopting an Electron install carried across every preference and left the webhooks and
//  the scheduled messages behind. Measured against a simulated install with two of each: two
//  webhooks and one scheduled message in, zero and zero out, and nothing said so. A device
//  row is different and is deliberately not imported (see below); these two are not, because
//  nothing recreates them. A webhook URL was typed by a person, and a scheduled message is
//  words they intend to send.
//
//  **The dangerous part is the scheduled messages, and it is not obvious.**
//  `ScheduledMessageRepository.due(at:)` selects `status = pending AND scheduled_for <= now`,
//  so a pending row imported with a date in the past is not merely stale — it is DUE, and the
//  next sweep sends it. Someone migrating a server months after scheduling something would
//  have had it delivered to a real person the moment the new server started. Nothing about
//  the adoption would have looked wrong.
//
//  So a pending row is placed by what its date means NOW, not by what it said then:
//
//    | Row                                   | Imported as                                |
//    |---------------------------------------|--------------------------------------------|
//    | pending, in the future                | pending — it fires when they meant it to   |
//    | pending, past, recurring              | pending at its next occurrence             |
//    | pending, past, one-shot               | failed, with a sentence saying why         |
//    | sent / failed / cancelled             | as-is: history, never dispatched           |
//
//  The recurring case goes through `ScheduledMessageService.nextOccurrence`, which already
//  answers "the next one after now" and already knows that a server which was off for a week
//  must not fire seven days of a daily schedule one tick apart. Reimplementing that here
//  would be a second answer to the same question.
//
//  **Devices ARE imported, and the first version of this file argued they should not be.**
//  That argument was: an FCM token is re-registered by every client on launch, so the list
//  refills itself and importing only copies rows about to be rewritten. What it undervalued
//  is WHEN. The tokens stay valid because the Firebase project migrates with them, so a
//  server that imports them can send a notification immediately; one that does not is silent
//  until each client is next opened — and being opened is exactly what a person does INSTEAD
//  of reading a notification. "It heals the first time you pick up your phone" describes the
//  gap rather than excusing it.
//
//  Registration goes through `DeviceRepository.register`, the same door a client uses, which
//  upserts on the identifier: a re-run, or a client that has already re-registered on the new
//  server, updates that row rather than adding a second.
//
//  Alerts are still not imported: they are the old server's notices about itself, and a
//  notice about a server that no longer exists is not worth carrying.

import BBAppStore
import BBCore
import BBPersistence
import Foundation
import GRDB
import Logging

/// Imports the webhook and scheduled-message tables from an Electron `config.db`.
struct LegacyRecordMigration: Sendable {

  /// What one run moved.
  struct Result: Sendable {
    var devicesImported = 0
    var webhooksImported = 0
    var webhooksAlreadyPresent = 0
    var scheduledImported = 0
    /// Pending one-shots whose time had already passed. Recorded rather than sent.
    var scheduledLapsed = 0

    var isEmpty: Bool {
      devicesImported == 0 && webhooksImported == 0 && webhooksAlreadyPresent == 0
        && scheduledImported == 0
    }
  }

  /// Whether there is anything here worth offering to import.
  ///
  /// The TABLES, not the file: a `config.db` with no `webhook` table is an Electron install
  /// older than the feature, not a broken one, and it must not read as an artifact that
  /// failed to import.
  ///
  /// Opened READ-ONLY, and only once the file is known to exist, for the reason `run` gives:
  /// this is a question about someone else's installation, and asking it must not change the
  /// answer. A read-write open CREATES the file when it is absent, so merely looking for an
  /// Electron install left an empty `config.db` behind on every Mac that never had one, which
  /// the next check then found and had to reason about.
  func hasLegacyRecords(at url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    var configuration = Configuration()
    configuration.readonly = true
    // A file that will not open as a database is not an install worth offering to import.
    guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else {
      return false
    }
    defer { try? queue.close() }
    let counts = try? queue.read { db -> Int in
      var total = 0
      if try db.tableExists("device") {
        total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device") ?? 0
      }
      if try db.tableExists("webhook") {
        total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webhook") ?? 0
      }
      if try db.tableExists("scheduled_message") {
        total += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduled_message") ?? 0
      }
      return total
    }
    return (counts ?? 0) > 0
  }

  /// Reads both tables and writes what belongs in each.
  ///
  /// - Parameter now: the clock, taken once so every row in a run is placed against the same
  ///   instant and so a test can state the boundary rather than wait for it.
  func run(
    from url: URL, into database: AppDatabase, logger: Logger, now: Date = Date()
  ) async throws -> Result {
    guard FileManager.default.fileExists(atPath: url.path) else { return Result() }
    // Read-only: an adoption must never be able to damage the installation it is adopting,
    // and a failed migration has to leave the old server able to run.
    var configuration = Configuration()
    configuration.readonly = true
    let legacy = try DatabaseQueue(path: url.path, configuration: configuration)
    defer { try? legacy.close() }

    var result = Result()
    result = try await importDevices(from: legacy, into: database, logger: logger, into: result)
    result = try await importWebhooks(from: legacy, into: database, logger: logger, into: result)
    result = try await importScheduled(
      from: legacy, into: database, logger: logger, now: now, into: result)
    return result
  }

  // MARK: - Devices

  private func importDevices(
    from legacy: DatabaseQueue, into database: AppDatabase, logger: Logger, into partial: Result
  ) async throws -> Result {
    var result = partial
    let rows: [(String, String, Date)] = try await legacy.read { db in
      guard try db.tableExists("device") else { return [] }
      return try Row.fetchAll(db, sql: "SELECT name, identifier, last_active FROM device")
        .compactMap { row in
          guard let name = row["name"] as String?,
            let identifier = row["identifier"] as String?, !identifier.isEmpty
          else { return nil }
          // Milliseconds, like every other date Electron writes; absent is not a reason to
          // drop a token, so it falls back to now.
          let active = LegacyScheduled.date(row["last_active"]) ?? Date()
          return (name, identifier, active)
        }
    }
    guard !rows.isEmpty else { return result }

    let repository = DeviceRepository(database: database, logger: logger)
    for (name, identifier, active) in rows {
      try await repository.register(name: name, identifier: identifier, at: active)
      result.devicesImported += 1
    }
    // Neither the name nor the identifier goes in the line: the name is usually the
    // person's own ("Zach's iPhone") and the identifier is a push token, which is a
    // credential. `DeviceRepository.register` makes the same distinction.
    logger.info(
      "Imported push devices from the previous installation",
      metadata: ["imported": .stringConvertible(result.devicesImported)])
    return result
  }

  // MARK: - Webhooks

  private func importWebhooks(
    from legacy: DatabaseQueue, into database: AppDatabase, logger: Logger, into partial: Result
  ) async throws -> Result {
    var result = partial
    let rows: [(String, String)] = try await legacy.read { db in
      guard try db.tableExists("webhook") else { return [] }
      return try Row.fetchAll(db, sql: "SELECT url, events FROM webhook")
        .compactMap { row in
          guard let url = row["url"] as String?, !url.isEmpty else { return nil }
          return (url, (row["events"] as String?) ?? "[]")
        }
    }
    guard !rows.isEmpty else { return result }

    let repository = WebhookRepository(database: database)
    let existing = Set(try await repository.all().map(\.url))
    for (url, events) in rows {
      // Keyed on the URL, which is UNIQUE on both sides, so a second run adds nothing and
      // — more importantly — does not overwrite subscriptions the person has since edited
      // on the new server.
      guard !existing.contains(url) else {
        result.webhooksAlreadyPresent += 1
        continue
      }
      // The column is a JSON array on both sides. A row this server cannot parse is taken
      // as "everything" rather than dropped: an endpoint that receives too much is visible
      // and fixable, and one that was silently not imported is neither.
      let names =
        (try? JSONSerialization.jsonObject(with: Data(events.utf8))) as? [String] ?? ["*"]
      // `followRedirects: true`, NOT the default for a new webhook, and the asymmetry is
      // the same one `InterfacesSchema.addWebhookRedirectPolicy` reasons about: a row that
      // predates the column has been following redirects, so moving it to `false` changes
      // what a working integration does on upgrade. An adopted Electron row is exactly
      // that row. The premise is checked rather than assumed — the reference posts with
      // `axios.post(url, event, { headers })` and no `maxRedirects`
      // (`webhookService/index.ts:53`), and axios follows up to five by default.
      //
      // A webhook someone creates on THIS server still starts at `false`; this is about not
      // silently changing an arrangement that already exists.
      _ = try await repository.upsert(url: url, events: names, followRedirects: true)
      result.webhooksImported += 1
    }
    logger.info(
      "Imported webhooks from the previous installation",
      metadata: [
        "imported": .stringConvertible(result.webhooksImported),
        "alreadyPresent": .stringConvertible(result.webhooksAlreadyPresent),
      ])
    return result
  }

  // MARK: - Scheduled messages

  private func importScheduled(
    from legacy: DatabaseQueue, into database: AppDatabase, logger: Logger, now: Date,
    into partial: Result
  ) async throws -> Result {
    var result = partial
    let rows: [LegacyScheduled] = try await legacy.read { db in
      guard try db.tableExists("scheduled_message") else { return [] }
      return try Row.fetchAll(
        db,
        sql: """
          SELECT type, payload, scheduled_for, schedule, status, error, sent_at, created
          FROM scheduled_message
          """
      ).compactMap(LegacyScheduled.init(row:))
    }
    guard !rows.isEmpty else { return result }

    let repository = ScheduledMessageRepository(database: database)
    // Anything already here was made on THIS server, so a second run must not duplicate
    // what the first one wrote. Matched on the payload and the original date, because the
    // legacy rows carry no identifier this server preserves.
    //
    // Keyed on the date the row was FIRST for: an overdue recurring row is placed at its
    // next occurrence below, so the date it sits at here is not the legacy row's.
    let existing = Set(
      try await repository.all().map {
        Fingerprint(payload: $0.payload, at: $0.firstScheduledFor ?? $0.scheduledFor)
      }
    )

    for row in rows {
      var record = row.record(now: now)
      guard !existing.contains(Fingerprint(payload: record.payload, at: row.scheduledFor))
      else { continue }

      // The placement rule, and the reason this migration is not a copy. See the header.
      if record.status == ScheduledMessageStatus.pending.rawValue, record.scheduledFor <= now {
        do {
          if let next = try ScheduledMessageService.nextOccurrence(
            after: record, from: now, calendar: .current)
          {
            record.scheduledFor = next
          } else {
            record.status = ScheduledMessageStatus.failed.rawValue
            record.error =
              "Not sent: this message was already overdue when the server was upgraded."
            result.scheduledLapsed += 1
          }
        } catch {
          // Imported, and failed with the reason, rather than guessed at: the same answer
          // the dispatcher gives a schedule it cannot read.
          record.status = ScheduledMessageStatus.failed.rawValue
          record.error = DiagnosticText.sentence(for: error)
          result.scheduledLapsed += 1
        }
      }
      _ = try await repository.insert(record)
      result.scheduledImported += 1
    }

    logger.info(
      "Imported scheduled messages from the previous installation",
      metadata: [
        "imported": .stringConvertible(result.scheduledImported),
        "lapsed": .stringConvertible(result.scheduledLapsed),
      ])
    return result
  }

  /// Identity for a legacy row, which carries none this server keeps.
  ///
  /// The payload and the date it was FIRST for: the text and the moment together are what a
  /// person would call the same scheduled message, and neither survives editing on the new
  /// server, which is what makes a re-run leave an edited row alone.
  ///
  /// The payload's BYTES, never its `hashValue`: Swift seeds hashing per process, so a key
  /// built from one matched nothing on the next run, and a re-run imported every scheduled
  /// message again, each to fire again.
  struct Fingerprint: Hashable {
    let payload: Data
    let milliseconds: Int64

    /// Nearest, not truncated: the legacy value arrived as whole milliseconds and was
    /// divided into seconds, and stored and read back it can land a hair either side.
    init(payload: Data, at moment: Date) {
      self.payload = payload
      self.milliseconds = moment.epochMilliseconds(rounded: .toNearestOrAwayFromZero)
    }
  }
}

/// One row of the Electron `scheduled_message` table, before it is placed.
private struct LegacyScheduled {
  let type: String
  let payload: Data
  let scheduledFor: Date
  let schedule: Data?
  let status: String
  let error: String?
  let sentAt: Date?
  let createdAt: Date

  init?(row: Row) {
    guard let type = row["type"] as String?,
      let payload = row["payload"] as String?,
      let scheduledFor = LegacyScheduled.date(row["scheduled_for"])
    else { return nil }
    self.type = type
    self.payload = Data(payload.utf8)
    self.scheduledFor = scheduledFor
    self.schedule = (row["schedule"] as String?).map { Data($0.utf8) }
    // An unrecognised status is taken as `failed` rather than `pending`: the whole point of
    // the placement rule is that nothing this import does not understand can cause a send.
    let raw = (row["status"] as String?) ?? ""
    self.status =
      ScheduledMessageStatus(rawValue: raw)?.rawValue ?? ScheduledMessageStatus.failed.rawValue
    self.error = row["error"] as String?
    self.sentAt = LegacyScheduled.date(row["sent_at"])
    self.createdAt = LegacyScheduled.date(row["created"]) ?? scheduledFor
  }

  /// Electron writes these through an `EpochDateTransformer`, so they are milliseconds since
  /// 1970 held in a column typed `date`. SQLite keeps whatever it was given, so the value
  /// arrives as a number or as the text of one.
  static func date(_ value: DatabaseValue?) -> Date? {
    guard let value else { return nil }
    if let milliseconds = Int64.fromDatabaseValue(value) {
      return Date(epochMilliseconds: Double(milliseconds))
    }
    if let text = String.fromDatabaseValue(value), let milliseconds = Double(text) {
      return Date(epochMilliseconds: milliseconds)
    }
    return nil
  }

  func record(now: Date) -> ScheduledMessage {
    ScheduledMessage(
      id: nil,
      type: type,
      payload: payload,
      scheduledFor: scheduledFor,
      schedule: schedule,
      status: status,
      error: error,
      sentAt: sentAt,
      createdAt: createdAt,
      // The series counts from where it STARTED, not from where this row happens to sit;
      // see `ScheduledMessageService.nextOccurrence` on why a monthly message made for the
      // 31st must count from January and not from the February it was clamped into.
      firstScheduledFor: scheduledFor
    )
  }
}

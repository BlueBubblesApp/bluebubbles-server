//  AppDatabase
//  The server's own store. Ours to design, migrate and write.
//
//  Uses a proper linear DatabaseMigrator, fixing the current strategy where
//  `synchronize: !fs.existsSync(dbPath)` creates a fresh schema that NEVER records the
//  migrations as applied, with `migrationsRun` set to its inverse — so a new install and an
//  upgraded install end up in different states and neither knows it.
//
//  See `.claude/docs/database.md`.

import Foundation
import GRDB

public struct AppDatabase: Sendable {

  /// Deliberately NOT public.
  ///
  /// `read` and `write` are the whole access surface, and the omission below them is the
  /// point: there is no `readSynchronously`. GRDB's `DatabaseQueue` offers both a sync and
  /// an async `read`, and the async one requires a `Sendable` result — so a closure
  /// returning `[Row]`, which borrows the statement's storage and is not `Sendable`,
  /// silently resolves to the SYNCHRONOUS overload and blocks the caller while still
  /// reading as `await`. Through here that same closure fails to compile instead.
  ///
  /// That is not hypothetical. The only two types that held a raw queue —
  /// `SettingsStore` and `LegacyConfigMigration` — are the only two that hit it, and both
  /// carry a comment about mapping inside the closure to steer the overload. None of the
  /// sixty-nine call sites that went through here ever could.
  let queue: DatabaseQueue

  /// Wraps a queue this type did not open. `open` and `inMemory` are the usual entry
  /// points; this exists for callers that need their own `Configuration`.
  public init(queue: DatabaseQueue) {
    self.queue = queue
  }

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/bluebubbles-server/app.db")
  }

  public static func open(at url: URL = defaultURL) throws -> AppDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    let database = AppDatabase(queue: queue)
    try database.migrate()
    return database
  }

  /// In-memory, for tests.
  public static func inMemory() throws -> AppDatabase {
    let queue = try DatabaseQueue()
    let database = AppDatabase(queue: queue)
    try database.migrate()
    return database
  }

  /// Migrations are append-only and never edited once released — editing one means two
  /// installs on the same version have different schemas.
  public func migrate() throws {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("createSettings") { db in
      try db.create(table: "setting") { table in
        table.column("key", .text).primaryKey()
        table.column("value", .blob).notNull()
        table.column("type_tag", .text).notNull()
        table.column("is_secret", .boolean).notNull().defaults(to: false)
        table.column("updated_at", .datetime).notNull()
      }
    }

    migrator.registerMigration("createAlerts") { db in
      try db.create(table: "alert") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("uuid", .text).notNull().unique()
        table.column("severity", .text).notNull()
        table.column("title", .text).notNull()
        table.column("body", .text).notNull()
        table.column("source", .text).notNull()
        table.column("diagnostics", .blob)
        table.column("dedupe_key", .text).indexed()
        table.column("occurrence_count", .integer).notNull().defaults(to: 1)
        table.column("created_at", .datetime).notNull()
        table.column("last_occurred_at", .datetime).notNull()
        table.column("read_at", .datetime)
        table.column("dismissed_at", .datetime)
      }
    }

    migrator.registerMigration("createDevices") { db in
      try db.create(table: "device") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("name", .text).notNull()
        table.column("identifier", .text).notNull().unique()
        table.column("last_active", .datetime)
        // Per-target codec negotiation (§ 4). Null means legacy-v1.
        table.column("supported_codecs", .text)
        table.column("public_key", .blob)
      }
    }

    migrator.registerMigration("createWebhooks") { db in
      try db.create(table: "webhook") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("url", .text).notNull().unique()
        table.column("events", .text).notNull()
        table.column("created_at", .datetime).notNull()
      }
    }

    migrator.registerMigration("createContactIndex") { db in
      // Contacts merged from macOS Contacts, Google and the local table into ONE
      // indexed table, resolved once at index time rather than per request.
      try db.create(table: "contact") { table in
        table.column("id", .text).primaryKey()
        table.column("source", .integer).notNull()
        table.column("first_name", .text)
        table.column("last_name", .text)
        table.column("display_name", .text)
        table.column("nickname", .text)
        table.column("birthday", .text)
        table.column("external_id", .text).indexed()
        table.column("updated_at", .datetime).notNull()
      }

      try db.create(table: "contact_address") { table in
        table.column("normalized", .text).notNull()
        // The normalized address REVERSED. SQLite can range-scan a prefix but not a
        // suffix, and the match we need is "ends with these N digits" — so we store
        // it backwards and the suffix match becomes a prefix range on the index.
        table.column("reversed", .text).notNull()
        table.column("kind", .integer).notNull()
        table.column("contact_id", .text)
          .notNull()
          .references("contact", onDelete: .cascade)
        table.primaryKey(["normalized", "contact_id"])
      }

      // THE index that matters. It turns the "last N digits" phone match from four
      // full scans over a map rebuilt per call into four indexed range probes — and
      // that lookup runs once per handle during message serialization.
      try db.create(
        index: "idx_contact_address_reversed", on: "contact_address", columns: ["reversed"]
      )
    }

    migrator.registerMigration("addContactAddressRawAndAccount") { db in
      // The stored `normalized` address is lossy by design — it strips everything that
      // is not alphanumeric so that "+1 (555) 010-1234" and "5550101234" collide on
      // lookup. It was also the ONLY thing stored, so every read handed the stripped
      // form back: `person.name@example.com` came out of GET /api/v1/contact as
      // `personnameexamplecom`. `raw` keeps what was actually entered.
      //
      // Nullable with no backfill because there is nothing to backfill FROM. Existing
      // rows read as they did before until the next re-index rewrites them.
      try db.alter(table: "contact_address") { table in
        table.add(column: "raw", .text)
      }

      // Which account in Contacts a record synced from — iCloud, Google, on this Mac.
      // Distinct from `source`, which says only "address book" vs "our own API" and is
      // frozen into the wire format as db/api.
      try db.alter(table: "contact") { table in
        table.add(column: "account_kind", .text)
        table.add(column: "account_name", .text)
      }
    }

    migrator.registerMigration("createScheduledMessages") { db in
      try db.create(table: "scheduled_message") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("type", .text).notNull()
        table.column("payload", .blob).notNull()
        table.column("scheduled_for", .datetime).notNull().indexed()
        table.column("schedule", .blob)
        table.column("status", .text).notNull()
        table.column("error", .text)
        table.column("sent_at", .datetime)
        table.column("created_at", .datetime).notNull()
      }
    }

    // Client-supplied blobs the server only stores and hands back: theme definitions and
    // settings bundles from the mobile app. Deliberately opaque — the server has no
    // reason to parse a client's theme, and parsing it would make every client-side
    // format change a server release.
    migrator.registerMigration("createBackups") { db in
      try db.create(table: "backup") { table in
        table.autoIncrementedPrimaryKey("id")
        // "theme" or "settings". Both live in one table because they differ only by
        // kind, and two identical tables would drift.
        table.column("kind", .text).notNull()
        table.column("name", .text).notNull()
        table.column("payload", .blob).notNull()
        table.column("created_at", .datetime).notNull()
        table.uniqueKey(["kind", "name"])
      }
    }

    migrator.registerMigration("createAccessControl") { db in
      // Blocklist persists so a restart is not an accidental unblock, and an admin
      // can see what happened while they were away (§ 17).
      try db.create(table: "blocked_client") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("address", .text).notNull().unique()
        table.column("reason", .text).notNull()
        table.column("failure_count", .integer).notNull().defaults(to: 0)
        table.column("first_seen", .datetime).notNull()
        table.column("last_seen", .datetime).notNull()
        table.column("blocked_at", .datetime).notNull()
        table.column("expires_at", .datetime)
        table.column("is_permanent", .boolean).notNull().defaults(to: false)
      }

      try db.create(table: "allowed_client") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("cidr", .text).notNull().unique()
        table.column("note", .text)
        table.column("created_at", .datetime).notNull()
      }

      // Bounded ring, so an attack is visible before it trips a block.
      try db.create(table: "auth_failure") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("address", .text).notNull().indexed()
        table.column("at", .datetime).notNull().indexed()
        table.column("path", .text)
        table.column("reason", .text)
      }
    }

    // Added separately rather than folded into `createAccessControl`: installs created
    // before this shipped have already run that migration, and editing it would leave
    // them without the column while the schema version claimed otherwise.
    migrator.registerMigration("addBlockOffenceCount") { db in
      // Escalation state. Without persisting it a repeat offender restarts at the base
      // lockout after every server restart, which is the one thing escalation exists
      // to prevent.
      try db.alter(table: "blocked_client") { table in
        table.add(column: "offence_count", .integer).notNull().defaults(to: 1)
      }
    }

    // Appended, never edited into `createAlerts`: migrations are append-only, and an
    // install that already ran the original has to get this column by migrating rather
    // than by having history rewritten under it.
    //
    // Defaults to true because every alert raised before this existed was a fact rather
    // than a live condition as far as anything can now tell, and true is the reading that
    // keeps information rather than discarding it.
    migrator.registerMigration("addAlertDurability") { db in
      try db.alter(table: "alert") { table in
        table.add(column: "is_durable", .boolean).notNull().defaults(to: true)
      }
    }

    migrator.registerMigration("createPairedClients") { db in
      // Token auth (§ 5). Created regardless so the schema is stable, but no rows
      // exist and no endpoint is registered while auth_mode is `password`.
      try db.create(table: "paired_client") { table in
        table.column("client_id", .text).primaryKey()
        table.column("secret_hash", .text).notNull()
        table.column("device_name", .text).notNull()
        table.column("platform", .text)
        table.column("scopes", .text).notNull()
        table.column("public_key", .blob)
        table.column("created_at", .datetime).notNull()
        table.column("last_seen", .datetime)
        table.column("revoked_at", .datetime)
      }
    }

    // Every datetime column in the schema says WHEN something happened with an `_at`
    // suffix. Six did not, and five of those were plain drift — `first_seen`, `last_seen`,
    // `last_active`, and a column literally called `at`. The drift was not cosmetic: it
    // reached clients, because `blocked_client` is serialized field-for-field onto
    // `/api/v2/server/security/blocklist`, where `first_seen` and `blocked_at` sat next to
    // each other as two timestamps spelled two ways.
    //
    // `scheduled_message.scheduled_for` is deliberately NOT renamed. `_at` records when an
    // event happened; `_for` states a time something is aimed at, which has not happened
    // and may never. See docs/NAMING.md.
    migrator.registerMigration("normaliseTimestampColumnNames") { db in
      try db.alter(table: "blocked_client") { table in
        table.rename(column: "first_seen", to: "first_seen_at")
        table.rename(column: "last_seen", to: "last_seen_at")
      }
      try db.alter(table: "device") { table in
        table.rename(column: "last_active", to: "last_active_at")
      }
      try db.alter(table: "paired_client") { table in
        table.rename(column: "last_seen", to: "last_seen_at")
      }
      try db.alter(table: "auth_failure") { table in
        table.rename(column: "at", to: "occurred_at")
      }
    }

    try migrator.migrate(queue)
  }

  public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    try await queue.read(block)
  }

  public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
    try await queue.write(block)
  }

  /// Blocking write, for callers that genuinely cannot suspend.
  ///
  /// There is exactly one: the Contacts ingest runs inside
  /// `CNContactStore.enumerateContacts`, a synchronous callback we do not control and
  /// cannot await from. Without this the ingest has to buffer the whole address book to
  /// write it afterwards, which defeats the point of streaming it in the first place.
  ///
  /// Do not reach for this anywhere else. It blocks the calling thread on the database
  /// queue, and from inside an actor that stalls every other caller of that actor.
  public func writeSynchronously<T>(_ block: (Database) throws -> T) throws -> T {
    try queue.write(block)
  }
}

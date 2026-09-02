//  InterfacesSchema
//  The tables the interfaces layer owns, declared by the module that owns them.
//
//  `alert`, `device`, `webhook`, `scheduled_message` and `backup` — each one has its
//  repository in this target and had its `CREATE TABLE` in BBPersistence, two layers down.
//
//  Every identifier keeps its exact original spelling. These are rows in `grdb_migrations` on
//  every install in the field; renaming one would make it look unapplied and re-run
//  `CREATE TABLE` against a table that already exists. See
//  `SchemaContributor.legacyMigrationIdentifiers`.
//
//  `device.last_active` is renamed to `last_active_at` by `normaliseTimestampColumnNames`,
//  which is NOT here: it renames columns across this module and BBAuth in a single released
//  migration, so it stays in `AppDatabase` as the frozen tail and runs after every
//  contributor. See `AppDatabase.registerFrozenTail`.
//
//  See `.claude/docs/database.md`.

import BBPersistence
import Foundation
import GRDB

public enum InterfacesSchema: SchemaContributor {

  public static let schemaNamespace = "interfaces"

  /// All predate namespacing — see the file header.
  public static let legacyMigrationIdentifiers: Set<String> = [
    "createAlerts", "createDevices", "createWebhooks", "createScheduledMessages",
    "createBackups", "addAlertDurability",
  ]

  public static func registerSchema(in migrator: inout DatabaseMigrator) {
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
        // Per-target codec negotiation. Null means legacy-v1.
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
  }
}

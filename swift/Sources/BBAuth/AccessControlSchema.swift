//  AccessControlSchema
//  The access-control tables, declared by the module that owns them.
//
//  `blocked_client`, `allowed_client`, `auth_failure` and `paired_client` — all read and
//  written only by this target, and declared here rather than in BBPersistence two layers
//  down.
//
//  Every identifier keeps its exact original spelling, because each is a row in
//  `grdb_migrations` on every install in the field. See
//  `SchemaContributor.legacyMigrationIdentifiers`.
//
//  The `_at` renames on three of these tables live in `normaliseTimestampColumnNames`, which
//  is NOT here: one released migration renames columns across this module and BBInterfaces
//  together and cannot be split, so it stays in `AppDatabase` as the frozen tail and runs
//  after every contributor. Its renames are guarded on the table existing, which is what lets
//  this schema be used on its own. See `AppDatabase.registerFrozenTail`.
//
//  See `docs/AUTH.md` and `.claude/docs/database.md`.

import BBPersistence
import Foundation
import GRDB

public enum AccessControlSchema: SchemaContributor {

  public static let schemaNamespace = "auth"

  /// All predate namespacing — see the file header.
  public static let legacyMigrationIdentifiers: Set<String> = [
    "createAccessControl", "addBlockOffenceCount", "createPairedClients",
  ]

  public static func registerSchema(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createAccessControl") { db in
      // Blocklist persists so a restart is not an accidental unblock, and an admin
      // can see what happened while they were away.
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

    migrator.registerMigration("createPairedClients") { db in
      // Token auth. Created regardless so the schema is stable, but no rows
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
  }
}

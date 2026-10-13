//  AccessControlSchema
//  The access-control tables, declared by the module that owns them.
//
//  `blocked_client`, `allowed_client`, `auth_failure` and `paired_client`: all read and
//  written only by this target, and declared here rather than in BBPersistence two layers
//  down.
//
//  Every identifier keeps its exact original spelling, because each is a row in
//  `grdb_migrations` on every install in the field. See
//  `SchemaContributor.legacyMigrationIdentifiers`.
//
//  The `_at` renames on three of these tables live in `normaliseTimestampColumnNames`, which
//  is NOT here: one released migration renames columns across this module and BBInterfaces
//  together and cannot be split, so it stays in `AppDatabase`, which runs it after every
//  migration registered here and before anything in `registerSchema`. Its renames are guarded
//  on the table existing, which is what lets this schema be used on its own. See
//  `AppDatabase.registerTimestampRename`.
//
//  See `docs/AUTH.md` and `.claude/docs/database.md`.

import BBPersistence
import Foundation
import GRDB

public enum AccessControlSchema: SchemaContributor {

  public static let schemaNamespace = "auth"

  /// All predate namespacing; see the file header.
  public static let legacyMigrationIdentifiers: Set<String> = [
    "createAccessControl", "addBlockOffenceCount", "createPairedClients",
  ]

  public static func registerSchemaBeforeTimestampRename(in migrator: inout DatabaseMigrator) {
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

      // Bounded ring, so an attack is visible before it trips a block. Superseded by
      // `auth.relaxAuthFailureAddress` below, which is where the live shape is; this body is
      // frozen because it has run on every install in the field.
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

    // `auth_failure.address` must be NULLABLE, because a failure that could not be
    // attributed to an address is exactly the one worth keeping: it is the global-throttling
    // case, and `AuthFailureRecord.address` has always been optional to say so.
    //
    // Recreated rather than altered, and that is safe here in a way it would not be for any
    // other table in this file: `createAccessControl` declared `auth_failure` and then
    // NOTHING ever inserted into it, on any install, for the whole life of the table. There
    // are no rows to preserve anywhere. SQLite cannot drop a NOT NULL constraint in place,
    // and the twelve-step table rebuild it otherwise takes buys nothing when the table is
    // provably empty.
    //
    // A released migration is still never edited: `createAccessControl` keeps its exact
    // original body, and this runs after it.
    //
    // **The timestamp column keeps whichever name it already has, and that is load-bearing.**
    // `normaliseTimestampColumnNames` renames this table's `at` to `occurred_at`, and it is
    // registered after this one, so on a fresh install it has not run yet when this does,
    // while on an existing install it may have run long before and GRDB will not run it
    // again. Hard-coding either name therefore diverges — a fresh database would
    // end up with one spelling and an upgraded one with the other, which is the kind of
    // schema drift that shows up much later as a query that works on exactly one machine.
    // Preserving what is there converges both on `occurred_at`:
    //
    //   - fresh:    `at` here, renamed by the tail afterwards      -> occurred_at
    //   - existing: already `occurred_at`, tail does not re-run    -> occurred_at
    //
    // `SchemaContributionTests.frozenTailIsGuarded` is what holds this: it asserts
    // `occurred_at` is present and `at` is not, on an auth-only fresh database.
    migrator.registerMigration("auth.relaxAuthFailureAddress") { db in
      let timestampColumn =
        try db.columns(in: "auth_failure").map(\.name).contains("occurred_at")
        ? "occurred_at" : "at"
      try db.drop(table: "auth_failure")
      try db.create(table: "auth_failure") { table in
        table.autoIncrementedPrimaryKey("id")
        // Nullable: see above.
        table.column("address", .text).indexed()
        table.column(timestampColumn, .datetime).notNull().indexed()
        table.column("path", .text)
        table.column("reason", .text)
      }
    }
  }
}

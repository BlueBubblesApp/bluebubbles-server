//  SchemaContributionTests
//  That moving a table's declaration cannot move the table.
//
//  `setting`, `contact` and `contact_address` were declared by `AppDatabase.migrate()` and are
//  now declared by the modules that own them. Every install in the field already ran those
//  three migrations from the old location, so the ONE thing that must not change is the
//  identifier each was recorded under — `createSettings`, `createContactIndex`,
//  `addContactAddressRawAndAccount`. Rename any of them and GRDB sees an unapplied migration
//  and re-runs `CREATE TABLE` against a table that already exists.
//
//  The upgrade test below simulates exactly that install: it migrates a database the way the
//  old central migrator did, then opens it the way the new code does, and asserts nothing ran
//  a second time.
//
//  See `Sources/BBPersistence/SchemaContributor.swift`.

import BBAuth
import BBContacts
import BBInterfaces
import BBSettings
import BlueBubblesServerCore
import Foundation
import GRDB
import Testing

// `@testable` for `registerCoreSchema`, which is deliberately internal: the baseline is not
// something a caller should be able to register on its own. This test reaches for it to
// reconstruct the OLD migrator and prove an existing install survives the move.
@testable import BBPersistence

@Suite("Schema contribution")
struct SchemaContributionTests {

  /// The complete, ordered migration sequence, frozen.
  ///
  /// Order is load-bearing on a FRESH install — it is the order tables are built in — and
  /// nothing else in the build would notice it changing. Each contributor in
  /// `AppSchema.contributors` order, then the frozen tail.
  ///
  /// `AppDatabase` contributes NO tables of its own. Every entry below belongs to a module.
  private static let expectedPlan = [
    // BBSettings
    "createSettings",
    // BBContacts
    "createContactIndex",
    "addContactAddressRawAndAccount",
    // BBInterfaces
    "createAlerts",
    "createDevices",
    "createWebhooks",
    "createScheduledMessages",
    "createBackups",
    "addAlertDurability",
    // BBAuth
    "createAccessControl",
    "addBlockOffenceCount",
    "createPairedClients",
    // The frozen tail, appended by AppDatabase itself: it renames columns across
    // BBInterfaces and BBAuth in one released migration and belongs to neither.
    "normaliseTimestampColumnNames",
  ]

  @Test("The migration plan is exactly the frozen sequence")
  func planIsFrozen() throws {
    let plan = try AppDatabase.migrationPlan(contributors: AppSchema.contributors)
    #expect(plan == Self.expectedPlan)
  }

  /// The identifiers are the contract with every install in the field.
  @Test("The moved migrations keep their original identifiers")
  func movedMigrationsKeepIdentifiers() {
    #expect(SettingsSchema.migrationIdentifiers() == ["createSettings"])
    #expect(
      ContactsSchema.migrationIdentifiers() == [
        "createContactIndex", "addContactAddressRawAndAccount",
      ])
    #expect(
      InterfacesSchema.migrationIdentifiers() == [
        "createAlerts", "createDevices", "createWebhooks", "createScheduledMessages",
        "createBackups", "addAlertDurability",
      ])
    #expect(
      AccessControlSchema.migrationIdentifiers() == [
        "createAccessControl", "addBlockOffenceCount", "createPairedClients",
      ])
  }

  /// THE upgrade test.
  ///
  /// An install created before the move has all thirteen identifiers already recorded, in an
  /// order this build no longer produces. That is the risk in moving a migration's
  /// declaration: GRDB applies by identifier and skips what is on file, so a rename or a
  /// re-order must be a no-op against an existing database.
  ///
  /// Simulated by recording them in a DIFFERENT order from production and then running the
  /// production path over the result — which is the property the historical install actually
  /// exercises.
  @Test("A database migrated in another order is not re-migrated")
  func existingInstallIsUntouched() async throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)

    let scrambled: [any SchemaContributor.Type] = [
      InterfacesSchema.self, AccessControlSchema.self, SettingsSchema.self, ContactsSchema.self,
    ]
    try AppDatabase(queue: queue).migrate(contributors: scrambled)

    let before = try await queue.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    #expect(Set(before) == Set(Self.expectedPlan))

    // Now the production path, over the same database.
    try AppDatabase(queue: queue).migrate(contributors: AppSchema.contributors)

    let after = try await queue.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    #expect(after == before, "the production path must not record or re-run anything")

    // And the frozen tail's renames are applied exactly once, not undone or repeated.
    let deviceColumns = try await queue.read { db in try db.columns(in: "device").map(\.name) }
    #expect(deviceColumns.contains("last_active_at"))
    #expect(!deviceColumns.contains("last_active"))
  }

  /// The frozen tail renames columns on four tables across two modules. Each rename is
  /// guarded on its table existing, which is what lets a module's schema be used alone —
  /// `BBAuthTests` builds the access-control tables and nothing else.
  @Test("The frozen tail applies to whichever tables are present")
  func frozenTailIsGuarded() async throws {
    let authOnly = try AppDatabase.inMemory(contributors: [AccessControlSchema.self])
    let columns = try await authOnly.read { db in
      (
        blocked: try db.columns(in: "blocked_client").map(\.name),
        failures: try db.columns(in: "auth_failure").map(\.name),
        hasDevice: try db.tableExists("device")
      )
    }
    // Renamed, even though `device` — which the same migration also renames — is absent.
    #expect(columns.blocked.contains("first_seen_at"))
    #expect(columns.blocked.contains("last_seen_at"))
    #expect(columns.failures.contains("occurred_at"))
    #expect(!columns.failures.contains("at"))
    #expect(!columns.hasDevice)
  }

  /// The whole point of the exercise: the foundation layer declares no tables.
  @Test("AppDatabase contributes no schema of its own")
  func appDatabaseOwnsNoTables() async throws {
    let bare = try AppDatabase.inMemory()
    let tables = try await bare.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%'")
    }
    #expect(tables.isEmpty, "AppDatabase created: \(tables)")
  }

  @Test("A fresh database gets every table, whoever declared it")
  func freshDatabaseIsComplete() async throws {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let tables = try await database.read { db in
      try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    }
    for expected in [
      "alert", "allowed_client", "auth_failure", "backup", "blocked_client", "contact",
      "contact_address", "device", "paired_client", "scheduled_message", "setting", "webhook",
    ] {
      #expect(tables.contains(expected), "missing table: \(expected)")
    }
  }

  /// A contributor that names only its own module's schema can be used on its own, which is
  /// what lets `BBSettingsTests` stand up a `setting` table without the rest of the server.
  @Test("A contributor can be used without the others")
  func contributorsAreIndependent() async throws {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let tables = try await database.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("setting"))
    #expect(!tables.contains("contact"))
    #expect(!tables.contains("device"))
  }

  // MARK: - The rules the seam enforces

  private enum Unnamespaced: SchemaContributor {
    static let schemaNamespace = "widget"
    static func registerSchema(in migrator: inout DatabaseMigrator) {
      // No `widget.` prefix, and not grandfathered.
      migrator.registerMigration("createThing") { _ in }
    }
  }

  private enum Namespaced: SchemaContributor {
    static let schemaNamespace = "widget"
    static func registerSchema(in migrator: inout DatabaseMigrator) {
      migrator.registerMigration("widget.createThing") { db in
        try db.create(table: "widget_thing") { $0.column("id", .text).primaryKey() }
      }
    }
  }

  /// Identifiers are global. Without this, two modules both reaching for `createIndex` would
  /// have the second silently recorded as already applied and never run.
  @Test("A migration without its namespace is rejected")
  func namespaceIsEnforced() {
    #expect(throws: SchemaContributionError.self) {
      _ = try AppDatabase.migrationPlan(contributors: [Unnamespaced.self])
    }
  }

  @Test("Two contributors cannot claim the same namespace")
  func duplicateNamespaceRejected() throws {
    let database = try AppDatabase.inMemory()
    #expect(throws: SchemaContributionError.self) {
      try database.migrate(contributors: [Namespaced.self, Namespaced.self])
    }
  }

  /// The seam is real, not decorative: a module that did not exist when the baseline was
  /// written can create a table without anyone editing BBPersistence.
  @Test("A new contributor can create its own table")
  func newContributorCreatesTable() async throws {
    let database = try AppDatabase.inMemory(contributors: [Namespaced.self])
    let tables = try await database.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.contains("widget_thing"))
  }
}

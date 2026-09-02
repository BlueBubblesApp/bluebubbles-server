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

  /// - Parameter contributors: The modules that own tables here, in a FIXED order. See
  ///   `migrate(contributors:)` — this order is part of the schema and must not be
  ///   rearranged once a release has shipped with it.
  public static func open(
    at url: URL = defaultURL,
    contributors: [any SchemaContributor.Type] = []
  ) throws -> AppDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: contributors)
    return database
  }

  /// In-memory, for tests.
  ///
  /// Takes contributors for the same reason `open` does: a test that needs a module's
  /// tables asks for that module's schema. A test target that names none gets the core
  /// baseline alone, which is what every existing caller wanted and still gets.
  public static func inMemory(
    contributors: [any SchemaContributor.Type] = []
  ) throws -> AppDatabase {
    let queue = try DatabaseQueue()
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: contributors)
    return database
  }

  /// Migrations are append-only and never edited once released — editing one means two
  /// installs on the same version have different schemas.
  ///
  /// Two phases, and the split is deliberate:
  ///
  ///   1. **The core baseline below.** History, and immutable. It stays here rather than
  ///      moving to the modules that own these tables because of ONE migration:
  ///      `normaliseTimestampColumnNames` renames columns on `device` (BBInterfaces) and on
  ///      `blocked_client`, `paired_client` and `auth_failure` (BBAuth) in a single step.
  ///      A released migration cannot be split — the identifier is already recorded on
  ///      every install — so those two modules' tables cannot leave until it is dealt with.
  ///      `setting` and the contact tables are not touched by it, and have moved out.
  ///
  ///   2. **Contributed schema**, registered after it, in the order given.
  ///
  /// - Parameter contributors: Registered in the order supplied, after the baseline. That
  ///   order is part of the schema on a FRESH install and must stay stable across releases.
  ///   It is safe to reorder relative to an EXISTING install — GRDB applies by identifier
  ///   and skips what is recorded — but a fresh install would build its tables in the new
  ///   order, so treat the list as append-only too.
  public func migrate(contributors: [any SchemaContributor.Type] = []) throws {
    var migrator = DatabaseMigrator()

    // Namespaces checked before anything runs: a collision would have one contributor's
    // migration recorded under another's identifier and silently never applied.
    var seen: Set<String> = []
    for contributor in contributors {
      guard seen.insert(contributor.schemaNamespace).inserted else {
        throw SchemaContributionError.duplicateNamespace(contributor.schemaNamespace)
      }
      try contributor.validateSchemaNamespace()
    }
    for contributor in contributors {
      contributor.registerSchema(in: &migrator)
    }
    Self.registerFrozenTail(in: &migrator)

    try migrator.migrate(queue)
  }

  /// Every migration this database would run, in order, without touching a database.
  ///
  /// Exists for the test that freezes the sequence. Reordering migrations across a release
  /// is invisible in review and changes what a fresh install builds.
  public static func migrationPlan(
    contributors: [any SchemaContributor.Type] = []
  ) throws -> [String] {
    var migrator = DatabaseMigrator()
    for contributor in contributors {
      try contributor.validateSchemaNamespace()
      contributor.registerSchema(in: &migrator)
    }
    registerFrozenTail(in: &migrator)
    return migrator.migrations
  }

  /// The one migration that could not move to a module, applied last.
  ///
  /// `normaliseTimestampColumnNames` renames columns on `device` (BBInterfaces) and on
  /// `blocked_client`, `paired_client` and `auth_failure` (BBAuth) in a SINGLE step. It has
  /// shipped, so its identifier is recorded on every install and it cannot be split into one
  /// migration per module — there would be two new identifiers where one old one is on file,
  /// and both would re-run.
  ///
  /// So it stays here, as the last thing registered, and each rename is guarded on the table
  /// being present. On any real database that guard is always true: every install ran the
  /// creates before this, so the behaviour is exactly what it has always been. What the guard
  /// buys is a PARTIAL contributor set — `BBAuthTests` can stand up the access-control tables
  /// alone and still get its renames, without also building the BBInterfaces schema to
  /// satisfy one `ALTER` it does not care about.
  ///
  /// Registered by `migrate` unconditionally rather than being a contributor callers pass.
  /// A caller who forgot it would get un-renamed columns and no error, which is a silent
  /// data bug — so it is not theirs to forget.
  private static func registerFrozenTail(in migrator: inout DatabaseMigrator) {
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
      if try db.tableExists("blocked_client") {
        try db.alter(table: "blocked_client") { table in
          table.rename(column: "first_seen", to: "first_seen_at")
          table.rename(column: "last_seen", to: "last_seen_at")
        }
      }
      if try db.tableExists("device") {
        try db.alter(table: "device") { table in
          table.rename(column: "last_active", to: "last_active_at")
        }
      }
      if try db.tableExists("paired_client") {
        try db.alter(table: "paired_client") { table in
          table.rename(column: "last_seen", to: "last_seen_at")
        }
      }
      if try db.tableExists("auth_failure") {
        try db.alter(table: "auth_failure") { table in
          table.rename(column: "at", to: "occurred_at")
        }
      }
    }
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

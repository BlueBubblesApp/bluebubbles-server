//  AppDatabase
//  The server's own store. Ours to design, migrate and write.
//
//  Uses a proper linear DatabaseMigrator, fixing the reference's strategy where
//  `synchronize: !fs.existsSync(dbPath)` creates a fresh schema that NEVER records the
//  migrations as applied, with `migrationsRun` set to its inverse, so a new install and an
//  upgraded install end up in different states and neither knows it.
//
//  See `.claude/docs/database.md`.

import BBCore
import Foundation
import GRDB

public struct AppDatabase: Sendable {

  /// Deliberately NOT public.
  ///
  /// `read` and `write` are the whole access surface, and the omission below them is the
  /// point: there is no `readSynchronously`. GRDB's `DatabaseQueue` offers both a sync and
  /// an async `read`, and the async one requires a `Sendable` result, so a closure
  /// returning `[Row]`, which borrows the statement's storage and is not `Sendable`,
  /// silently resolves to the SYNCHRONOUS overload and blocks the caller while still
  /// reading as `await`. Through here that same closure fails to compile instead.
  let queue: DatabaseQueue

  /// Wraps a queue this type did not open. `open` and `inMemory` are the usual entry
  /// points; this exists for callers that need their own `Configuration`.
  public init(queue: DatabaseQueue) {
    self.queue = queue
  }

  public static var defaultURL: URL { ApplicationSupport.appDatabase }

  /// How long a write waits for another connection before giving up.
  ///
  /// GRDB's default is `.immediateError`, which throws the instant `app.db` is held by anyone
  /// else. Nothing hits that in normal operation: `SingleInstanceLock` stops two servers, and
  /// `AppModel.start` hands the same `Storage` to `build` rather than opening a second
  /// connection, but there is one path that skips the lock ON PURPOSE:
  /// `--clear-blocklist` opens the database before acquiring it, because an admin locked out by
  /// a bad access rule needs recovery to work while the server is up. Without a timeout that
  /// recovery fails with "database is locked" precisely when it is needed, and the person
  /// running it has no way to know it was a transient collision rather than a broken flag.
  ///
  /// Five seconds is far longer than any write here (settings rows and small deletes, all of
  /// them milliseconds) and short enough that a genuinely stuck database still reports rather
  /// than hanging. It is a ceiling, not a delay: an uncontended write does not wait at all.
  ///
  /// A timeout only covers `SQLITE_BUSY`. It does nothing for `SQLITE_IOERR_LOCK`, which is a
  /// different failure with a different cause; see `.claude/docs/database.md` on the chat.db
  /// fixtures.
  static let busyTimeout: TimeInterval = 5

  /// Shared by `open` and `inMemory`, so the two cannot drift.
  ///
  /// The timeout is meaningless for an in-memory database, which no other connection can
  /// reach, and is applied anyway rather than maintaining two configurations that differ in a
  /// way nobody would remember to keep deliberate.
  static func configuration() -> Configuration {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(busyTimeout)
    return configuration
  }

  /// - Parameter contributors: The modules that own tables here, in a FIXED order. See
  ///   `migrate(contributors:)`: this order is part of the schema and must not be
  ///   rearranged once a release has shipped with it.
  public static func open(
    at url: URL = defaultURL,
    contributors: [any SchemaContributor.Type] = []
  ) throws -> AppDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let queue = try DatabaseQueue(path: url.path, configuration: configuration())
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
    let queue = try DatabaseQueue(configuration: configuration())
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: contributors)
    return database
  }

  /// Migrations are append-only and never edited once released: editing one means two
  /// installs on the same version have different schemas.
  ///
  /// Two phases, and the split is deliberate:
  ///
  ///   1. **The core baseline below.** History, and immutable. It stays here rather than
  ///      moving to the modules that own these tables because of ONE migration:
  ///      `normaliseTimestampColumnNames` renames columns on `device` (BBInterfaces) and on
  ///      `blocked_client`, `paired_client` and `auth_failure` (BBAuth) in a single step.
  ///      A released migration cannot be split: the identifier is already recorded on
  ///      every install, so those two modules' tables cannot leave until it is dealt with.
  ///      `setting` and the contact tables are not touched by it, and have moved out.
  ///
  ///   2. **Contributed schema**, registered after it, in the order given.
  ///
  /// - Parameter contributors: Registered in the order supplied, after the baseline. That
  ///   order is part of the schema on a FRESH install and must stay stable across releases.
  ///   It is safe to reorder relative to an EXISTING install (GRDB applies by identifier
  ///   and skips what is recorded) but a fresh install would build its tables in the new
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
  /// migration per module: there would be two new identifiers where one old one is on file,
  /// and both would re-run.
  ///
  /// So it stays here, as the last thing registered, and each rename is guarded on the table
  /// being present. On any real database that guard is always true: every install ran the
  /// creates before this, so the behaviour is exactly what it has always been. What the guard
  /// buys is a PARTIAL contributor set: `BBAuthTests` can stand up the access-control tables
  /// alone and still get its renames, without also building the BBInterfaces schema to
  /// satisfy one `ALTER` it does not care about.
  ///
  /// Registered by `migrate` unconditionally rather than being a contributor callers pass.
  /// A caller who forgot it would get un-renamed columns and no error, which is a silent
  /// data bug, so it is not theirs to forget.
  private static func registerFrozenTail(in migrator: inout DatabaseMigrator) {
    // Every datetime column in the schema says WHEN something happened with an `_at`
    // suffix. This renames the ones that did not: `first_seen`, `last_seen`,
    // `last_active`, and a column literally called `at`. The inconsistency reaches
    // clients, because `blocked_client` is serialized field-for-field onto
    // `/api/v2/server/security/blocklist`.
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

  /// A read, re-run after every commit that touches what it read.
  ///
  /// GRDB tracks the region the fetch observed and re-fetches when a write lands on it, so
  /// this is how a screen follows a table instead of re-reading it on a timer, which is
  /// the rule the app holds itself to (`Sources/BlueBubblesApp/CLAUDE.md`, "followed, never
  /// polled"). The first element is the current value, so a follower needs no seed read of
  /// its own. Any write path counts, including the HTTP API and the command line.
  public func observe<T: Sendable>(
    _ fetch: @escaping @Sendable (Database) throws -> T
  ) -> AsyncValueObservation<T> {
    ValueObservation.tracking(fetch).values(in: queue)
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

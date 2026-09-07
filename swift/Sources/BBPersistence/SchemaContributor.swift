//  SchemaContributor
//  How a module declares the tables it owns.
//
//  Creating every table in `app.db` from one function in THIS target — the lowest in the
//  graph — would put the schema for `setting` (BBSettings), `contact` (BBContacts),
//  `device`/`webhook`/`alert` (BBInterfaces) and `blocked_client` (BBAuth) below every module
//  that owns them. Two consequences, and the second is the one that matters:
//
//    1. Adding a persisted feature to a module means editing the foundation layer. That
//       dependency is invisible to `Tools/package-graph/check.py`, because it is knowledge
//       coupling rather than an import — the check passes cleanly either way.
//    2. A service could not have storage AT ALL. `ServiceMigration` lets a service migrate
//       its own settings FIELDS, but with no seam for a table, "this service needs somewhere
//       to keep things" has no answer short of a core patch. That is the half of the plugin
//       model this provides.
//
//  A contributor is a module's answer to "what do you store". It registers onto the shared
//  migrator, so there is still ONE migration history and one `grdb_migrations` table — this
//  is about who declares a migration, not about giving anyone their own database.
//
//  ORDER. Migrations are applied in registration order, and `AppDatabase` registers the core
//  baseline first and then each contributor in the order it was given. Within a contributor,
//  its own declared order holds. Cross-contributor ordering is therefore the caller's to fix
//  and must stay stable — see `AppDatabase.migrate`.
//
//  See `.claude/docs/database.md`.

import Foundation
import GRDB

/// A module that owns tables in the application database.
///
/// Implemented as a static requirement rather than an instance: a schema is a fact about a
/// module, not about any object it builds, and nothing needs to exist before the database
/// does. It is also what lets the composition root name contributors as types in a list
/// without constructing anything.
/// `Sendable` so a list of contributor METATYPES can be a `static let` — the composition
/// root holds exactly that, and a non-Sendable metatype makes it a concurrency warning.
public protocol SchemaContributor: Sendable {

  /// Prefix every migration this contributor registers must carry.
  ///
  /// Namespacing is not decoration. Migration identifiers are global — they are rows in one
  /// `grdb_migrations` table — so two modules that both reach for `createIndex` would
  /// silently collide, and the second would be recorded as already applied and never run.
  /// `AppDatabase` rejects a contributor whose migrations do not carry its namespace, so
  /// that failure is a precondition at startup rather than a missing table later.
  static var schemaNamespace: String { get }

  /// Identifiers that predate namespacing and must keep the exact name already recorded.
  ///
  /// These are migrations that shipped from the central migrator before schema became
  /// contributable. Their identifiers are rows in `grdb_migrations` on every install in the
  /// field, so renaming one to carry a namespace would make it look unapplied — and it
  /// would then re-run `CREATE TABLE` against a table that already exists.
  ///
  /// Empty for anything written after this seam existed, which is why it defaults to empty:
  /// a new contributor should never need it, and needing it is a sign a released migration
  /// is being renamed.
  static var legacyMigrationIdentifiers: Set<String> { get }

  /// Registers this module's migrations, in the order they must run.
  ///
  /// Append-only, exactly as the core baseline is: never edit one that has shipped, because
  /// an install that already ran it will not run it again and would end up with a different
  /// schema from a fresh one on the same version.
  static func registerSchema(in migrator: inout DatabaseMigrator)
}

/// Rejected before any migration runs.
public enum SchemaContributionError: Error, CustomStringConvertible {
  /// Two contributors claim the same namespace, so their migration identifiers could
  /// collide.
  case duplicateNamespace(String)
  /// A migration identifier that does not begin with its contributor's namespace.
  case unnamespacedMigration(namespace: String, identifier: String)
  /// An empty or malformed namespace. A namespace has to be a usable identifier prefix.
  case malformedNamespace(String)

  public var description: String {
    switch self {
    case .duplicateNamespace(let namespace):
      "Two schema contributors both claim the namespace '\(namespace)'."
    case .unnamespacedMigration(let namespace, let identifier):
      "Migration '\(identifier)' must begin with its contributor's namespace '\(namespace).'."
    case .malformedNamespace(let namespace):
      "'\(namespace)' is not a usable schema namespace: expected letters, digits or "
        + "underscores."
    }
  }
}

extension SchemaContributor {

  public static var legacyMigrationIdentifiers: Set<String> { [] }

  /// The migrations this contributor registers, by identifier, in order.
  ///
  /// Used by `AppDatabase` to enforce the namespace, and by the test that freezes the
  /// application's whole migration sequence — reordering migrations across a release is the
  /// one change here that is invisible in review and destructive in the field.
  public static func migrationIdentifiers() -> [String] {
    var migrator = DatabaseMigrator()
    registerSchema(in: &migrator)
    return migrator.migrations
  }

  /// Checks the namespace rule without touching a database.
  static func validateSchemaNamespace() throws {
    let namespace = schemaNamespace
    guard !namespace.isEmpty,
      namespace.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
    else {
      throw SchemaContributionError.malformedNamespace(namespace)
    }
    let grandfathered = legacyMigrationIdentifiers
    for identifier in migrationIdentifiers()
    where !identifier.hasPrefix("\(namespace).") && !grandfathered.contains(identifier) {
      throw SchemaContributionError.unnamespacedMigration(
        namespace: namespace, identifier: identifier
      )
    }
  }
}

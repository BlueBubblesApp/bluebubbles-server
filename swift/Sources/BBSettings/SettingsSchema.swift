//  SettingsSchema
//  The `setting` table, declared by the module that owns it.
//
//  Moved out of `AppDatabase.migrate()`, where it had lived since the first commit. Nothing
//  about the table changed — the migration identifier is `createSettings`, character for
//  character, because that string is a row in `grdb_migrations` on every install in the
//  field. See `SchemaContributor.legacyMigrationIdentifiers`.
//
//  See `.claude/docs/database.md`.

import BBPersistence
import Foundation
import GRDB

/// `setting` belongs to BBSettings. `SettingsStore` is the only thing that reads or writes it.
public enum SettingsSchema: SchemaContributor {

  public static let schemaNamespace = "settings"

  /// Predates namespacing — see the file header.
  public static let legacyMigrationIdentifiers: Set<String> = ["createSettings"]

  public static func registerSchema(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createSettings") { db in
      try db.create(table: "setting") { table in
        table.column("key", .text).primaryKey()
        table.column("value", .blob).notNull()
        table.column("type_tag", .text).notNull()
        table.column("is_secret", .boolean).notNull().defaults(to: false)
        table.column("updated_at", .datetime).notNull()
      }
    }
  }
}

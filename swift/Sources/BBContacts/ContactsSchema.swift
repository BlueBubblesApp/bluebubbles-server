//  ContactsSchema
//  The contact index tables, declared by the module that owns them.
//
//  Moved out of `AppDatabase.migrate()` unchanged. Both migration identifiers keep their
//  exact original spelling — `createContactIndex` and `addContactAddressRawAndAccount` are
//  rows in `grdb_migrations` on every install in the field, so renaming either would make it
//  look unapplied and re-run `CREATE TABLE` against tables that already exist. See
//  `SchemaContributor.legacyMigrationIdentifiers`.
//
//  These two are safe to move and the BBAuth/BBInterfaces tables are not, for one reason:
//  `normaliseTimestampColumnNames` — a single released migration — renames columns across
//  `device`, `blocked_client`, `paired_client` and `auth_failure` at once, and a released
//  migration cannot be split. It touches nothing here.
//
//  See `.claude/docs/database.md`.

import BBPersistence
import Foundation
import GRDB

/// `contact` and `contact_address` belong to BBContacts. `ContactIndex` is the only thing
/// that reads or writes them.
public enum ContactsSchema: SchemaContributor {

  public static let schemaNamespace = "contacts"

  /// Both predate namespacing — see the file header.
  public static let legacyMigrationIdentifiers: Set<String> = [
    "createContactIndex", "addContactAddressRawAndAccount",
  ]

  public static func registerSchema(in migrator: inout DatabaseMigrator) {
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
  }
}

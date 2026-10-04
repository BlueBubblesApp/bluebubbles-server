//  AuditSchema
//  The `audit_event` table, declared by the module that owns it.
//
//  One table, append-mostly: rows are inserted by the recorder, read by the page and the
//  exporters, and deleted only by the retention sweep. Every column of the envelope is a
//  column rather than a key inside the JSON, so the common filters (time, category, kind,
//  actor, outcome) are indexed and a query over a year of records does not parse a year of
//  JSON; only the kind-specific `metadata` is a document.
//
//  Namespaced from the first migration, as every contributor written after the seam is.
//
//  See `.claude/docs/database.md` and `docs/AUDIT_LOG.md`.

import BBPersistence
import Foundation
import GRDB

public enum AuditSchema: SchemaContributor {

  public static let schemaNamespace = "audit"

  public static func registerSchema(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("audit.createAuditEvent") { db in
      try db.create(table: "audit_event") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("uuid", .text).notNull().unique()
        table.column("occurred_at", .datetime).notNull()
        table.column("category", .text).notNull().indexed()
        table.column("kind", .text).notNull().indexed()
        table.column("outcome", .text).notNull()
        table.column("severity", .text).notNull()
        table.column("actor_kind", .text).notNull()
        table.column("actor_id", .text)
        table.column("source", .text).notNull()
        table.column("request_id", .text)
        table.column("route", .text)
        table.column("subject_kind", .text)
        table.column("subject_id", .text)
        table.column("summary", .text).notNull()
        // JSON. `{}` for a kind with nothing to add, never NULL, so a reader can parse the
        // column unconditionally.
        table.column("metadata", .text).notNull()
        table.column("schema_version", .integer).notNull()
      }
      // The page reads newest first and the sweep deletes oldest first; both walk this.
      try db.create(
        indexOn: "audit_event", columns: ["occurred_at", "id"], options: [], condition: nil)
    }
  }
}

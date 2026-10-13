//  AuditSchema
//  The `audit_event` table, declared by the module that owns it.
//
//  One table, append-mostly: rows are inserted by the recorder, read by the page and the
//  exporters, and deleted only by the retention sweep. Every column of the envelope is a
//  column rather than a key inside the JSON, so a filter on one is a column comparison and a
//  query over a year of records does not parse a year of JSON; only the kind-specific
//  `metadata` is a document. Indexed: time, category by time, and kind.
//
//  Namespaced from the first migration, as every contributor written after the seam is.
//
//  See `.claude/docs/database.md` and `docs/AUDIT_LOG.md`.

import BBPersistence
import Foundation
import GRDB

public enum AuditSchema: SchemaContributor {

  public static let schemaNamespace = "audit"

  public static func registerSchemaBeforeTimestampRename(in migrator: inout DatabaseMigrator) {
    migrator.registerMigration("audit.createAuditEvent") { db in
      try db.create(table: "audit_event") { table in
        table.autoIncrementedPrimaryKey("id")
        // NOT unique, and not indexed. Nothing here looks a record up by it: it is the key a
        // RECEIVER deduplicates on, in its own store. Every other index on this table is in
        // age order, so the retention sweep deleting oldest first touches pages at one end
        // of each; a random UUID's index has the oldest rows on every page, and measured, it
        // made a 5,000-row delete take 160 to 500 ms where it takes 6 ms without, all of it
        // holding `app.db`'s writer.
        table.column("uuid", .text).notNull()
        table.column("occurred_at", .datetime).notNull()
        table.column("category", .text).notNull().indexed()
        table.column("kind", .text).notNull().indexed()
        table.column("outcome", .text).notNull()
        table.column("severity", .text).notNull()
        table.column("actor_kind", .text).notNull()
        table.column("actor_id", .text)
        table.column("source", .text).notNull()
        // Not indexed either, for the reason `uuid` is not: it is a random UUID per request,
        // and an index on it would put the oldest rows on every page the sweep deletes from.
        // Joining a request to what it caused is a receiver's query, run in its own store.
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

    // The page filtered by category, newest first. With only `category` indexed, SQLite found
    // the category's rows and then sorted all of them for the newest hundred: measured at a
    // million rows, 151 ms for authentication and 906 ms for API requests, all of it holding
    // the queue every `app.db` reader shares. Ordered by time within the category, the page is
    // the index's last hundred entries: 1.5 ms and 20 ms. The sweep pays about 3 ms more per
    // 5,000-row batch, because the rows it deletes sit at one end of each category's range.
    //
    // It costs about 41 bytes a row. The single-column index it replaces is a prefix of it,
    // which SQLite already stopped choosing once both existed, so dropping that one gives back
    // 12 of those bytes: net, about 6% of the table.
    migrator.registerMigration("audit.indexCategoryByTime") { db in
      try db.create(
        indexOn: "audit_event", columns: ["category", "occurred_at", "id"], options: [],
        condition: nil)
      try db.drop(index: "audit_event_on_category")
    }
  }
}

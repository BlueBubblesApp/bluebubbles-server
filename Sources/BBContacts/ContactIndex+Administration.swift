//  ContactIndex+Administration
//  What the person running the server changes about the index: which contacts are served,
//  and removing the ones clients uploaded.
//
//  A pure move out of `ContactIndex.swift`, along the seam between answering lookups and
//  administering what they answer with. Nothing here is on the lookup hot path.

import BBCore
import BBPersistence
import Foundation
import GRDB

extension ContactIndex {

  /// Switches contacts off, or back on.
  ///
  /// Recorded by id, which survives a re-index: `reindexAll` deletes and re-inserts every
  /// address-book row, and this table is deliberately not joined to it by a cascading key.
  /// A contact deleted from the address book therefore leaves its row here, and gets its
  /// setting back if it ever returns — which is the behaviour somebody who unlinked an
  /// account and relinked it would expect.
  public func setEnabled(_ enabled: Bool, ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await database.write { db in
      try Self.record(enabled, ids: ids, in: db)
    }
    // The resolution cache holds records keyed by address, so a contact switched off while
    // its name is cached would go on being served until the entry expired. Five minutes of
    // a setting appearing not to work is worse than dropping a cache nobody is timing.
    lookupCache.removeAll()
  }

  /// Switches every contact shown under one Account label off, or back on.
  ///
  /// Matched on the label the table DISPLAYS — the account name, falling back to the account
  /// kind and then to the source — so "disable everything from Google" means what the person
  /// reading that column thinks it means. `ContactOrder.account` sorts by the same expression,
  /// so the group a bulk action covers is exactly the block the sort puts together.
  ///
  /// It applies to the contacts that exist NOW. A contact synced later into an account that
  /// was bulk-disabled arrives enabled, because every contact is enabled by default and a
  /// stored per-account rule would be a second source of truth about the same question.
  @discardableResult
  public func setEnabled(_ enabled: Bool, accountLabel: String) async throws -> Int {
    let changed = try await database.write { db -> Int in
      let expression = ContactOrder.account.expression
      let ids = try String.fetchAll(
        db, sql: "SELECT c.id FROM contact c WHERE \(expression) = ?",
        arguments: [accountLabel])
      guard !ids.isEmpty else { return 0 }
      try Self.record(enabled, ids: ids, in: db)
      return ids.count
    }
    lookupCache.removeAll()
    return changed
  }

  /// Writes the switch for `ids`: deletes their rows from `contact_disabled` to switch them on,
  /// inserts one each to switch them off. Both `setEnabled` forms go through here, so a
  /// contact switched off one way is switched back on by the other.
  ///
  /// `DO NOTHING` on a contact already off, so `disabled_at` keeps the time it was FIRST
  /// switched off rather than the latest time somebody pressed the button.
  private static func record(_ enabled: Bool, ids: [String], in db: Database) throws {
    if enabled {
      let placeholders = SQLPlaceholders.list(ids.count)
      try db.execute(
        sql: "DELETE FROM contact_disabled WHERE contact_id IN (\(placeholders))",
        arguments: StatementArguments(ids))
    } else {
      let now = Date()
      for id in ids {
        try db.execute(
          sql: """
            INSERT INTO contact_disabled (contact_id, disabled_at) VALUES (?, ?)
            ON CONFLICT(contact_id) DO NOTHING
            """, arguments: [id, now])
      }
    }
  }

  /// Every Account label in the index, with how many contacts carry it, for the bulk control.
  public func accountLabels() async throws -> [(label: String, count: Int)] {
    try await database.read { db in
      let expression = ContactOrder.account.expression
      return try Row.fetchAll(
        db,
        sql: """
          SELECT \(expression) AS label, COUNT(*) AS total
          FROM contact c GROUP BY label ORDER BY label ASC
          """
      ).map { (label: $0["label"] as String, count: $0["total"] as Int) }
    }
  }

  /// How many contacts came from `source`, counting the ones switched off.
  ///
  /// Counted with the switched-off ones because this is what a bulk removal of that source
  /// would remove, and a figure that leaves some out is a confirmation that undercounts.
  public func count(source: ContactSource) async throws -> Int {
    try await database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM contact WHERE source = ?",
        arguments: [source.rawValue]) ?? 0
    }
  }

  /// Deletes every contact a client created (`.local`), and says how many went.
  ///
  /// **The address book is untouched by construction**: every account configured in
  /// Contacts — iCloud, Google, on this Mac — is `.macOS`, and the predicate names only
  /// `.local`. This exists to recover an index a client has flooded, such as one built by an
  /// address-book sync that ran before `mergeLocal` folded re-sent contacts together and
  /// left a copy of the whole book per sync.
  ///
  /// The contacts' switches go with them, unlike a re-index of the address book: a
  /// client-created id is a fresh UUID, so a switch naming one can never name anything again.
  /// Addresses cascade.
  ///
  /// One transaction, so a lookup sees all of them or none of them.
  @discardableResult
  public func removeClientContacts() async throws -> Int {
    let removed = try await database.write { db -> Int in
      let source = ContactSource.local.rawValue
      try db.execute(
        sql: """
          DELETE FROM contact_disabled
          WHERE contact_id IN (SELECT id FROM contact WHERE source = ?)
          """, arguments: [source])
      try db.execute(sql: "DELETE FROM contact WHERE source = ?", arguments: [source])
      // The contact rows alone: SQLite does not count what a foreign key cascades to.
      return db.changesCount
    }
    lookupCache.removeAll()
    return removed
  }
}

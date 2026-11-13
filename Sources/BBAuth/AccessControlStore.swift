//  AccessControlStore
//  The durable half of access control.
//
//  Blocks, allowlists and the recent-failure ring live in `app.db` and are read and written
//  here. Durability is the whole point of this type, and each thing it buys is invisible
//  until it is missing:
//
//    - An allowlist an administrator curated survives a restart. Without that the feature is
//      worse than not having it: it appears to work, then quietly stops.
//    - "Restart the server" is not an accidental unblock-everyone: a block outlives the
//      process.
//    - `--clear-blocklist`, the documented lockout recovery, and the stated reason the
//      Security admin routes can stay off by default, operates on the stored blocklist. A
//      fresh in-memory service would clear nothing and print success.
//    - Failures that never reached the block threshold survive a restart, which is the
//      whole point of keeping them: the pattern an administrator needs to see is the one
//      building up BEFORE anything is blocked, and restarting the server is the most
//      likely thing they do while investigating one.
//
//  See `docs/AUTH.md`.

import BBPersistence
import Foundation
import GRDB

public struct AccessControlStore: AccessControlPersistence {

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func loadAccessControl() async throws -> (
    blocked: [BlockedClient], allowlist: [AllowedClient]
  ) {
    try await database.read { db in
      let blocked = try Row.fetchAll(
        db,
        sql: """
          SELECT address, reason, failure_count, first_seen_at, last_seen_at,
                 blocked_at, expires_at, is_permanent, offence_count
          FROM blocked_client
          """
      ).map(BlockedClient.init(row:))

      let allowlist = try Row.fetchAll(
        db,
        sql: """
          SELECT cidr, note, created_at FROM allowed_client
          """
      ).map(AllowedClient.init(row:))

      return (blocked, allowlist)
    }
  }

  /// Replaces the table wholesale.
  ///
  /// A full rewrite rather than a diff because the in-memory set is the authority and it
  /// is small (bounded by `AccessControlService.addressMemoryLimit`). Reconciling row by
  /// row would be more code for the sole purpose of introducing a way for the two to
  /// disagree.
  public func saveBlocked(_ blocked: [BlockedClient]) async throws {
    try await database.write { db in try Self.write(blocked: blocked, db: db) }
  }

  public func saveAllowlist(_ allowlist: [AllowedClient]) async throws {
    try await database.write { db in try Self.write(allowlist: allowlist, db: db) }
  }

  /// Replaces both lists in one transaction, for a restore into a server that is not
  /// running.
  ///
  /// One transaction because the two are restored as one decision: a failure between two
  /// writes would leave the archive's blocklist beside this server's own allowlist, which
  /// is neither machine's configuration. A RUNNING server is restored through its
  /// `AccessControlService` instead (`replaceAdministeredLists`), because a write beneath it
  /// is overwritten by its next change.
  public func replace(blocked: [BlockedClient], allowlist: [AllowedClient]) async throws {
    try await database.write { db in
      try Self.write(blocked: blocked, db: db)
      try Self.write(allowlist: allowlist, db: db)
    }
  }

  private static func write(blocked: [BlockedClient], db: Database) throws {
    try db.execute(sql: "DELETE FROM blocked_client")
    for entry in blocked {
      try db.execute(
        sql: """
          INSERT INTO blocked_client
              (address, reason, failure_count, first_seen_at, last_seen_at,
               blocked_at, expires_at, is_permanent, offence_count)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          entry.address, entry.reason, entry.failureCount,
          entry.firstSeen, entry.lastSeen, entry.blockedAt,
          entry.expiresAt, entry.isPermanent, entry.offenceCount,
        ]
      )
    }
  }

  private static func write(allowlist: [AllowedClient], db: Database) throws {
    try db.execute(sql: "DELETE FROM allowed_client")
    for entry in allowlist {
      try db.execute(
        sql: "INSERT INTO allowed_client (cidr, note, created_at) VALUES (?, ?, ?)",
        arguments: [entry.cidr, entry.note, entry.createdAt]
      )
    }
  }

  /// The newest `limit` failures, oldest first.
  ///
  /// Ordered to match the in-memory ring (`recentFailures` appends and trims from the
  /// front), so a restore is an assignment rather than a re-sort. `ORDER BY occurred_at`
  /// DESC picks
  /// the newest when there are more rows than asked for; the reversal puts them back.
  public func loadFailures(limit: Int) async throws -> [AuthFailureRecord] {
    try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT address, occurred_at, path, reason FROM auth_failure
          ORDER BY occurred_at DESC, id DESC LIMIT ?
          """,
        arguments: [max(0, limit)]
      ).reversed().map { row in
        // The id is minted fresh rather than stored: it identifies a row to a SwiftUI list
        // for the life of one process and means nothing across a restart. Persisting it
        // would imply a stability it does not have.
        AuthFailureRecord(
          id: UUID(),
          address: row["address"],
          at: row["occurred_at"],
          path: row["path"],
          reason: row["reason"]
        )
      }
    }
  }

  /// Replaces the table wholesale, for the reason `saveBlocked` gives.
  ///
  /// The row count is bounded by the caller (`AccessControlPolicy.failureHistoryLimit`),
  /// and the write itself is debounced, because unlike blocks the arrival rate here is
  /// chosen by whoever is attacking. See `AccessControlService.failureWriteInterval`.
  public func saveFailures(_ failures: [AuthFailureRecord]) async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM auth_failure")
      for entry in failures {
        try db.execute(
          sql: """
            INSERT INTO auth_failure (address, occurred_at, path, reason)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [entry.address, entry.at, entry.path, entry.reason]
        )
      }
    }
  }

  /// Empties the blocklist without building a server.
  ///
  /// Static, and touching only the table, because this is the path someone takes when the
  /// API has locked them out; it has to work when whatever broke is still broken.
  public static func clearBlocklist(database: AppDatabase) async throws -> Int {
    try await database.write { db in
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blocked_client") ?? 0
      try db.execute(sql: "DELETE FROM blocked_client")
      return count
    }
  }
}

// MARK: - Rows

extension BlockedClient {

  /// A `blocked_client` row, and the one reading of that table: the store's load and a
  /// restored archive's rows both come through here.
  ///
  /// Each column is DECODED, which throws on a value of the wrong kind, rather than read
  /// through the subscript, which traps on one. An archive is a file from outside this
  /// server, and a hand-edited `failure_count` must refuse the section rather than end the
  /// process. The three columns the schema gives a default take that default when a row
  /// does not carry them, as an `INSERT` naming only the other columns would.
  public init(row: Row) throws {
    // `is_permanent` is the authority, not the null-ness of `expires_at`: a permanent row
    // with a stale expiry would otherwise expire itself.
    let isPermanent = try row.decode(Bool?.self, forColumn: "is_permanent") ?? false
    let expiresAt = try row.decode(Date?.self, forColumn: "expires_at")
    self.init(
      address: try row.decode(String.self, forColumn: "address"),
      reason: try row.decode(String.self, forColumn: "reason"),
      failureCount: try row.decode(Int?.self, forColumn: "failure_count") ?? 0,
      firstSeen: try row.decode(Date.self, forColumn: "first_seen_at"),
      lastSeen: try row.decode(Date.self, forColumn: "last_seen_at"),
      blockedAt: try row.decode(Date.self, forColumn: "blocked_at"),
      expiresAt: isPermanent ? nil : expiresAt,
      offenceCount: try row.decode(Int?.self, forColumn: "offence_count") ?? 1
    )
  }
}

extension AllowedClient {

  /// An `allowed_client` row, decoded for the reason `BlockedClient.init(row:)` gives.
  public init(row: Row) throws {
    self.init(
      cidr: try row.decode(String.self, forColumn: "cidr"),
      note: try row.decode(String?.self, forColumn: "note"),
      createdAt: try row.decode(Date.self, forColumn: "created_at")
    )
  }
}

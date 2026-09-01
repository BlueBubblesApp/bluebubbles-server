//  AccessControlStore
//  The durable half of access control.
//
//  The tables have existed since the Phase 3 migration and nothing ever read or wrote them.
//  Three things followed from that, and all three were invisible:
//
//    - An allowlist an administrator curated was lost on every restart, which makes the
//      feature worse than not having it: it appears to work, then quietly stops.
//    - "Restart the server" became an accidental unblock-everyone, so a block was only ever
//      as durable as the process.
//    - `--clear-blocklist` — the documented lockout recovery, and the stated reason the
//      Security admin routes can stay off by default — built a fresh in-memory service,
//      cleared its empty blocklist, and printed success. It could not have worked.
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
      ).map { row in
        let isPermanent: Bool = row["is_permanent"]
        return BlockedClient(
          id: UUID(),
          address: row["address"],
          reason: row["reason"],
          failureCount: row["failure_count"],
          firstSeen: row["first_seen_at"],
          lastSeen: row["last_seen_at"],
          blockedAt: row["blocked_at"],
          // `is_permanent` is the authority, not the null-ness of `expires_at`:
          // a permanent row with a stale expiry would otherwise expire itself.
          expiresAt: isPermanent ? nil : row["expires_at"],
          offenceCount: row["offence_count"]
        )
      }

      let allowlist = try Row.fetchAll(
        db,
        sql: """
          SELECT cidr, note, created_at FROM allowed_client
          """
      ).map { row in
        AllowedClient(
          cidr: row["cidr"], note: row["note"], createdAt: row["created_at"]
        )
      }

      return (blocked, allowlist)
    }
  }

  /// Replaces the table wholesale.
  ///
  /// A full rewrite rather than a diff because the in-memory set is the authority and it
  /// is small — bounded by `AccessControlService.addressMemoryLimit`. Reconciling row by
  /// row would be more code for the sole purpose of introducing a way for the two to
  /// disagree.
  public func saveBlocked(_ blocked: [BlockedClient]) async throws {
    try await database.write { db in
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
  }

  public func saveAllowlist(_ allowlist: [AllowedClient]) async throws {
    try await database.write { db in
      try db.execute(sql: "DELETE FROM allowed_client")
      for entry in allowlist {
        try db.execute(
          sql: "INSERT INTO allowed_client (cidr, note, created_at) VALUES (?, ?, ?)",
          arguments: [entry.cidr, entry.note, entry.createdAt]
        )
      }
    }
  }

  /// Empties the blocklist without building a server.
  ///
  /// Static, and touching only the table, because this is the path someone takes when the
  /// API has locked them out — it has to work when whatever broke is still broken.
  public static func clearBlocklist(database: AppDatabase) async throws -> Int {
    try await database.write { db in
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM blocked_client") ?? 0
      try db.execute(sql: "DELETE FROM blocked_client")
      return count
    }
  }
}

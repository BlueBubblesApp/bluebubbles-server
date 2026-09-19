//  AppDatabaseContentionTests
//  Two connections to one `app.db`, which is a supported situation and used to throw.
//
//  GRDB's `Configuration.busyMode` defaults to `.immediateError`, so a write to a database
//  another connection is holding fails at once rather than waiting. Normal operation never
//  reaches that: `SingleInstanceLock` stops two servers and `AppModel.start` reuses one
//  `Storage`, but `--clear-blocklist` opens `app.db` BEFORE acquiring the lock, deliberately,
//  so that an admin locked out by a bad access rule can recover while the server is running.
//
//  Which makes this the one place the default was actively wrong: the recovery path failing
//  with "database is locked" exactly when it is needed, and reporting it as though the flag
//  were broken.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBSettings

@Suite("App database contention")
struct AppDatabaseContentionTests {

  private func temporaryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-contention-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("app.db")
  }

  /// Every NOT NULL column, because a constraint failure inside the holder thread is invisible:
  /// it throws, the signal never fires, and the test deadlocks rather than failing.
  private static let insert = """
    INSERT OR REPLACE INTO setting (key, value, type_tag, is_secret, updated_at)
    VALUES (?, ?, 'string', 0, '2026-01-01 00:00:00')
    """

  /// The `--clear-blocklist` shape: a second connection writing while the first holds the
  /// database. It must wait, not throw.
  ///
  /// Synchronous throughout: `DispatchSemaphore.wait` is unavailable from an async context,
  /// and blocking a real thread is what the production path does anyway.
  @Test("A write waits for another connection instead of failing")
  func writeWaitsRatherThanThrowing() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let first = try AppDatabase.open(at: url, contributors: [SettingsSchema.self])
    let second = try AppDatabase.open(at: url, contributors: [SettingsSchema.self])

    // The first connection holds a write transaction briefly, standing in for a running server
    // mid-write. No explicit BEGIN: `writeSynchronously` is already inside a transaction and
    // nesting one deadlocks. The INSERT escalates it to a write lock; the sleep holds it.
    let holding = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    let holderError = ErrorBox()
    Thread.detachNewThread {
      // `holding` is signalled in a `defer` so a failure here surfaces as a failed expectation
      // rather than as a hang. Swallowing it with `try?` cost an afternoon.
      defer {
        holding.signal()
        released.signal()
      }
      do {
        try first.writeSynchronously { db in
          try db.execute(sql: Self.insert, arguments: ["holder", "1"])
          holding.signal()
          Thread.sleep(forTimeInterval: 0.3)
        }
      } catch { holderError.value = error }
    }
    holding.wait()
    #expect(holderError.value == nil, "the holder failed: \(holderError.value as Any)")

    // Under `.immediateError` this throws instantly. It should instead wait the hold out.
    let started = Date()
    try second.writeSynchronously { db in
      try db.execute(sql: Self.insert, arguments: ["contention_probe", "written"])
    }
    let waited = Date().timeIntervalSince(started)
    released.wait()

    let stored = try second.writeSynchronously { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM setting WHERE key = ?", arguments: ["contention_probe"])
    }
    #expect(stored == "written")
    // Proves it actually contended. Without this the test would pass under `.immediateError`
    // too, on any run where the second write happened to land before the lock was taken.
    #expect(waited > 0.1, "the write never contended, so this proves nothing")
  }

  /// The timeout is a ceiling, not a delay; an uncontended write must not pay for it.
  @Test("An uncontended write does not wait")
  func uncontendedWriteIsImmediate() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let database = try AppDatabase.open(at: url, contributors: [SettingsSchema.self])
    let started = Date()
    try database.writeSynchronously { db in
      try db.execute(sql: Self.insert, arguments: ["probe", "1"])
    }
    #expect(Date().timeIntervalSince(started) < 1, "a free database was made to wait")
  }
}

/// Carries an error out of a detached thread.
private final class ErrorBox: @unchecked Sendable {
  var value: (any Error)?
}

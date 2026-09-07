//  ChatFixtureCopy
//  A working copy of a chat.db fixture, in the journal mode Messages actually uses.
//
//  **Why this exists at all.** The committed fixtures are in rollback-journal mode, because
//  `Tools/chatdb-fixtures/generate.py` never sets one and SQLite's default is `delete`. A real
//  `chat.db` is in WAL — Messages puts it there, and the file header says so. That difference
//  is invisible until a test opens the file TWICE, once read-only through `ReadOnlyDatabase`
//  and once writable to stand in for Messages, which is exactly what the hydration tests do.
//
//  In rollback-journal mode a reader's SHARED lock blocks a writer, and with both connections
//  in one process SQLite answers `BEGIN IMMEDIATE` with `SQLITE_IOERR_LOCK` (extended 3850) —
//  reported as "SQLite error 10: disk I/O error". Measured: 100% of attempts in that mode,
//  0% in WAL. It looked load-dependent only because load widened the window in which the
//  reader's transaction and the writer's overlapped; the conflict itself is not a race.
//
//  A busy timeout does NOT fix it, which is worth stating because it was the standing theory.
//  `Configuration.busyMode` retries `SQLITE_BUSY`. This is `SQLITE_IOERR`, and it is returned
//  immediately whatever the busy handler says.
//
//  **The order below is load-bearing.** The writable connection is opened FIRST and returned
//  to the caller to hold, because a read-only connection cannot create the `-shm` file a WAL
//  database needs: open one against a WAL file with no sidecars and it fails with
//  `SQLITE_CANTOPEN`. The sidecars exist only while some connection holds them, so the writer
//  has to outlive the reader's open — and it has to have actually WRITTEN, since the PRAGMA
//  alone flips the header without materialising the files.

import BBPersistence
import Foundation
import GRDB

enum ChatFixtureCopy {

  /// A private copy of a fixture, converted to WAL, with a writable connection already open.
  ///
  /// - Returns: the path, and the writable connection. **Keep the connection for as long as
  ///   any reader is open** — releasing it lets SQLite remove `-wal` and `-shm`, after which a
  ///   read-only open of the same file fails.
  static func make(
    _ fixture: String = "chat-sonoma.db",
    testFile: StaticString = #filePath
  ) throws -> (path: String, writer: DatabaseQueue) {
    let source = URL(fileURLWithPath: "\(testFile)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/\(fixture)")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-chat-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)

    let writer = try DatabaseQueue(path: path.path)
    try writer.writeWithoutTransaction { db in
      _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
    }
    // A real write, to materialise `-wal` and `-shm`. A no-op UPDATE is enough and changes
    // nothing a test can observe.
    try writer.write { db in
      try db.execute(sql: "UPDATE message SET ROWID = ROWID WHERE 0")
    }
    return (path.path, writer)
  }

  /// Removes a copy and its WAL sidecars.
  ///
  /// The sidecars matter: leaving `-wal` and `-shm` behind in the temporary directory is how a
  /// suite that creates one database per test slowly fills it.
  static func remove(_ path: String) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }
}

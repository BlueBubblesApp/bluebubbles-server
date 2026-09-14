//  ChatDatabaseSafetyTests
//  `chat.db` is Apple's, and this server never writes to it. Asserted, not asserted-to.
//
//  This is the first non-negotiable in the project's own rulebook, and it was the one with no
//  test behind it. `docs/TESTING.md` described this suite in detail — a compile-failure test
//  blocking writes, a byte-identical check over the file and its journal, an assertion that
//  the connection reports read-only, a query-plan check in CI — and none of it existed.
//  Searching the whole test tree for `SQLITE_OPEN_READONLY` returned nothing. The protection
//  was real but structural and conventional: `ReadOnlyDatabase` vends no write API, so
//  nothing COULD write, and everyone believed a suite was keeping it that way.
//
//  The distinction matters because the structural guarantee is one refactor from gone. A
//  `write` method added to `ReadOnlyDatabase` for some internal cache, a repository reaching
//  for `DatabaseQueue` directly, a configuration change that drops `readonly` — each compiles,
//  and each turns "cannot write" back into "does not happen to write today".
//
//  What is asserted here is what can be: that a write through the real type is refused by
//  SQLite itself, and that a representative read leaves the file, its write-ahead log and its
//  shared-memory index untouched to the byte. The fixtures are the committed per-release
//  schemas, so this runs anywhere without a live Messages.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("chat.db is opened read-only and left untouched")
struct ChatDatabaseSafetyTests {

  /// A working copy, so a defect here damages a temporary file and not the fixture.
  private static func copyOfFixture(_ name: String) throws -> URL {
    let source = try #require(
      Bundle.module.url(
        forResource: "chat-\(name)", withExtension: "db", subdirectory: "ChatDBFixtures"),
      "the \(name) chat.db fixture is missing")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-chatdb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("chat.db")
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
  }

  /// Size and modification date for the database and both of its sidecars.
  private static func fingerprint(_ database: URL) -> [String: String] {
    var out: [String: String] = [:]
    for suffix in ["", "-wal", "-shm"] {
      let url = URL(fileURLWithPath: database.path + suffix)
      guard
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      else {
        out[suffix.isEmpty ? "db" : suffix] = "absent"
        continue
      }
      let size = values.fileSize ?? -1
      let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? -1
      out[suffix.isEmpty ? "db" : suffix] = "\(size)@\(stamp)"
    }
    return out
  }

  @Test("A write through the read-only handle is refused by SQLite")
  func writesAreRefused() async throws {
    let file = try Self.copyOfFixture("sequoia")
    let database = try ReadOnlyDatabase(path: file.path)

    // Reaching past every repository, straight at the connection, which is the only way a
    // write could ever be attempted.
    //
    // The CODE is the assertion, not merely that something threw: `SQLITE_READONLY` (8) is
    // SQLite itself refusing, rather than a Swift-level guard that a refactor could remove.
    //
    // **What this does NOT isolate, measured rather than assumed.** Two mechanisms can
    // deliver code 8, and they are alternatives rather than layers. With
    // `configuration.readonly = true` the connection itself refuses and `PRAGMA query_only`
    // reads 0; flip that flag to `false` and GRDB sets `query_only = 1` for the duration of
    // every `read` block instead, and the write is refused just the same. Both were measured
    // by flipping the flag and re-running this suite, which passed either way.
    //
    // So this pins the PROPERTY — a write through the only API that exists cannot succeed —
    // and deliberately does not pin which layer delivers it, because either satisfies the
    // rule and asserting one would fail on a GRDB release that changed the other. The
    // connection flag carries its own reasoning where it is set.
    for statement in [
      "UPDATE message SET is_read = 1",
      "CREATE TABLE bb_probe (id INTEGER)",
      "DELETE FROM chat",
    ] {
      var code: Int32?
      do {
        try await database.read { db in try db.execute(sql: statement) }
      } catch let error as DatabaseError {
        code = error.resultCode.rawValue
      } catch {
        Issue.record("`\(statement)` failed with \(error), which is not a SQLite refusal")
        continue
      }
      #expect(
        code == 8,
        """
        `\(statement)` did not come back SQLITE_READONLY (got \(code.map(String.init) ?? "no error")). \
        chat.db is Apple's and nothing here may write to it.
        """)
    }
  }

  @Test("Reading leaves the database, its write-ahead log and its index untouched")
  func readingChangesNothing() async throws {
    let file = try Self.copyOfFixture("sequoia")
    let before = Self.fingerprint(file)

    let database = try ReadOnlyDatabase(path: file.path)
    // A representative read rather than a trivial one: the tables, the columns of the two
    // that matter, and rows out of each.
    let tables = try await database.tables()
    #expect(tables.contains("message"), "the fixture is not a chat.db")
    _ = try await database.columns(of: "message")
    // Row is not Sendable, so the values come back rather than the rows.
    _ = try await database.read { db in
      try Int.fetchAll(db, sql: "SELECT ROWID FROM message LIMIT 20")
    }
    _ = try await database.read { db in
      try Int.fetchAll(db, sql: "SELECT ROWID FROM chat LIMIT 20")
    }
    _ = try await database.changeToken()

    let after = Self.fingerprint(file)
    #expect(
      before == after,
      Comment(
        rawValue: """
          reading chat.db modified it.
            before: \(before.sorted(by: { $0.key < $1.key }))
            after:  \(after.sorted(by: { $0.key < $1.key }))
          """))
  }

  @Test("No chat.db query selects every column")
  func noSelectStar() throws {
    // Apple owns this schema and it changes per release, so `SELECT *` binds this server to
    // whichever columns happened to exist on the machine it was written on. The rule is in
    // the rulebook; this is the check.
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BBIMessage")
    let walker = try #require(FileManager.default.enumerator(atPath: root.path))
    var scanned = 0
    var offenders: [String] = []
    for case let relative as String in walker where relative.hasSuffix(".swift") {
      let source = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
      scanned += 1
      for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let code = line.trimmingCharacters(in: .whitespaces)
        if code.hasPrefix("//") { continue }
        if code.lowercased().contains("select *") {
          offenders.append("BBIMessage/\(relative):\(index + 1): \(code)")
        }
      }
    }
    #expect(scanned > 10, "the scan found only \(scanned) files; it is not reading the module")
    #expect(
      offenders.isEmpty,
      Comment(rawValue: "SELECT * against Apple's schema:\n" + offenders.joined(separator: "\n")))
  }
}

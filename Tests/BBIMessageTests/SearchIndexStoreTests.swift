//  SearchIndexStoreTests
//  The index file's lifecycle, and the three properties `docs/SEARCH.md` promises a user.
//
//  Two of those promises are the reason this feature is allowed to exist at all, so they are
//  asserted rather than described: turning it off leaves nothing on disk, and the file cannot
//  be read by anything that happens to be running as this user.
//
//  The third — that it cannot stop the server — is structural rather than testable here: the
//  store is not a `SchemaContributor`, so `AppDatabase.open` never touches it.
//  `SchemaContributionTests.freshDatabaseIsComplete` is where that stays true, because a
//  `message_search` table appearing in `app.db` would show up there.

import BBCore
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Search index store")
struct SearchIndexStoreTests {

  /// A store in a directory of its own, removed with the test.
  private func temporaryStore() -> (SearchIndexStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-search-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("search-index.db")
    return (SearchIndexStore(url: url), root)
  }

  // MARK: Creating

  @Test("Opening creates the index, and opening again reuses it")
  func opensAndCreates() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try await store.open()
    #expect(first == .available)
    #expect(await store.exists)

    // Idempotent: a second open must not rebuild, which would throw away a backfill.
    try await store.setBackfillCursor(4182)
    #expect(try await store.open() == .available)
    #expect(try await store.backfillCursor() == 4182)
  }

  @Test("The table is contentless, and deletes work without the original text")
  func tableIsContentlessAndDeletable() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()

    let queue = try await store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [1, "dinner at eight"])
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [2, "breakfast tomorrow"])
    }

    let found = try await queue.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
        arguments: ["dinner"])
    }
    #expect(found == [1])

    // The whole reason `contentless_delete=1` is on: an edited message has to lose its old
    // tokens, and a plain contentless table refuses `DELETE` outright.
    try await queue.write { db in
      try db.execute(sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [1])
    }
    let afterDelete = try await queue.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
        arguments: ["dinner"])
    }
    #expect(afterDelete.isEmpty)
  }

  @Test("The tokenizer folds accents, so `cafe` finds `café`")
  func tokenizerFoldsDiacritics() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()

    let queue = try await store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [7, "meet at the café"])
    }
    let hits = try await queue.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
        arguments: ["cafe"])
    }
    #expect(hits == [7])
  }

  @Test("`detail=none` is in force: the index cannot answer a phrase query")
  func phraseQueriesAreUnsupported() async throws {
    // Not a limitation being worked around — it is the POINT. Token positions are what make
    // an index reconstructable back into sentences, and their absence is what lets the
    // onboarding copy say "a word list, not your conversations". If this test ever starts
    // passing a phrase query, the privacy claim in `docs/SEARCH.md` has quietly stopped
    // being true.
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()

    let queue = try await store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [1, "see you tomorrow"])
    }

    await #expect(throws: (any Error).self) {
      try await queue.read { db in
        try Int64.fetchAll(
          db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
          arguments: ["\"see you\""])
      }
    }
  }

  // MARK: The promises

  @Test("Turning it off leaves nothing on disk")
  func destroyRemovesEverything() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()

    let queue = try await store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [1, "something private"])
    }

    try await store.destroy()
    #expect(!(await store.exists))
    // The sidecars too: a `-wal` left behind holds the tokens of whatever was written last,
    // which is exactly the residue `destroy` exists to remove.
    for suffix in ["-wal", "-shm"] {
      #expect(!FileManager.default.fileExists(atPath: store.fileURL.path + suffix))
    }
  }

  @Test("The index file is not readable by anything else running as this user")
  func fileIsNotWorldReadable() async throws {
    // `app.db` sits at 0644 in a 0755 directory, and the source this is derived from —
    // `chat.db` — is behind TCC. The file mode is the only thing standing between this
    // index and any process running as this user, so it is asserted.
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()

    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(mode & 0o077 == 0, "index mode is \(String(mode, radix: 8)), expected 0600")

    let directory = try FileManager.default.attributesOfItem(atPath: root.path)
    let directoryMode = (directory[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(
      directoryMode & 0o077 == 0,
      "directory mode is \(String(directoryMode, radix: 8)), expected 0700")
  }

  // MARK: Rebuilding

  @Test("An index built by a different schema version is rebuilt, not read")
  func schemaVersionMismatchRebuilds() async throws {
    // A tokenizer change makes an existing index disagree with the queries run against it,
    // silently. Rebuilding costs seconds; reading it would cost correctness.
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()
    try await store.setBackfillCursor(9999)
    try await store.setBackfillComplete(true)
    try await store.close()

    // Stand in for "built by a future version".
    let queue = try DatabaseQueue(path: store.fileURL.path)
    try await queue.write { db in
      try db.execute(sql: "UPDATE search_state SET schema_version = ?", arguments: [99])
    }
    try queue.close()

    #expect(try await store.open() == .available)
    #expect(try await store.backfillCursor() == 0, "a rebuild starts from nothing")
    #expect(try await store.isBackfillComplete() == false)
  }

  @Test("State survives a close and reopen")
  func stateIsDurable() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    try await store.open()
    try await store.setBackfillCursor(1234)
    try await store.setIndexedCount(56)
    try await store.setBackfillComplete(true)
    try await store.close()

    let reopened = SearchIndexStore(url: store.fileURL)
    try await reopened.open()
    #expect(try await reopened.backfillCursor() == 1234)
    #expect(try await reopened.indexedCount() == 56)
    #expect(try await reopened.isBackfillComplete())
  }

  @Test("Reading before opening refuses rather than opening implicitly")
  func readingBeforeOpenThrows() async throws {
    let (store, root) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SearchIndexError.notOpen) {
      _ = try await store.connection()
    }
    #expect(!(await store.exists), "a refused read must not have created a file")
  }
}

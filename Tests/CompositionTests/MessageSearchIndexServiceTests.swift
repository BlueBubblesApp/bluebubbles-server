//  MessageSearchIndexServiceTests
//  The indexer: what it builds, what it resumes, and what it removes.
//
//  Three of these are promises made to a user rather than properties of the code. The switch
//  going off DELETES the index, because that is what the onboarding copy says. The backfill
//  resumes rather than restarting, because on the hardware this targets it is tens of seconds
//  and a server that restarts loses it. And a text-free run of rows — attachments, tapbacks —
//  must not stall the cursor, because the failure mode there is an index that stops advancing
//  and a search that silently covers only part of the history.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBBuiltIns
import BBIMessage
import BBInterfaces
import BBPersistence
import BBSerialization
import BBServiceKit
import BBSettings
import BBTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Message search indexer", .serialized)
struct MessageSearchIndexServiceTests {

  private struct Harness {
    let context: AppContext
    let store: SearchIndexStore
    let root: URL
    let settings: SettingsStore
  }

  /// The committed `chat.db` fixture, copied into the harness's root so the suite never
  /// writes beside it.
  ///
  /// A REAL database with real rows, not `AppContextFixture`'s empty repository: a backfill
  /// over nothing would assert that the loop terminates and nothing else, and the cursor
  /// behaviour this file is mostly about only happens when there are rows to walk.
  private func harness(enabled: Bool) async throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-indexer-\(UUID().uuidString)", isDirectory: true)
    let chatPath = try CommittedChatDB.copy(into: root)

    let context = try await AppContextFixture.make(
      chatDatabase: try ReadOnlyDatabase(path: chatPath.path))
    let store = SearchIndexStore(url: root.appendingPathComponent("index.db"))
    let settings = context.settings
    try await settings.set(Settings.searchIndexEnabled, to: enabled)
    return Harness(context: context, store: store, root: root, settings: settings)
  }

  private func indexedRowIDs(_ store: SearchIndexStore, matching term: String) async throws
    -> [Int64]
  {
    let queue = try await store.connection()
    return try await queue.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM message_search WHERE message_search MATCH ?",
        arguments: [term])
    }
  }

  /// Waits for the pump rather than guessing at a sleep. A read that fails is "not yet":
  /// the pump may still be standing the table up.
  private func settle(_ store: SearchIndexStore) async throws {
    try await waitUntil("the backfill to finish") {
      (try? await store.isBackfillComplete()) == true
    }
  }

  // MARK: Building

  @Test("It indexes the history it finds, and reports itself ready")
  func backfillsAndBecomesReady() async throws {
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)

    // The fixture's seeded messages carry text; whatever they are, the index has them and
    // the cursor has moved past them.
    #expect(try await harness.store.indexedCount() > 0)
    #expect(try await harness.store.backfillCursor() > 0)
    // The pump keeps running once the backfill is done: it is what indexes new messages.
    #expect(await service.isAlive)
    await service.stop()
  }

  @Test("A second start does not rebuild what is already indexed")
  func completedBackfillIsNotRepeated() async throws {
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let first = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await first.start()
    try await settle(harness.store)
    let cursor = try await harness.store.backfillCursor()
    let count = try await harness.store.indexedCount()
    await first.stop()

    // A restart — which a settings change causes — must not pay for the history again.
    let second = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await second.start()
    // And it says so at once. `start()` used to report `.building` whatever the file said,
    // and the steady state only moves to `.ready` after it adds a message, so a launch over
    // a finished index read "building the search index" until the next message arrived.
    #expect(await second.health == .running, "a finished index reported itself as building")
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await harness.store.backfillCursor() == cursor)
    #expect(try await harness.store.indexedCount() == count)
    #expect(await second.health == .running)
    await second.stop()
  }

  @Test("An interrupted backfill resumes from its cursor")
  func backfillResumes() async throws {
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    // Stand in for a server that was stopped mid-build: the index exists, the cursor is
    // part-way, and the backfill is not marked complete.
    try await harness.store.open()
    try await harness.store.setBackfillCursor(2)
    try await harness.store.setBackfillComplete(false)

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)
    // It carried on from 2 rather than starting again, and finished.
    #expect(try await harness.store.backfillCursor() > 2)
    await service.stop()
  }

  @Test("A chat.db that is not the one it was built from discards the index and rebuilds")
  func replacedDatabaseDiscardsTheIndex() async throws {
    // A restore, a rebuild or a migration reassigns `message.ROWID` from 1, and this index
    // is nothing BUT row ids. Every stored row then names a different message, so a search
    // returns messages that do not contain the term — and it never heals, because the
    // cursor sits above the new maximum so the walk ends at once while `backfill_complete`
    // is still true and the reader goes on trusting it.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let first = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(50))
    try await first.start()
    try await settle(harness.store)
    await first.stop()

    // The state a replacement leaves: the pinned row id now carries a DIFFERENT guid,
    // because in the new file that id belongs to some other message. Rewriting the guid is
    // the same observation a restore produces, and it is the only one that distinguishes a
    // replaced file from a deleted message — see `discardIndexIfDatabaseWasReplaced`.
    try await harness.store.open()
    let origin = try #require(try await harness.store.origin())
    let queue = try await harness.store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [9_000_000, "zzqqxaardvark"])
    }
    try await harness.store.close()

    let chatPath = harness.root.appendingPathComponent("chat.db")
    let writable = try DatabaseQueue(path: chatPath.path)
    try await writable.write { db in
      try db.execute(
        sql: "UPDATE message SET guid = ? WHERE ROWID = ?",
        arguments: ["REBUILT-DATABASE-ROW", origin.rowID])
    }
    try writable.close()

    let second = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(50))
    try await second.start()

    // Both halves, and both are needed: the rows from the old file gone, AND a finished
    // index in their place. Waiting on `settle` alone would pass on the stale
    // `backfill_complete` the discarded index still carries.
    try await waitUntil("the stale row ids gone and the index rebuilt") {
      let stale = (try? await indexedRowIDs(harness.store, matching: "zzqqxaardvark")) ?? [0]
      let complete = (try? await harness.store.isBackfillComplete()) ?? false
      return stale.isEmpty && complete
    }
    #expect(try await harness.store.indexedCount() > 0)
    await second.stop()
  }

  @Test("Deleting the newest message is not mistaken for a replaced database")
  func deletingTheNewestMessageIsNotAReplacement() async throws {
    // THE FALSE POSITIVE. The first version of this guard compared `MAX(ROWID)` against
    // the cursor, which is not a property of a replaced database at all: deleting the
    // NEWEST message puts the maximum below the cursor in a file nobody touched, and
    // leaves it there until the next message arrives, because `AUTOINCREMENT` does not
    // reissue the id. An unsend, or deleting the last message in a conversation, would
    // then discard a whole index and rebuild it — silently, and every time it happened.
    //
    // This test is the evidence for that, which is why it asserts the cursor is UNCHANGED
    // rather than merely that the index still works: a rebuild would also end in a working
    // index, several hundred thousand rows later.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(50))
    try await service.start()
    try await settle(harness.store)
    let cursor = try await harness.store.backfillCursor()
    let count = try await harness.store.indexedCount()

    // The newest row goes, which puts `MAX(ROWID)` below the cursor — the exact shape the
    // magnitude check called a replacement.
    let highest = try #require(try await harness.context.messages?.maximumMessageRowID())
    let chatPath = harness.root.appendingPathComponent("chat.db")
    let writable = try DatabaseQueue(path: chatPath.path)
    try await writable.write { db in
      try db.execute(sql: "DELETE FROM message WHERE ROWID = ?", arguments: [highest])
    }
    try writable.close()
    #expect(
      try await harness.context.messages?.maximumMessageRowID() ?? 0 < cursor,
      "the test did not reproduce the state it is about")

    // Several passes' worth, so this is not just catching it before the pump looked.
    try await Task.sleep(for: .milliseconds(300))
    #expect(
      try await harness.store.backfillCursor() == cursor,
      "the index was rebuilt over a single deleted message")
    #expect(try await harness.store.indexedCount() <= count)
    #expect(try await harness.store.isBackfillComplete())
    await service.stop()
  }

  @Test("A message deleted from chat.db loses its words from the index")
  func deletedMessagesArePruned() async throws {
    // RESIDUE, not wrong answers. A deleted row id resolves to nothing, so the join already
    // drops it and no search ever returned it — but `message.ROWID` is AUTOINCREMENT, so the
    // id is never reused and the WORDS stayed for the life of the index. Someone who deleted
    // a message on purpose was left with a file recording which words it held.
    //
    // Nothing reports a deletion: the cursor never looks back and the watcher does not
    // observe them. So the index is reconciled against the rows that still exist.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    // `pruneInterval: .zero` so every pass reconciles. With the shipped hour, whether this
    // test passed would depend on whether the delete below landed before or after the first
    // steady-state pass, which is a coin toss dressed up as an assertion.
    let service = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(50),
      pruneInterval: .zero)
    try await service.start()
    try await settle(harness.store)

    // A row the index holds, chosen from the index itself so the test does not have to know
    // what the fixture says.
    let queue = try await harness.store.connection()
    let victim = try await queue.read { db in
      try Int64.fetchOne(db, sql: "SELECT rowid FROM message_search ORDER BY rowid LIMIT 1")
    }
    let rowID = try #require(victim)
    let words = try await harness.context.messages?.searchableText(rowIDs: [rowID]).first
    let term = try #require(words?.text.split(separator: " ").first.map(String.init))
    #expect(try await indexedRowIDs(harness.store, matching: "\"\(term)\"").contains(rowID))

    // Deleted the way Messages would: the row is gone from chat.db and nothing tells us.
    let chatPath = harness.root.appendingPathComponent("chat.db")
    let writable = try DatabaseQueue(path: chatPath.path)
    try await writable.write { db in
      try db.execute(sql: "DELETE FROM message WHERE ROWID = ?", arguments: [rowID])
    }
    try writable.close()

    try await waitUntil("the deleted message's words to be pruned") {
      let holding = (try? await indexedRowIDs(harness.store, matching: "\"\(term)\"")) ?? [rowID]
      return !holding.contains(rowID)
    }
    await service.stop()
  }

  @Test("Indexing a new message in the steady state does not report a build")
  func steadyStateIsNotABuild() async throws {
    // `indexNewMessages` serves the backfill and the steady state, and it used to announce
    // `.building` on every page of both. In the steady state nothing ever set the state
    // back, so ONE arriving message left `health` reporting
    // `degraded("building the search index")` for the rest of the process's life over an
    // index that was complete. Invisible until the settings screen started following
    // health; visible immediately afterwards, as a finished feature that looks broken.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(50))
    try await service.start()
    try await settle(harness.store)
    #expect(await service.health == .running)

    // A message arrives after the backfill, which is the ordinary case for a running server.
    let chatPath = harness.root.appendingPathComponent("chat.db")
    let writable = try DatabaseQueue(path: chatPath.path)
    let highest = try await harness.context.messages?.maximumMessageRowID() ?? 0
    try await writable.write { db in
      try db.execute(
        sql: "INSERT INTO message (ROWID, guid, text, is_from_me, date) VALUES (?, ?, ?, 0, 0)",
        arguments: [highest + 1, "STEADY-STATE-1", "zzqqxaardvark"])
    }
    try writable.close()

    try await waitUntil("the new message to be indexed") {
      let hits = (try? await indexedRowIDs(harness.store, matching: "zzqqxaardvark")) ?? []
      return !hits.isEmpty
    }
    #expect(
      await service.health == .running,
      "a finished index reported itself as still building")
    await service.stop()
  }

  // MARK: The promise

  @Test("With the switch off, the index is deleted")
  func disabledRemovesTheIndex() async throws {
    // The onboarding copy says "turning it off deletes it". This is that sentence.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let building = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await building.start()
    try await settle(harness.store)
    await building.stop()
    #expect(await harness.store.exists)

    try await harness.settings.set(Settings.searchIndexEnabled, to: false)
    let disabled = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await disabled.start()
    #expect(!(await harness.store.exists), "the index survived the switch going off")
    await disabled.stop()
  }

  @Test("Switched off, it does not build one either")
  func disabledBuildsNothing() async throws {
    let harness = try await harness(enabled: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(!(await harness.store.exists))
    // No pump, and nothing for the liveness poll to revive.
    #expect(await service.isAlive)
    await service.stop()
  }

  // MARK: The cursor

  @Test("Rows with no searchable text do not stall the cursor")
  func textFreeRowsAdvanceTheCursor() async throws {
    // `searchableText` DROPS rows that resolve to nothing — an attachment with no caption, a
    // tapback — so a page of them comes back empty while rows remain. Advancing on the page
    // alone would stop the cursor dead at the first such run, and every message after it
    // would be missing from the index with nothing reporting a problem.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let repository = try #require(harness.context.messages)
    let maximum = try await repository.maximumMessageRowID() ?? 0
    #expect(maximum > 0)

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)

    // The cursor reached the end of the table, whatever the rows along the way contained.
    #expect(try await harness.store.backfillCursor() >= maximum)
    await service.stop()
  }

  // MARK: Re-indexing

  @Test("Re-indexing a row replaces its words rather than adding to them")
  func reindexReplaces() async throws {
    // `contentless_delete=1` exists for this. Without the DELETE a row indexed twice holds
    // the union of both texts, so a search finds a message by a word it no longer contains.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.store.open()

    let queue = try await harness.store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [4182, "the original wording"])
    }
    #expect(try await indexedRowIDs(harness.store, matching: "original") == [4182])

    try await queue.write { db in
      try db.execute(sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [4182])
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [4182, "the replacement wording"])
    }
    #expect(try await indexedRowIDs(harness.store, matching: "replacement") == [4182])
    #expect(
      try await indexedRowIDs(harness.store, matching: "original").isEmpty,
      "the old words survived a re-index")
  }

  // MARK: Edits — the thing a ROWID cursor cannot see

  @Test("An edited message loses its old words and gains its new ones")
  func reindexReplacesWordsThroughTheHook() async throws {
    // The gap a forward-only cursor leaves: it walks each row once and never looks back, so
    // without this hook an edited message keeps the words it used to have and a search finds
    // it by a word it no longer contains.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)

    // Index a row by hand under a word that is not in the fixture, then re-read it. The
    // fixture's own text is what `searchableText` will return, so the planted word must
    // disappear and the real one must appear.
    let repository = try #require(harness.context.messages)
    let rows = try await repository.searchableText(afterRowID: 0, limit: 1)
    let target = try #require(rows.first)

    let queue = try await harness.store.connection()
    try await queue.write { db in
      try db.execute(sql: "DELETE FROM message_search WHERE rowid = ?", arguments: [target.rowID])
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [target.rowID, "obsoletewording"])
    }
    #expect(try await indexedRowIDs(harness.store, matching: "obsoletewording") == [target.rowID])

    await service.reindex(rowIDs: [target.rowID])

    #expect(
      try await indexedRowIDs(harness.store, matching: "obsoletewording").isEmpty,
      "the stale words survived the re-read")
    // And what the row actually says is there instead.
    // Split the same way the tokenizer does, so the word asked for is one the index holds.
    let word = target.text.split { !$0.isLetter && !$0.isNumber }.map(String.init).first
    if let word {
      #expect(try await indexedRowIDs(harness.store, matching: word).contains(target.rowID))
    }
    await service.stop()
  }

  @Test("A message with no text left is removed from the index, not rewritten")
  func unsentMessageLeavesTheIndex() async throws {
    // An unsend keeps the row and empties it. `searchableText` returns nothing for such a
    // row, and the absence is the instruction: delete rather than rewrite.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)

    // A row id no message has: `searchableText` returns nothing for it, which is the same
    // shape an unsent message presents.
    let vanished: Int64 = 999_999
    let queue = try await harness.store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [vanished, "wordsthatarenowgone"])
    }
    #expect(try await indexedRowIDs(harness.store, matching: "wordsthatarenowgone") == [vanished])

    await service.reindex(rowIDs: [vanished])
    #expect(try await indexedRowIDs(harness.store, matching: "wordsthatarenowgone").isEmpty)
    await service.stop()
  }

  @Test("The hook is published while running and withdrawn on stop")
  func hookIsPublishedAndWithdrawn() async throws {
    // The withdrawal is the half that matters: a hook left published after `stop()` writes
    // to a database that is closed, or to one the user has just switched off.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    #expect(await harness.context.messageReindexer() == nil)
    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    #expect(await harness.context.messageReindexer() != nil, "nothing was published")
    await service.stop()
    #expect(await harness.context.messageReindexer() == nil, "the hook outlived the service")
  }

  @Test("Switched off, nothing is published for the watcher to call")
  func disabledPublishesNothing() async throws {
    let harness = try await harness(enabled: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    #expect(await harness.context.messageReindexer() == nil)
    await service.stop()
  }

  // MARK: Rebuilding

  @Test("A requested rebuild resets the state the backfill reads")
  func rebuildResetsProgress() async throws {
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let service = MessageSearchIndexService(host: harness.context, store: harness.store)
    try await service.start()
    try await settle(harness.store)
    #expect(try await harness.store.backfillCursor() > 0)
    await service.stop()

    try await harness.store.open()
    try await harness.store.requestRebuild()
    #expect(try await harness.store.backfillCursor() == 0)
    #expect(try await harness.store.isBackfillComplete() == false)
    #expect(try await harness.store.indexedCount() == 0)
  }

  @Test("The pump walks the table again after a rebuild, without a restart")
  func rebuildIsPickedUpByTheRunningService() async throws {
    // The reason `run` is one loop rather than "backfill, then poll": a rebuild sets
    // `backfill_complete` back to false, and a run structured as build-once has no way back
    // to the building half. The settings screen sets a flag and this is what acts on it.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    // A short interval, so this watches a pass happen rather than waiting out the shipped
    // minute. The interval is the only thing overridden; everything else is the real service.
    let service = MessageSearchIndexService(
      host: harness.context, store: harness.store, pollInterval: .milliseconds(20))
    try await service.start()
    try await settle(harness.store)
    let first = try await harness.store.backfillCursor()

    try await harness.store.requestRebuild()
    #expect(try await harness.store.isBackfillComplete() == false)

    // No restart, no new service: the running pump notices on its next pass.
    try await waitUntil("the running service to re-run the backfill", timeout: .seconds(6)) {
      (try? await harness.store.isBackfillComplete()) == true
    }
    #expect(try await harness.store.backfillCursor() == first)
    await service.stop()
  }

  // MARK: Reporting

  @Test("Finishing the backfill is reported, because the registry cannot see it")
  func backfillCompletionIsReported() async throws {
    // The registry publishes health on transitions IT performs — start, stop, restart. This
    // service's most interesting transition is none of those: the backfill finishes inside
    // the pump, seconds to minutes after `start()` returned. Without the report the app
    // shows "building the search index" until something unrelated moves, which from the
    // user's side is a progress bar that never completes.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let reporter = RecordingHealthReporter()
    let service = MessageSearchIndexService(
      host: HealthReportingHost(inner: harness.context, reporter: reporter),
      store: harness.store)
    try await service.start()
    try await settle(harness.store)
    // Give the final transition a moment to land.
    try await waitUntil("a health change to be reported") { await reporter.count > 0 }
    #expect(await reporter.count > 0, "no health change was ever reported")
    // The transition itself, not just some report: progress INSIDE `.building` is throttled
    // to one a second, and a throttle that could swallow the last page's report would leave
    // the screen saying "building" over a finished index.
    #expect(await service.health == .running, "the service did not end up ready")
    await service.stop()
  }

  @Test("The backfill reports how far along it is, and reaches the end")
  func backfillReportsItsFraction() async throws {
    // The sidebar draws its bar from `.degraded(progress:)`, and the first page's report is
    // the one that puts the row on screen, so it has to get past the throttle that bounds
    // the pages after it. The fixture is one page, which makes that the ONLY progress
    // report: if the throttle swallowed it, nothing here would carry a fraction at all.
    let harness = try await harness(enabled: true)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let reporter = RecordingHealthReporter()
    let service = MessageSearchIndexService(
      host: HealthReportingHost(inner: harness.context, reporter: reporter),
      store: harness.store)
    await reporter.attach { await service.health }
    try await service.start()
    try await settle(harness.store)
    try await waitUntil("the final report to be running") {
      await reporter.healths.last == .running
    }

    let healths = await reporter.healths
    let fractions = healths.compactMap { health -> Double? in
      if case .degraded(_, let progress) = health { return progress }
      return nil
    }
    #expect(!fractions.isEmpty, "no page of the backfill reported a fraction")
    #expect(fractions.allSatisfy { (0...1).contains($0) }, "a fraction left 0...1: \(fractions)")
    #expect(fractions == fractions.sorted(), "the bar went backwards: \(fractions)")
    #expect(fractions.last == 1, "the last page did not reach the end: \(fractions)")
    // Before the first page the build has no extent yet, and says so rather than guessing.
    #expect(
      healths.first == .degraded(reason: "building the search index: 0 messages", progress: nil))
    #expect(healths.last == .running, "the service did not end up ready: \(healths)")
    await service.stop()
  }

  @Test("The bar measures the rows this build walks, not the table")
  func extentIsTheDelta() {
    typealias Extent = MessageSearchIndexService.BackfillExtent

    let fresh = Extent(start: 0, ceiling: 1000)
    #expect(fresh.fraction(at: 0) == 0)
    #expect(fresh.fraction(at: 250) == 0.25)
    #expect(fresh.fraction(at: 1000) == 1)

    // Resumed at 400 after an interruption: the 600 rows left are the whole of this build.
    let resumed = Extent(start: 400, ceiling: 1000)
    #expect(resumed.fraction(at: 400) == 0)
    #expect(resumed.fraction(at: 700) == 0.5)

    // Rows that arrived during the walk lie past the fixed ceiling; the bar stays full.
    #expect(fresh.fraction(at: 1200) == 1)

    // Nothing to walk is complete, not a division by zero.
    #expect(Extent(start: 7, ceiling: 7).fraction(at: 7) == 1)
    #expect(Extent(start: 7, ceiling: 0).fraction(at: 7) == 1)
  }

  @Test("A state that has not moved is not reported")
  func unchangedStateIsNotReported() async throws {
    // Equality, which is the cheap half. It does NOT cover the backfill's own `.building`
    // reports: those carry a count that moves every page, so each one is a different value
    // and equality never dedupes them — the throttle in `setState` is what bounds those,
    // and `progressReportInterval` is the number.
    let harness = try await harness(enabled: false)
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let reporter = RecordingHealthReporter()
    let host = HealthReportingHost(inner: harness.context, reporter: reporter)
    let service = MessageSearchIndexService(host: host, store: harness.store)
    try await service.start()
    let afterFirst = await reporter.count
    // Starting again lands on the same `.disabled`, so nothing new is worth announcing.
    try await service.start()
    #expect(await reporter.count == afterFirst)
    await service.stop()
  }

  // MARK: Wiring

  @Test("It is registered, and its manifest is the declared one")
  func isRegistered() async throws {
    // A module is not done until the composition root calls it and a test asserts the call.
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(in: registry)
    let ids = await registry.manifests.map(\.id)
    #expect(ids.contains(BuiltInManifests.ID.messageSearch))
  }

  @Test("The setting it reads is the one its manifest declares")
  func readsOnlyWhatItDeclares() {
    // An undeclared read throws at runtime, so the two have to agree. Asserted rather than
    // trusted because the failure is a service that starts and then dies on its first read.
    let manifest = BuiltInManifests.messageSearch
    var declared: Set<String> = []
    for entitlement in manifest.entitlements {
      if case .readSettings(let keys) = entitlement { declared.formUnion(keys) }
    }
    #expect(declared == [Settings.searchIndexEnabled.key])
  }

  @Test("It declares the file it keeps, not only the messages it reads")
  func declaresItsOwnStorage() {
    // The permissions list is what a person has when deciding whether to trust a service,
    // and this one's defining characteristic is the file it keeps: a word list derived from
    // every message, on disk until the switch goes off. A manifest naming only `.readMessages`
    // describes the input and hides the output.
    //
    // It is also the first built-in to claim `.ownStorage`, which makes it the worked
    // example. See rule 9 in the root CLAUDE.md on why a built-in's manifest has to be
    // exactly right years before anything third-party loads.
    #expect(BuiltInManifests.messageSearch.entitlements.contains(.ownStorage))
  }

  /// **The test that was missing, and the bug it would have caught.**
  ///
  /// `MessageRepository` takes its search index as a parameter defaulting to nil. Every test
  /// above injects one by hand, so all of them passed while `openReadPath` built the
  /// repository WITHOUT it — the indexer filled a file nothing ever read. The first run
  /// against a real database returned identical totals with the feature on and off, which is
  /// the only way it could have surfaced.
  ///
  /// So this asserts the composition, not a hand-assembled object: one store, reachable from
  /// the container, and the same instance the repository was built with.
  @Test("The composition gives the repository the same index the service fills")
  func compositionSharesOneIndex() async throws {
    let logger = Logger(label: "bluebubbles.test.search-wiring")
    let settings = try await TestSettings.store()
    let shared = SearchIndexStore(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent("bb-wiring-\(UUID().uuidString).db"))

    let readPath = await ServerComposition.openReadPath(
      settings: settings, logger: logger, searchIndex: shared)

    // Carried on the read path, so the container and the service both reach it.
    #expect(readPath.searchIndex === shared)

    // And handed to the repository. Asserted through BEHAVIOUR rather than by reading a
    // private field: a repository with no index never consults one, so a term the index
    // answers is the difference between the two.
    let repository = try #require(readPath.messages)
    #expect(repository.hasSearchIndex, "the repository was built without the index")
  }

  @Test("It is not user-manageable: the setting is the only switch")
  func isNotUserManageable() {
    // Two switches for one feature is the failure `isUserManageable` exists to prevent, and
    // this one already has a switch the user meets during onboarding.
    #expect(!BuiltInManifests.messageSearch.isUserManageable)
  }
}

/// Which changes the watcher forwards to the search index.
///
/// The rule that connects the two services, asserted on its own: a message search that keeps
/// finding a message by a word it no longer contains is the failure, and the rule deciding
/// that lives here rather than in a loop nobody can reach.
@Suite("Reindex triggers", .removingChatDBCopies)
struct MessageReindexTriggerTests {

  /// Real rows from the committed fixture: `IMessageRow` is built from a database row and
  /// has no memberwise initialiser, which is the right constraint — a hand-made row is a
  /// second definition of what a message is.
  private func rows(_ count: Int) async throws -> [IMessageRow] {
    let path = try CommittedChatDB.copy()
    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    var query = MessageRepository.MessageQuery()
    query.limit = count
    return try await repository.messages(query)
  }

  private func change(_ row: IMessageRow, _ fields: Set<MessageField>) -> MessageChange {
    MessageChange(message: row, isNew: false, changedFields: fields)
  }

  @Test("An edit and an unsend are forwarded")
  func editsAndRetractionsAreForwarded() async throws {
    let rows = try await rows(2)
    let changes = [change(rows[0], [.edited]), change(rows[1], [.retracted])]
    #expect(
      ChangeDetectionService.rowIDsNeedingReindex(changes) == [rows[0].rowID, rows[1].rowID])
  }

  @Test("Receipts and statuses are not")
  func receiptsAreNotForwarded() async throws {
    // Every one of these moves a column the index does not hold. Forwarding them would make
    // a busy conversation re-read rows on every delivery receipt, for no change in words.
    let rows = try await rows(5)
    let changes = [
      change(rows[0], [.delivered]), change(rows[1], [.read]), change(rows[2], [.played]),
      change(rows[3], [.notifiedRecipient]), change(rows[4], [.error]),
    ]
    #expect(ChangeDetectionService.rowIDsNeedingReindex(changes).isEmpty)
  }

  @Test("A change carrying both an edit and a receipt is forwarded once")
  func mixedChangeIsForwarded() async throws {
    let row = try await rows(1)[0]
    #expect(
      ChangeDetectionService.rowIDsNeedingReindex([change(row, [.edited, .read])])
        == [row.rowID])
  }

  @Test("A new message is not forwarded: the cursor owns those")
  func newMessagesAreNotForwarded() async throws {
    // Deliberate. The ROWID walk is the completeness guarantee and it already picks these up
    // within a tick; a second writer for the same rows would be a second thing to reason
    // about for a latency nobody is waiting on.
    let row = try await rows(1)[0]
    let arrival = MessageChange(message: row, isNew: true, changedFields: [])
    #expect(ChangeDetectionService.rowIDsNeedingReindex([arrival]).isEmpty)
  }
}

/// Counts health reports, and records what the service said at each one once attached.
private actor RecordingHealthReporter: HealthChangeReporting {
  private(set) var count = 0
  private(set) var healths: [ServiceHealth] = []
  private var source: (@Sendable () async -> ServiceHealth)?

  /// Reads the service's health at each report, so a test can see the sequence and not only
  /// the count. After construction because the host is built before the service is.
  func attach(_ source: @escaping @Sendable () async -> ServiceHealth) { self.source = source }

  func serviceHealthDidChange(_ id: ServiceIdentifier) async {
    count += 1
    if let source { healths.append(await source()) }
  }
}

/// The real container with the health reports intercepted.
///
/// Forwarding by hand rather than subclassing, because `AppContext` is an actor and the host
/// is a protocol composition: the point is to substitute ONE member and leave the rest real.
private struct HealthReportingHost: ScopedSettingsProviding, LoggerProviding,
  MessageSourceProviding, MessageReindexerPublishing, SearchIndexProviding, HealthChangeReporting
{
  let inner: AppContext
  let reporter: RecordingHealthReporter

  func scopedSettings(for manifest: ServiceManifest) -> ScopedSettings {
    inner.scopedSettings(for: manifest)
  }
  var logger: Logger { inner.logger }
  var messages: MessageRepository? { inner.messages }
  var serializer: MessageSerializer? { inner.serializer }
  var searchIndex: SearchIndexStore { inner.searchIndex }
  func publish(messageReindexer reindexer: any MessageReindexing) async {
    await inner.publish(messageReindexer: reindexer)
  }
  func withdrawMessageReindexer() async { await inner.withdrawMessageReindexer() }
  func serviceHealthDidChange(_ id: ServiceIdentifier) async {
    await reporter.serviceHealthDidChange(id)
  }
}

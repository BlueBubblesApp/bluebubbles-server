//  ChatDatabaseFixtureTests
//  The fixture has to be in the journal mode a real chat.db is in.
//
//  Messages commits while this server reads, and in WAL neither waits for the other. In SQLite's
//  default rollback-journal mode a read in progress refuses a commit outright, so an overlap
//  between a detector's tick and a fixture write fails the write with "database is locked".
//  Whether the two overlap is down to scheduling, so in a stream test that shows only under load.
//  Here the overlap is held open, so a fixture in that mode fails on every run.

import BBCore
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("The chat.db fixture")
struct ChatDatabaseFixtureTests {

  @Test("It is in WAL, as a real chat.db is")
  func journalMode() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let mode = try await fixture.database.read { db in
      try String.fetchOne(db, sql: "PRAGMA journal_mode")
    }
    #expect(mode == "wal")
  }

  @Test("A commit lands while a read is in progress, and the read keeps its snapshot")
  func commitDuringARead() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }

    let reading = Locked(false)
    let finishRead = DispatchSemaphore(value: 0)
    // Released on the way out too, or a failed write would leave the read holding its queue.
    defer { finishRead.signal() }
    let database = fixture.database
    let read = Task {
      try await database.read { db -> Int in
        let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        reading.withLock { $0 = true }
        finishRead.wait()
        return before + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0)
      }
    }
    try await waitUntil("the read to start") { reading.value }

    try await fixture.insertMessage(guid: "DURING-A-READ", at: Date())
    finishRead.signal()

    // The six seeded rows, counted twice: a read started before the commit never sees it.
    #expect(try await read.value == 12)
    let after = try await fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message")
    }
    #expect(after == 7)
  }
}

//  MistypedCellTests
//  A chat.db cell that does not hold its column's type is contained, not fatal.
//
//  SQLite does not enforce column types, and GRDB's typed row subscript decodes with `try!`,
//  so a BLOB that is not UTF-8 in a text column, or text in an integer column, terminated the
//  server the first time any request read the row. These put exactly such cells into a real
//  SQLite file and read them through the repository.
//
//  The cells are written through a second, writable connection, as Messages writes; the
//  repository's own connection stays read-only.

import BBCore
import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Mistyped chat.db cells")
struct MistypedCellTests {

  /// Rewrites cells of one seeded message, bypassing nothing but the column's declared type.
  private func corrupt(_ fixture: ChatDatabaseFixture, sql: String) async throws {
    let queue = try DatabaseQueue(path: fixture.path)
    defer { try? queue.close() }
    try await queue.write { db in try db.execute(sql: sql) }
  }

  @Test("A mistyped optional cell reads as NULL and the rest of the row survives")
  func optionalCellDegrades() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    // `text` holds a BLOB that is not UTF-8, which TEXT affinity keeps as a BLOB; `date_read`
    // holds text that is not a number, which INTEGER affinity keeps as text. Both trapped.
    try await corrupt(
      fixture,
      sql: """
        UPDATE message SET text = X'FFFE00', date_read = 'not a date' WHERE guid = 'MSG-0001'
        """)

    let rows = try await fixture.repository.messages(rowIDs: [1, 2])

    let damaged = try #require(rows.first { $0.guid == "MSG-0001" })
    #expect(damaged.text == nil)
    #expect(damaged.dateRead == nil)
    #expect(damaged.date != nil, "a readable cell beside the bad ones was lost")
    #expect(rows.contains { $0.guid == "MSG-0002" }, "the neighbouring row was lost")
  }

  @Test("A mistyped identity cell fails the read with a database error, naming no value")
  func requiredCellThrows() async throws {
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await corrupt(fixture, sql: "UPDATE message SET guid = X'FF' WHERE guid = 'MSG-0002'")

    let error = await #expect(throws: RowReadError.self) {
      try await fixture.repository.messages(rowIDs: [2])
    }
    #expect(
      error
        == .unreadableCell(column: "guid", expected: "String", found: "BLOB", in: .chatDatabase),
      "\(String(describing: error))")
    #expect(error?.title == "A row in the message database could not be read")
  }

  @Test("The change detector's fingerprints read past a mistyped timestamp")
  func fingerprintsDegrade() async throws {
    // The detector reads the same window every tick and a tick that throws is retried, so a
    // cell that threw here would stop every new message being announced, not just one.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    try await corrupt(
      fixture,
      sql: "UPDATE message SET date_delivered = 'never' WHERE guid = 'MSG-0003'")

    let fingerprints = try await fixture.repository.messageFingerprints(afterRowID: 0)
    #expect(fingerprints.count == 6, "a row was dropped: \(fingerprints.map(\.guid))")
    let damaged = try #require(fingerprints.first { $0.guid == "MSG-0003" })
    #expect(damaged.fingerprint.dateDelivered == nil)
    #expect(damaged.fingerprint.date != nil)
  }

  @Test("The search indexer reads past a text cell that is not UTF-8")
  func searchableTextDegrades() async throws {
    // The indexer walks every row in the background, so a trap here ended the server with no
    // request to blame, the first time the walk reached the row.
    let fixture = try await ChatDatabaseFixture()
    defer { fixture.tearDown() }
    let before = try await fixture.repository.searchableText(afterRowID: 0)
    try await corrupt(fixture, sql: "UPDATE message SET text = X'FFFE00' WHERE ROWID = 1")

    let after = try await fixture.repository.searchableText(afterRowID: 0)
    let byRow = try await fixture.repository.searchableText(rowIDs: [1, 2])
    #expect(
      after.filter { $0.rowID != 1 }.map(\.text) == before.filter { $0.rowID != 1 }.map(\.text))
    #expect(byRow.map(\.rowID) == before.filter { $0.rowID == 2 }.map(\.rowID))
  }
}

//  ReadConcurrencyBenchmark
//  What one SQLite connection actually costs under concurrent readers.
//
//  `ReadOnlyDatabase` opens chat.db as a single `DatabaseQueue` with `maximumReaderCount = 1`,
//  so EVERY read in the server — every `message.query` from every client, the change
//  detector's poll, and the SwiftUI app — serialises through one connection. The comment
//  justifying it argues lower memory on old hardware, and adds that "a reader needs no
//  concurrency against a database it never writes", which is the weaker half: concurrency
//  here is about how many readers can be in flight, not about writing.
//
//  Multi-client is a design requirement rather than an edge case, so the question is whether
//  that ceiling binds in practice. This measures it rather than assuming either way: the same
//  query, run at rising concurrency, against a database large enough for the query to cost
//  something.
//
//  Not a budget test. It asserts only that the measurement ran; the numbers are printed for a
//  human to read. Wall-clock thresholds on a shared CI machine are how a suite becomes flaky.

import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Read concurrency", .serialized)
struct ReadConcurrencyBenchmark {

  /// Big enough that a page query does real work, small enough to build in a few seconds.
  private static let messageCount = 40_000
  private static let pageSize = 100
  private static let queriesPerLevel = 200

  /// Disabled in the ordinary run, and deliberately kept rather than deleted.
  ///
  /// It takes about ninety seconds and asserts nothing — it exists to produce numbers a
  /// human reads when deciding whether to move `chat_db_readers`. Paying that on every
  /// `swift test` would buy no gate at all. Run it directly, in release, which is the only
  /// build whose absolute figures mean anything:
  ///
  ///     swift test -c release --filter ReadConcurrencyBenchmark/concurrencyProfile
  @Test(
    "A page query under rising concurrency",
    .disabled("~90s and asserts nothing; run it deliberately — see the note above"))
  func concurrencyProfile() async throws {
    let fixture = try await LargeChatFixture(messages: Self.messageCount)
    defer { fixture.tearDown() }

    print("")
    print("chat.db read concurrency — \(Self.messageCount) messages, page of \(Self.pageSize)")
    print(String(repeating: "-", count: 68))
    print("  readers   mode        total(ms)   per-query(ms)   queries/sec")

    for readers in [1, 2, 4, 8, 16] {
      let single = try await Self.measure(
        database: fixture.singleConnection, readers: readers, profile: fixture.profile)
      Self.report(readers: readers, mode: "queue(1)", elapsed: single)

      let pooled = try await Self.measure(
        database: fixture.pooled, readers: readers, profile: fixture.profile)
      Self.report(readers: readers, mode: "pool(4) ", elapsed: pooled)
    }
    print("")

    // The only assertion: it ran. See the file header.
    #expect(Self.messageCount > 0)
  }

  /// What a pool actually costs in memory, which is the reason the default is one.
  ///
  /// A pool holds one SQLite connection, with its own page cache, per reader. That was the
  /// stated justification for a single connection and it had never been measured against the
  /// throughput it buys.
  @Test("The memory a pool costs against the throughput it buys")
  func poolMemoryCost() async throws {
    let fixture = try await LargeChatFixture(messages: 20_000)
    defer { fixture.tearDown() }

    // Warmed: the first query through a fresh repository pays for GRDB's statement cache and
    // the schema probe, which are not the pool.
    _ = try await Self.measure(
      database: fixture.singleConnection, readers: 1, profile: fixture.profile)
    let baseline = MemoryFootprint.currentMegabytes() ?? 0

    _ = try await Self.measure(database: fixture.pooled, readers: 4, profile: fixture.profile)
    let pooled = MemoryFootprint.currentMegabytes() ?? 0

    print("")
    print(
      "  pool memory: baseline \(String(format: "%.1f", baseline)) MB "
        + "→ after 4 pooled readers \(String(format: "%.1f", pooled)) MB "
        + "(+\(String(format: "%.1f", pooled - baseline)) MB)")
    print("")

    #expect(pooled >= 0)
  }

  /// The default is unchanged: one connection, exactly as before this setting existed.
  @Test("The default is a single connection, and readerCount reports what opened")
  func defaultIsSingleConnection() async throws {
    let fixture = try await LargeChatFixture(messages: 10)
    defer { fixture.tearDown() }
    #expect(fixture.singleConnection.readerCount == 1)
    #expect(fixture.pooled.readerCount == 4)
  }

  private static func report(readers: Int, mode: String, elapsed: Duration) {
    let ms =
      Double(elapsed.components.attoseconds) / 1e15
      + Double(elapsed.components.seconds) * 1000
    let per = ms / Double(queriesPerLevel)
    let rate = Double(queriesPerLevel) / (ms / 1000)
    print(
      "  \(String(format: "%7d", readers))   \(mode)"
        + "    \(String(format: "%9.1f", ms))"
        + "       \(String(format: "%9.3f", per))"
        + "     \(String(format: "%9.0f", rate))")
  }

  /// Runs `queriesPerLevel` page queries spread across `readers` concurrent tasks.
  private static func measure(
    database: ReadOnlyDatabase, readers: Int, profile: SchemaProfile
  ) async throws -> Duration {
    let repository = MessageRepository(database: database, profile: profile)
    let each = queriesPerLevel / readers

    let clock = ContinuousClock()
    return try await clock.measure {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for reader in 0..<readers {
          group.addTask {
            for index in 0..<each {
              var query = MessageRepository.MessageQuery()
              query.limit = pageSize
              // Different offsets per reader, so the page cache does not turn this into
              // one query measured N times.
              query.offset = ((reader * each) + index) * pageSize % 20_000
              _ = try await repository.messages(query)
            }
          }
        }
        try await group.waitForAll()
      }
    }
  }
}

/// A chat.db with enough messages that a page query costs something.
///
/// Separate from `ChatDatabaseFixture`, which seeds a handful of rows through one insert per
/// call — 40,000 of those would dominate the run. This bulk-inserts in a single transaction
/// and then opens the same file twice: once the way the server does, once through a pool.
struct LargeChatFixture {

  let path: String
  /// Held open — see the note in `init`.
  private let writer: DatabaseQueue
  let singleConnection: ReadOnlyDatabase
  let pooled: ReadOnlyDatabase
  let profile: SchemaProfile

  init(messages count: Int) async throws {
    path =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-bench-\(UUID().uuidString).db").path

    let queue = try DatabaseQueue(path: path)

    // WAL, because that is the mode chat.db is actually in — Messages.app runs in WAL, and
    // measuring against a rollback-journal file would be measuring a database this server
    // never sees.
    //
    // Set BEFORE the bulk insert, not after, and that ordering is load-bearing: the `-shm`
    // file is created by a WRITE in WAL mode, not by the pragma. Switching modes after the
    // last write leaves a WAL database with no `-shm`, and a read-only connection cannot
    // create one — BOTH opens below then fail with "unable to open database file", pool and
    // single connection alike. It is also why production works only while Messages.app is
    // holding the WAL open.
    try await queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
    }

    try await queue.write { db in
      try ChatDatabaseFixture.createSchema(db)
      try db.execute(sql: "INSERT INTO handle (id, service) VALUES ('+15550101234', 'iMessage')")
      try db.execute(
        sql: "INSERT INTO chat (guid, style, state, chat_identifier, service_name) "
          + "VALUES ('iMessage;-;+15550101234', 45, 3, '+15550101234', 'iMessage')")

      let epoch = ChatDatabaseFixture.appleEpoch
      for index in 0..<count {
        let stamp = Int64(
          Date(timeIntervalSince1970: epoch.timeIntervalSince1970 + Double(index))
            .timeIntervalSince(epoch) * 1_000_000_000)
        try db.execute(
          sql: ChatDatabaseFixture.MessageInsert.sql,
          arguments: [
            "bench-\(index)", "message body number \(index)", 1, index % 2, stamp, 1,
          ])
        try db.execute(
          sql: "INSERT INTO chat_message_join VALUES (?, ?, ?)",
          arguments: [1, db.lastInsertedRowID, stamp])
      }
    }
    // The writer stays OPEN for the life of the fixture, and that is not laziness. A clean
    // close checkpoints and deletes the `-shm` file, and a READ-ONLY connection cannot
    // recreate it — so both opens below fail with "unable to open database file" against a
    // WAL database nobody is holding. Production is the held case: Messages.app is running
    // and owns the WAL the whole time this server is reading. Keeping the writer open is
    // what makes this measurement resemble that rather than an empty machine.
    self.writer = queue

    singleConnection = try ReadOnlyDatabase(path: path)
    pooled = try ReadOnlyDatabase(path: path, maximumReaders: 4)
    profile = try await SchemaProfile.detect(in: singleConnection, osMajorVersion: 14)
  }

  func tearDown() {
    try? writer.close()
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }
}

//  CountCachingTests
//  Counts that cannot be indexed are remembered instead.
//
//  Two of this repository's counts have no index behind them and cannot get one.
//  `count/updated` filters on `date_delivered` and `date_read`, which Apple leaves unindexed,
//  and `balloonIcon` matches `balloon_bundle_id`, which is also unindexed -- and adding an
//  index to chat.db is not something this server may do. The database is Apple's, opened
//  read-only, and its schema stays exactly as Messages wrote it.
//
//  So the scans stay and the ANSWERS are cached. `PRAGMA data_version` changes whenever
//  another connection commits, which for chat.db means Messages, so two equal tokens mean
//  nothing was written in between and a count cannot have moved.
//
//  What these assert is that the cache serves the same answer the query would have, and stops
//  serving it the moment the database moves.

import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Count caching", .serialized)
struct CountCachingTests {

  /// Counts every statement, so "was the query re-run" is answerable.
  private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func record(_ sql: String) { lock.withLock { statements.append(sql) } }
    func reset() { lock.withLock { statements.removeAll() } }
    /// Only the counting statements; the token read is a PRAGMA and runs every time.
    var counts: Int { matching("COUNT(") }

    /// Statements containing `needle`, case-insensitively.
    func matching(_ needle: String) -> Int {
      lock.withLock {
        statements.filter { $0.uppercased().contains(needle.uppercased()) }.count
      }
    }
  }

  /// - Returns: ONE repository instance, not a fresh one per access.
  ///
  /// `ChatDatabaseFixture.repository` is a computed property, so every read of it builds a
  /// new value with a new cache -- which is right for the fixture and wrong for a test of
  /// caching. In the server the repository is built once, at composition.
  private func open() async throws -> (ChatDatabaseFixture, MessageRepository, StatementLog) {
    let fixture = try await ChatDatabaseFixture()
    let log = StatementLog()
    let database = try ReadOnlyDatabase(
      path: fixture.path, observingStatements: { [log] in log.record($0) })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    return (fixture, MessageRepository(database: database, profile: profile), log)
  }

  @Test("A repeated count is served without re-running the query")
  func repeatedCountIsCached() async throws {
    let (fixture, repository, log) = try await open()
    defer { fixture.tearDown() }

    let query = MessageRepository.MessageQuery()
    let first = try await repository.messageCount(query)
    #expect(first > 0, "the fixture counted nothing, so this proves nothing")

    log.reset()
    let second = try await repository.messageCount(query)
    #expect(second == first)
    #expect(log.counts == 0, "the count query ran \(log.counts) times on a cache hit")
  }

  /// The correctness half. A commit moves `data_version`, and the next count must see it.
  @Test("A write to the database invalidates the count")
  func writeInvalidatesTheCount() async throws {
    let (fixture, repository, log) = try await open()
    defer { fixture.tearDown() }

    let query = MessageRepository.MessageQuery()
    let before = try await repository.messageCount(query)

    // Exactly what Messages does: another connection commits.
    _ = try await fixture.insertMessage(
      guid: "CACHE-TEST-1", text: "a new message", at: Date())

    log.reset()
    let after = try await repository.messageCount(query)
    #expect(after == before + 1, "the cache served a stale count across a write")
    #expect(log.counts > 0, "the query must actually re-run once the database has moved")
  }

  /// Different queries must not share an answer.
  @Test("Two different counts do not collide in the cache")
  func differentQueriesAreSeparate() async throws {
    let (fixture, repository, _) = try await open()
    defer { fixture.tearDown() }

    let all = try await repository.messageCount(MessageRepository.MessageQuery())
    let fromMe = try await repository.messageCount(
      MessageRepository.MessageQuery(onlyFromMe: true))
    #expect(all > 0)
    #expect(fromMe > 0, "the fixture has no outgoing messages, so this cannot distinguish")
    #expect(all != fromMe, "the two counts are equal, so a collision would be invisible")

    // And again, from the cache.
    #expect(try await repository.messageCount(MessageRepository.MessageQuery()) == all)
    #expect(
      try await repository.messageCount(MessageRepository.MessageQuery(onlyFromMe: true))
        == fromMe)
  }

  /// The artwork lookup scans every row, so a repeat must not.
  @Test("A balloon icon lookup is not repeated for the same app")
  func balloonIconIsCached() async throws {
    let (fixture, repository, log) = try await open()
    defer { fixture.tearDown() }

    // Nothing in the fixture sent one, which is the EXPENSIVE case: a full scan that finds
    // nothing costs the same as one that finds something, and it is the common case on a
    // real Mac.
    let first = try await repository.balloonIcon(bundleID: "com.example.nosuchapp")
    #expect(first == nil)

    // The scan has to have run the first time, or "it did not run again" means nothing.
    #expect(log.matching("balloon_bundle_id") > 0, "the first lookup did not query at all")

    log.reset()
    let second = try await repository.balloonIcon(bundleID: "com.example.nosuchapp")
    #expect(second == nil)
    let scans = log.matching("balloon_bundle_id")
    #expect(scans == 0, "the scan ran \(scans) more times on a cache hit")
  }

  @Test("A different app is looked up separately")
  func balloonIconKeyedByBundle() async throws {
    let (fixture, repository, log) = try await open()
    defer { fixture.tearDown() }
    #expect(try await repository.balloonIcon(bundleID: "com.example.a") == nil)
    let afterFirst = log.matching("balloon_bundle_id")
    #expect(try await repository.balloonIcon(bundleID: "com.example.b") == nil)
    #expect(
      log.matching("balloon_bundle_id") > afterFirst,
      "a second app was answered from the first app's entry")
  }
}

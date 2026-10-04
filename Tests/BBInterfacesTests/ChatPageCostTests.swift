//  ChatPageCostTests
//  What a page of chats COSTS, which no behavioural test can see.
//
//  `POST /chat/query` is the route every client hits when it connects, `Query.parse` sets
//  `withParticipants` unconditionally, and the limit defaults to 1000. `project` batched the
//  last-message sender lookup through `handles(rowIDs:)` and then, three lines below, called
//  `participants(chatGUID:)` once per row — so on a real Mac (486 chats measured) one request
//  issued 486 sequential queries, every one serialising through the single `DatabaseQueue`
//  while the change detector's tick and every other request queued behind it. The function's
//  own comment already recorded the measurement for the identical pattern it had just fixed
//  one loop earlier: 165 ms against 5 ms.
//
//  An N+1 passes every behavioural assertion there is, which is the whole reason this file
//  exists. It counts statements through GRDB's trace hook — `ReadOnlyDatabase` takes an
//  `observingStatements` closure for exactly this.
//
//  The assertion is COMPARATIVE rather than an absolute ceiling, and that is deliberate: a
//  magic number has to be re-guessed whenever GRDB changes how many pragmas it issues, and it
//  says nothing about the property under test. Asking for a few chats and then for many and
//  requiring the SAME statement count says exactly the thing an N+1 violates — the cost does
//  not scale with the page — and it holds however many statements the page costs.
//
//  Two sizes cannot be required to cost EXACTLY the same, and the reason is worth writing down
//  because this file asserted it on its first draft and reported a defect that was not there.
//  The batch loaders return early on an empty input, so a page whose chats happen to have no
//  last-message sender never runs that query at all — a fixed difference of a couple of
//  statements that has nothing to do with N+1.
//
//  So the assertion is on the GROWTH: going from a small page to a large one may add a
//  constant, and must not add anything per chat. That is precisely what an N+1 does and what a
//  batch does not, and it holds whatever the constant turns out to be.
//
//  Each test also asserts the participants still ARRIVE, because a loader that returned
//  nothing would satisfy every count assertion here triumphantly.

import BBContacts
import BBIMessage
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Chat page cost")
struct ChatPageCostTests {

  /// A counter the trace hook can write to from wherever GRDB calls it.
  private final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var selects: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    func record() { lock.withLock { count += 1 } }
  }

  private struct Harness {
    let interface: ChatInterface
    /// Contacts off, so the count is the chat.db read alone: the contact index is a
    /// different database and its one batched lookup is not what this file measures.
    let directory: ConversationDirectory
    let counter: StatementCounter
  }

  /// Chats seeded on top of the fixture, each with its own participant.
  ///
  /// The fixture holds three, which is too few to tell a batch from a loop: see the header.
  /// These are written BEFORE the read-only connection is opened, into a throwaway copy, so
  /// `chat.db` itself is untouched and the rule about never writing to it is not bent.
  private static let seededChats = 40

  /// The real fixture database, read-only, at a throwaway path.
  private func harness() async throws -> Harness {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("BBIMessageTests/ChatDBFixtures/chat-sonoma.db")
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-chat-cost-\(UUID().uuidString).db")
    try FileManager.default.copyItem(at: source, to: path)
    try Self.seed(into: path)

    let counter = StatementCounter()
    let database = try ReadOnlyDatabase(
      path: path.path, observingStatements: { _ in counter.record() })
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let repository = MessageRepository(database: database, profile: profile)
    let appDatabase = AppDatabase(queue: try DatabaseQueue())
    try appDatabase.migrate(contributors: [ContactsSchema.self])
    return Harness(
      interface: ChatInterface(
        repository: repository,
        serializer: MessageSerializer(profile: profile)
      ),
      directory: ConversationDirectory(
        repository: repository, contacts: ContactIndex(database: appDatabase),
        contactsEnabled: { false }),
      counter: counter
    )
  }

  /// Runs `body` and reports what it cost, ignoring everything before it.
  private func cost(_ harness: Harness, _ body: () async throws -> Void) async rethrows -> Int {
    harness.counter.reset()
    try await body()
    return harness.counter.selects
  }

  /// Adds chats, handles and the joins between them to a COPY of the fixture.
  ///
  /// Addresses are the reserved `+1555…` range the test-data policy requires; nothing here
  /// resembles a real person.
  private static func seed(into path: URL) throws {
    // GRDB rather than raw SQLite3, so this needs no external module the package graph would
    // have to declare for one test.
    let queue = try DatabaseQueue(path: path.path)
    try queue.write { db in
      for index in 0..<seededChats {
        let number = String(format: "+1555000%04d", index)
        try db.execute(
          sql: """
            INSERT INTO handle (id, country, service, uncanonicalized_id)
            VALUES (?, 'us', 'iMessage', ?)
            """,
          arguments: [number, number])
        try db.execute(
          sql: """
            INSERT INTO chat (guid, style, state, chat_identifier, service_name, is_archived)
            VALUES (?, 45, 3, ?, 'iMessage', 0)
            """,
          arguments: ["any;-;\(number)", number])
        try db.execute(
          sql: """
            INSERT INTO chat_handle_join (chat_id, handle_id)
            VALUES (last_insert_rowid(), (SELECT MAX(ROWID) FROM handle))
            """)
      }
    }
    // Closed before the read-only connection opens, so nothing is holding a write lock.
    try queue.close()
  }

  @Test("Querying chats costs the same for a small page as for a large one")
  func chatQueryIsNotNPlusOne() async throws {
    let harness = try await harness()
    // Detecting the schema profile is not what is being measured, and `cost` resets first.
    let all = try await harness.interface.query(ChatInterface.Query())
    #expect(all.count >= Self.seededChats, "the seeded chats should be readable")

    func run(limit: Int) async throws -> Int {
      try await cost(harness) {
        _ = try await harness.interface.query(
          ChatInterface.Query(limit: limit, withParticipants: true, withLastMessage: true))
      }
    }

    let few = try await run(limit: 5)
    let many = try await run(limit: all.count)

    // Growth, not equality. `extra` is how many more chats the large page carried; an N+1
    // would add at least one statement for each of them, and a batch adds a small constant.
    let extra = all.count - 5
    let growth = many - few
    let report = "5 chats cost \(few) statements and \(all.count) cost \(many)"
    #expect(growth < extra, "\(report): \(growth) more for \(extra) more chats is per-chat")
    // And in absolute terms, so a future change cannot satisfy the above by making the small
    // page expensive too.
    #expect(many < all.count, "\(report): a page should not cost a statement per chat")
  }

  @Test("Participants still arrive")
  func participantsAreLoaded() async throws {
    // The half that makes the count assertions mean anything.
    let harness = try await harness()
    let projections = try await harness.interface.query(
      ChatInterface.Query(withParticipants: true))
    #expect(
      projections.contains { !$0.participants.isEmpty },
      "a batch that returns no participants is not a fix")
  }

  @Test("The conversation directory costs the same for a small list as for a large one")
  func directoryIsNotNPlusOne() async throws {
    // The list every picker in the app reads, on open, 500 at a time: participants, last
    // messages and names for the whole list in a constant number of statements.
    let harness = try await harness()
    let directory = harness.directory
    let all = try await directory.list()
    #expect(all.count >= Self.seededChats)
    #expect(all.contains { !$0.participants.isEmpty })

    let few = try await cost(harness) { _ = try await directory.list(limit: 5) }
    let many = try await cost(harness) { _ = try await directory.list(limit: all.count) }

    let extra = all.count - 5
    let growth = many - few
    let report = "5 chats cost \(few) statements and \(all.count) cost \(many)"
    #expect(growth < extra, "\(report): \(growth) more for \(extra) more chats is per-chat")
    #expect(many < all.count, "\(report): a list should not cost a statement per chat")
  }

  @Test("Not asking for participants does not load them")
  func participantsAreOptional() async throws {
    // The batch must stay behind the same flag the per-row call was behind, or a caller that
    // deliberately skipped participants now pays for them.
    let harness = try await harness()

    let without = try await cost(harness) {
      _ = try await harness.interface.query(
        ChatInterface.Query(withParticipants: false, withLastMessage: false))
    }
    let with = try await cost(harness) {
      _ = try await harness.interface.query(
        ChatInterface.Query(withParticipants: true, withLastMessage: false))
    }

    #expect(without < with, "asking for no participants should not load them")
  }
}

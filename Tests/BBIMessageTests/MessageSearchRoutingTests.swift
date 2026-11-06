//  MessageSearchRoutingTests
//  The defect this whole feature exists to fix, pinned.
//
//  macOS 26 stopped populating `message.text`. The words live in `attributedBody`, the
//  serializer reads through to them so the message DISPLAYS correctly, and
//  `message.text LIKE ?` matches nothing — so a user searches for a word they can see on
//  screen and gets `200` with `total: 0`. Measured on a real database: 99.8% of one month's
//  messages, incoming as well as outgoing.
//
//  The first test below is the one that matters, and it asserts the ROWS AND THE TOTAL,
//  because they are computed by different call paths that share one predicate. A search that
//  returned the right page beside a total counting the whole database would be the same class
//  of bug as the one that made the incremental sync page everything.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Message search routing", .serialized)
struct MessageSearchRoutingTests {

  /// A chat.db fixture and an index over it, both thrown away with the test.
  private struct Harness {
    let fixture: ChatDatabaseFixture
    let store: SearchIndexStore
    let root: URL
    var repository: MessageRepository {
      MessageRepository(
        database: fixture.database, profile: fixture.profile, searchIndex: store)
    }
  }

  private func harness() async throws -> Harness {
    let fixture = try await ChatDatabaseFixture()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-search-route-\(UUID().uuidString)", isDirectory: true)
    let store = SearchIndexStore(url: root.appendingPathComponent("index.db"))
    try await store.open()
    return Harness(fixture: fixture, store: store, root: root)
  }

  /// Indexes a row by hand. The real indexer is step 4; this stands in for it so the read
  /// path can be tested on its own.
  private func index(_ harness: Harness, rowID: Int64, text: String) async throws {
    let queue = try await harness.store.connection()
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO message_search(rowid, text) VALUES (?, ?)",
        arguments: [rowID, text])
    }
  }

  private func rowID(of guid: String, in harness: Harness) async throws -> Int64 {
    try await harness.fixture.database.read { db in
      try Int64.fetchOne(db, sql: "SELECT ROWID FROM message WHERE guid = ?", arguments: [guid])
        ?? 0
    }
  }

  private func query(_ term: String) -> MessageRepository.MessageQuery {
    var query = MessageRepository.MessageQuery()
    query.filters = [.textLike(term)]
    query.limit = 100
    return query
  }

  // MARK: The defect

  @Test("A message whose text column is empty is found by its words, and counted")
  func emptyTextIsFoundThroughTheIndex() async throws {
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }

    // The macOS 26 shape: a row that displays fine and whose `text` column is empty.
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-EMPTY-1", text: "", at: Date().addingTimeInterval(-60))
    let rowID = try await rowID(of: guid, in: harness)
    try await index(harness, rowID: rowID, text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    // What a client sends.
    let rows = try await harness.repository.messages(query("%dinner%"))
    #expect(rows.map(\.guid) == [guid], "the message was not found by a word in its body")

    // And the total, which travels beside the page and is the half that was silently wrong.
    let total = try await harness.repository.messageCount(query("%dinner%"))
    #expect(total == 1, "rows and total must agree; got \(total)")
  }

  @Test("Without the index the same search finds nothing, which is the bug")
  func withoutTheIndexTheBugIsStillThere() async throws {
    // The control. It documents the behaviour being fixed, and it fails the day someone
    // makes `LIKE` reach `attributedBody` — at which point this file needs rewriting rather
    // than deleting.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    _ = try await harness.fixture.insertMessage(
      guid: "SEARCH-EMPTY-2", text: "", at: Date().addingTimeInterval(-60))

    let plain = MessageRepository(
      database: harness.fixture.database, profile: harness.fixture.profile)
    #expect(try await plain.messages(query("%dinner%")).isEmpty)
    #expect(try await plain.messageCount(query("%dinner%")) == 0)
  }

  // MARK: The total, which shares a predicate with the page

  @Test("A search scoped to a chat does not report the whole chat as its total")
  func scopedSearchTotalIsNotTheWholeChat() async throws {
    // `countsAWholeChat` takes a much faster join-only count when a query has no conditions
    // — and resolving a search REMOVES the `.textLike` filter, so without an explicit guard
    // the query looks condition-free and the total becomes the chat's entire message count.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }

    var matching: String?
    for index in 0..<5 {
      let guid = try await harness.fixture.insertMessage(
        guid: "SEARCH-CHAT-\(index)", text: "",
        at: Date().addingTimeInterval(Double(-600 + index)), chat: 1)
      let rowID = try await rowID(of: guid, in: harness)
      // One of the five carries the word.
      let text = index == 2 ? "the harbour at dusk" : "something else entirely"
      try await self.index(harness, rowID: rowID, text: text)
      if index == 2 { matching = guid }
    }
    try await harness.store.setBackfillComplete(true)

    var scoped = query("%harbour%")
    scoped.chatGUID = ChatDatabaseFixture.chatGUID(ChatDatabaseFixture.aliceAddress)
    let total = try await harness.repository.messageCount(scoped)
    #expect(total == 1, "the total counted \(total), which looks like the whole chat")
    #expect(matching != nil)
  }

  @Test("A term nothing matches returns nothing, not everything")
  func noMatchesMeansNoRows() async throws {
    // The `.guidIn` failure in a different costume: a search that finds nothing must not
    // come back as every message in the database.
    //
    // This now reaches that answer through the `LIKE` fallback rather than through the
    // index's empty set — see `infixTermFallsBackToLike` — and the assertion is the same
    // either way, which is the point of it: whichever path answers, "no matches" means no
    // rows and a total of zero.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-NONE-1", text: "", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "nothing relevant")
    try await harness.store.setBackfillComplete(true)

    #expect(try await harness.repository.messages(query("%aardvark%")).isEmpty)
    #expect(try await harness.repository.messageCount(query("%aardvark%")) == 0)
  }

  // MARK: When the index must not be used

  @Test("An incomplete backfill falls back rather than under-reporting")
  func incompleteBackfillFallsBack() async throws {
    // Answering from a half-built index under-reports SILENTLY, which is the same failure
    // this feature exists to fix wearing a different hat. Until the backfill finishes the
    // query takes the `LIKE` path: still wrong on macOS 26, but wrong in the way it was
    // already wrong rather than in a new way.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-PARTIAL-1", text: "", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    // Deliberately NOT marked complete.

    #expect(try await harness.repository.messages(query("%dinner%")).isEmpty)
  }

  @Test("A text column that IS populated still matches, through the index")
  func populatedTextStillMatches() async throws {
    // Older history has a real `text` column, and the index covers it too — the indexer
    // reads the column when it is there and decodes only when it is not. What must not
    // happen is the two paths disagreeing about the same message.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-PLAIN-1", text: "dinner at the harbour", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    #expect(try await harness.repository.messages(query("%dinner%")).map(\.guid) == [guid])

    // And the same query without an index finds it the old way, because the column is there.
    let plain = MessageRepository(
      database: harness.fixture.database, profile: harness.fixture.profile)
    #expect(try await plain.messages(query("%dinner%")).map(\.guid) == [guid])
  }

  @Test("A prefix is matched by the index; a fragment in the middle of a word is not")
  func prefixMatchesAndInfixDoesNot() async throws {
    // The documented divergence from `LIKE`, asserted in both directions so it is a decision
    // rather than a surprise. `%harb%` finds "harbour" because tokens are indexed by where
    // they START; `%bour%` does not, because no token begins with it.
    //
    // This measures the INDEX, which is why the row's `text` column is empty: with nothing
    // for `LIKE` to match, the fallback below cannot mask what the index did. The behaviour
    // a client actually sees when the column is populated is `infixTermFallsBackToLike`.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-FRAGMENT-1", text: "", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    #expect(try await harness.repository.messages(query("%harb%")).map(\.guid) == [guid])
    #expect(try await harness.repository.messages(query("%bour%")).isEmpty)
  }

  // MARK: What the index must never take away

  @Test("A fragment in the middle of a word still finds what LIKE found")
  func infixTermFallsBackToLike() async throws {
    // THE REGRESSION THIS GUARDS. The index answers "which messages hold a token starting
    // with this", the column answers "which messages contain this substring", and NEITHER
    // answer contains the other — so the condition is their union and the index can only
    // ever add rows. Replacing the column match with the index's took them away: measured
    // against a real database, `%omorrow%` went from 2,020 messages to none, which is the
    // exact defect the whole feature exists to remove, reintroduced by the fix.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    // Populated `text`, which is what every Mac below macOS 26 has, and what this one has
    // for everything sent before it updated.
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-INFIX-1", text: "dinner at the harbour", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    #expect(
      try await harness.repository.messages(query("%bour%")).map(\.guid) == [guid],
      "the index answered an infix term with nothing instead of standing aside")
    #expect(try await harness.repository.messageCount(query("%bour%")) == 1)
  }

  @Test("A term the index partly matches keeps the rows only LIKE can find")
  func partialIndexMatchStillUnionsWithLike() async throws {
    // The case an "empty answer means fall back" rule does NOT catch, and the reason the
    // condition is a union rather than a fallback. Here the index matches exactly one
    // message by prefix, which looks like a working answer, while the column match has
    // another the index cannot reach — a fragment mid-word. Taking the index's answer for
    // the whole question drops the second.
    //
    // Measured against a real database before this was a union: `%morrow%` matched one
    // token by prefix and reported ONE result where `LIKE` had reported 2,031.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }

    // Reachable only by the index: its column is empty, and a token starts with the term.
    let indexed = try await harness.fixture.insertMessage(
      guid: "SEARCH-UNION-INDEX", text: "", at: Date().addingTimeInterval(-30))
    try await index(harness, rowID: rowID(of: indexed, in: harness), text: "morrow is the day")

    // Reachable only by the column: the term sits inside a word, so no token begins with it.
    let liked = try await harness.fixture.insertMessage(
      guid: "SEARCH-UNION-LIKE", text: "see you tomorrow", at: Date().addingTimeInterval(-20))
    try await index(harness, rowID: rowID(of: liked, in: harness), text: "see you tomorrow")
    try await harness.store.setBackfillComplete(true)

    let found = Set(try await harness.repository.messages(query("%morrow%")).map(\.guid))
    #expect(
      found == [indexed, liked],
      "the union lost a half; got \(found.sorted())")
    #expect(try await harness.repository.messageCount(query("%morrow%")) == 2)
  }

  @Test("A script the tokenizer does not break into words still finds what LIKE found")
  func unspacedScriptFallsBackToLike() async throws {
    // `unicode61` splits on anything that is not a letter or a digit, and every character
    // of Chinese, Japanese or Thai is a letter — so a whole sentence in one of them is ONE
    // token. Measured directly against the shipped table definition:
    // `明天我们去吃晚饭好吗` is a single term in `fts5vocab`, and `晚饭` matches nothing.
    //
    // Without the fallback, turning this feature on switched message search OFF for those
    // users. It is the same defect as the infix case and it is worth its own test because
    // the cause is different: there the term is a fragment, here the STORED TEXT is one
    // enormous token.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let sentence = "明天我们去吃晚饭好吗"
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-CJK-1", text: sentence, at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: sentence)
    try await harness.store.setBackfillComplete(true)

    // The run STARTS with this, so the index's prefix match does reach it.
    #expect(try await harness.repository.messages(query("%明天%")).map(\.guid) == [guid])
    // This one is inside the run, so only the fallback can.
    #expect(
      try await harness.repository.messages(query("%晚饭%")).map(\.guid) == [guid],
      "a word inside an unspaced sentence was lost")
  }

  @Test("An index that cannot be read falls back instead of failing the request")
  func unreadableIndexFallsBack() async throws {
    // The read is not the caller's to recover from — the answer is always `LIKE` — so
    // `matchingRowIDs` reports its own failure and returns nil rather than throwing. What
    // must not happen is a 500 on a search because a cache file went bad.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-CLOSED-1", text: "dinner at the harbour", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)
    // Closed under the repository, which still holds the same store.
    try await harness.store.close()

    #expect(try await harness.repository.messages(query("%dinner%")).map(\.guid) == [guid])
  }

  @Test("An `ends with` term is refused, and takes the LIKE path instead")
  func endsWithFallsBack() async throws {
    // `%harbour` with no trailing wildcard asks a question an inverted index cannot answer.
    // Refusing it means `LIKE` still finds what it always found, rather than the index
    // confidently returning nothing.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-ENDS-1", text: "dinner at the harbour", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    #expect(try await harness.repository.messages(query("%harbour")).map(\.guid) == [guid])
  }

  @Test("Two text conditions are both widened, and both still have to match")
  func twoTermsAreBothWidened() async throws {
    // The union composes under `AND`, so each text condition becomes its own bracketed
    // `OR` and the `AND` already between filters does the combining. No set arithmetic —
    // which is what the single-condition restriction used to exist for, under the
    // replacement shape where two answers really would have had to be intersected.
    //
    // The row that proves it is the macOS 26 one: an empty `text` column, both words only
    // in the index. Under the old restriction both conditions fell back to `LIKE` and it
    // was found by neither.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }

    let both = try await harness.fixture.insertMessage(
      guid: "SEARCH-TWO-BOTH", text: "", at: Date().addingTimeInterval(-30))
    try await index(harness, rowID: rowID(of: both, in: harness), text: "dinner at the harbour")

    // Only one of the two words, so it must NOT come back: widening each condition must
    // not weaken the `AND` between them.
    let one = try await harness.fixture.insertMessage(
      guid: "SEARCH-TWO-ONE", text: "", at: Date().addingTimeInterval(-20))
    try await index(harness, rowID: rowID(of: one, in: harness), text: "dinner tomorrow")
    try await harness.store.setBackfillComplete(true)

    var query = MessageRepository.MessageQuery()
    query.filters = [.textLike("%dinner%"), .textLike("%harbour%")]
    query.limit = 100

    #expect(try await harness.repository.messages(query).map(\.guid) == [both])
    #expect(try await harness.repository.messageCount(query) == 1)
  }

  @Test("A term the index cannot express still lets the other one be widened")
  func oneUnanswerableTermDoesNotBlockTheOther() async throws {
    // Each filter is decided on its own. `%harbour` is "ends with", which an inverted
    // index cannot answer at all, and it must not take the answerable condition down with
    // it — which is what a single all-or-nothing decision over the whole query did.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    // `text` populated, so the unanswerable condition can still match through `LIKE`.
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-MIXED-1", text: "dinner at the harbour", at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: "dinner at the harbour")
    try await harness.store.setBackfillComplete(true)

    var query = MessageRepository.MessageQuery()
    query.filters = [.textLike("%dinner%"), .textLike("%harbour")]
    query.limit = 100
    #expect(try await harness.repository.messages(query).map(\.guid) == [guid])
  }

  @Test("Past the ceiling, a text condition keeps the plain LIKE it always had")
  func termsPastTheCeilingFallBack() async throws {
    // The bound is on the statement, not on what the route accepts: every condition still
    // applies, the extras just apply the old way. Asserted as "the answer is still right",
    // because that is the only part a client can see.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    #expect(
      words.count > MessageRepository.maximumIndexedTextTerms,
      "the test needs more terms than the ceiling admits")

    // Populated `text`, so the conditions past the ceiling can still match through `LIKE`.
    let sentence = words.joined(separator: " ")
    let guid = try await harness.fixture.insertMessage(
      guid: "SEARCH-CEILING-1", text: sentence, at: Date())
    try await index(harness, rowID: rowID(of: guid, in: harness), text: sentence)
    try await harness.store.setBackfillComplete(true)

    var query = MessageRepository.MessageQuery()
    query.filters = words.map { .textLike("%\($0)%") }
    query.limit = 100
    #expect(try await harness.repository.messages(query).map(\.guid) == [guid])
    #expect(try await harness.repository.messageCount(query) == 1)
  }

  // MARK: Anchored terms

  /// A message in the macOS 26 shape: empty `text`, its words in `attributedBody`, and the
  /// index holding the same words. Only the index can find it, so what it finds is what the
  /// re-check decides.
  private func bodyOnlyMessage(
    _ harness: Harness, guid: String, words: String, secondsAgo: Double
  ) async throws -> String {
    let inserted = try await harness.fixture.insertMessage(
      guid: guid, text: "", at: Date().addingTimeInterval(-secondsAgo))
    try await harness.fixture.setAttributedBody(
      guid: inserted,
      try NSKeyedArchiver.archivedData(
        withRootObject: NSAttributedString(string: words), requiringSecureCoding: false))
    try await index(harness, rowID: rowID(of: inserted, in: harness), text: words)
    return inserted
  }

  @Test("`word%` stays a prefix: the text must START with it, and the total agrees")
  func prefixTermStaysAPrefix() async throws {
    // The index answers "a token starting with dinner" for both of these; `LIKE 'dinner%'`
    // matches only the first. Unioning the index's answer as it was made the search
    // BROADER than the statement the client wrote.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let starts = try await bodyOnlyMessage(
      harness, guid: "SEARCH-PREFIX-1", words: "Dinner at the harbour", secondsAgo: 60)
    _ = try await bodyOnlyMessage(
      harness, guid: "SEARCH-PREFIX-2", words: "after dinner we walked", secondsAgo: 30)
    try await harness.store.setBackfillComplete(true)

    // Case-insensitive, as `LIKE` is for ASCII.
    #expect(try await harness.repository.messages(query("dinner%")).map(\.guid) == [starts])
    #expect(try await harness.repository.messageCount(query("dinner%")) == 1)
  }

  @Test("A bare `word` stays exact: the text must BE it, and the total agrees")
  func exactTermStaysExact() async throws {
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let exact = try await bodyOnlyMessage(
      harness, guid: "SEARCH-EXACT-1", words: "dinner", secondsAgo: 60)
    _ = try await bodyOnlyMessage(
      harness, guid: "SEARCH-EXACT-2", words: "dinner at the harbour", secondsAgo: 30)
    try await harness.store.setBackfillComplete(true)

    #expect(try await harness.repository.messages(query("dinner")).map(\.guid) == [exact])
    #expect(try await harness.repository.messageCount(query("dinner")) == 1)
  }

  @Test("`%word%` is still unanchored, so the re-check does not narrow it")
  func containsTermIsNotReChecked() async throws {
    // The control for the two above: a re-check applied to every term would pass them and
    // lose this, which is the ordinary search every client sends.
    let harness = try await harness()
    defer {
      harness.fixture.tearDown()
      try? FileManager.default.removeItem(at: harness.root)
    }
    let first = try await bodyOnlyMessage(
      harness, guid: "SEARCH-CONTAINS-1", words: "dinner at the harbour", secondsAgo: 60)
    let second = try await bodyOnlyMessage(
      harness, guid: "SEARCH-CONTAINS-2", words: "after dinner we walked", secondsAgo: 30)
    try await harness.store.setBackfillComplete(true)

    #expect(
      Set(try await harness.repository.messages(query("%dinner%")).map(\.guid))
        == [first, second])
    #expect(try await harness.repository.messageCount(query("%dinner%")) == 2)
  }
}

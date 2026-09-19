//  ContactSearchTests
//  Paging and searching in SQL, which is what lets the app stop loading the address book.
//
//  The page used to read every contact and filter in memory, so the read was capped — and the
//  cap disagreed with the interface's own clamp, which silently truncated any address book
//  over a thousand contacts. Filtering, counting and ordering now happen in the database, so
//  a page is a page.
//
//  The properties worth holding: the count is of MATCHES rather than of the page; a page is a
//  window onto a DATABASE ordering, not onto whatever the app happened to load; and a query
//  containing a wildcard character searches for that character.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBContacts

/// The index and the database behind it: one test has to reach past the index to put a row
/// into the state an upgrade leaves it in.
private func searchIndex() throws -> (ContactIndex, AppDatabase) {
  let queue = try DatabaseQueue()
  let database = AppDatabase(queue: queue)
  try database.migrate(contributors: [ContactsSchema.self])
  return (ContactIndex(database: database), database)
}

@Suite("Contact search and paging")
struct ContactSearchTests {

  private func seed(_ index: ContactIndex) async throws {
    try await index.upsert([
      ContactRecord(
        id: "1", source: .macOS, firstName: "Ada", lastName: "Lovelace",
        phoneNumbers: ["+1 (555) 010-1234"], emailAddresses: ["ada@example.com"]),
      ContactRecord(
        id: "2", source: .macOS, firstName: "Grace", lastName: "Hopper",
        phoneNumbers: ["+1 (555) 010-9999"], emailAddresses: ["grace@example.com"]),
      ContactRecord(
        id: "3", source: .local, firstName: "Alan", lastName: "Turing",
        emailAddresses: ["alan@example.com"]),
    ])
  }

  @Test("An empty query returns everything, counted")
  func emptyQueryReturnsAll() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(query: "", limit: 10, offset: 0)
    #expect(page.total == 3)
    #expect(page.contacts.count == 3)
  }

  /// The count is of MATCHES, not of the page. "Showing 1-2 of 3" needs both numbers, and
  /// taking them from two reads is how the page reports a total an ingest has already changed.
  @Test("The total counts matches, not the page")
  func totalCountsMatches() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(query: "", limit: 2, offset: 0)
    #expect(page.contacts.count == 2)
    #expect(page.total == 3)
  }

  @Test("Paging walks the whole ordered set without repeating or skipping")
  func pagingIsStable() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    var seen: [String] = []
    for offset in stride(from: 0, to: 3, by: 2) {
      let page = try await index.search(query: "", limit: 2, offset: offset)
      seen += page.contacts.map(\.id)
    }
    #expect(seen.count == 3)
    #expect(Set(seen).count == 3, "a page repeated a contact: \(seen)")
  }

  @Test("Search matches a name fragment, case-insensitively")
  func searchesNames() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(query: "LOVEL", limit: 10, offset: 0)
    #expect(page.total == 1)
    #expect(page.contacts.first?.firstName == "Ada")
  }

  /// The reason `AddressFormatting` had to move into `BBCore`: the table shows the formatted
  /// number, so the formatted number has to be searchable.
  @Test("Search matches the formatted number as well as the stored one")
  func searchesFormattedAndStoredNumbers() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    // As displayed.
    #expect(try await index.search(query: "(555) 010-1234", limit: 10, offset: 0).total == 1)
    // As stored, and as somebody would type it.
    #expect(try await index.search(query: "5550101234", limit: 10, offset: 0).total == 1)
  }

  @Test("Search matches an email fragment")
  func searchesEmails() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(query: "grace@", limit: 10, offset: 0)
    #expect(page.total == 1)
    #expect(page.contacts.first?.lastName == "Hopper")
  }

  /// A query containing `%` is a person looking for a percent sign, not a wildcard. Unescaped
  /// it matched every contact, which reads as search being broken rather than as finding none.
  @Test("Wildcard characters are searched for, not interpreted")
  func wildcardsAreEscaped() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    #expect(try await index.search(query: "%", limit: 10, offset: 0).total == 0)
    #expect(try await index.search(query: "_", limit: 10, offset: 0).total == 0)
  }

  @Test("Ordering by name is the database's, ascending and descending")
  func ordersByName() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let ascending = try await index.search(
      query: "", order: .name, ascending: true, limit: 10, offset: 0)
    #expect(ascending.contacts.map(\.firstName) == ["Ada", "Alan", "Grace"])

    let descending = try await index.search(
      query: "", order: .name, ascending: false, limit: 10, offset: 0)
    #expect(descending.contacts.map(\.firstName) == ["Grace", "Alan", "Ada"])
  }

  /// A page is a window onto the ORDERED set. Sorting in the app would reorder only the rows
  /// it happened to hold, behind a control that looks identical to one sorting everything.
  @Test("The order decides which rows a page contains")
  func orderDecidesThePage() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let first = try await index.search(
      query: "", order: .name, ascending: false, limit: 1, offset: 0)
    #expect(first.contacts.map(\.firstName) == ["Grace"])
  }

  /// A contact with no address of that kind sorts last rather than first: an empty column at
  /// the top of a sorted table looks like the sort did not happen.
  @Test("Sorting by phone puts contacts without one last")
  func missingAddressesSortLast() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(
      query: "", order: .phone, ascending: true, limit: 10, offset: 0)
    #expect(page.contacts.last?.firstName == "Alan", "the contact with no phone is not last")
  }

  @Test("Sorting by email orders by the address shown")
  func ordersByEmail() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(
      query: "", order: .email, ascending: true, limit: 10, offset: 0)
    #expect(page.contacts.map(\.firstName) == ["Ada", "Alan", "Grace"])
  }

  /// What a Google account being unlinked looks like from the page's side: the rows are gone,
  /// and the total has to go with them or the footer offers pages that do not exist.
  @Test("Removed contacts leave both the page and the total")
  func removalShrinksTheTotal() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    try await index.removeAll(source: .macOS)

    let page = try await index.search(query: "", limit: 10, offset: 0)
    #expect(page.total == 1)
    #expect(page.contacts.map(\.id) == ["3"])
  }

  /// An offset past the end answers empty rather than throwing, and still reports the real
  /// total, which is what lets the page clamp itself back into range.
  @Test("An offset past the end is empty, and says how many there are")
  func offsetPastTheEnd() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let page = try await index.search(query: "", limit: 10, offset: 500)
    #expect(page.contacts.isEmpty)
    #expect(page.total == 3)
  }

  /// The upgrade path. A row indexed before the haystack column existed has NULL in it, and
  /// must stay findable by name until its next re-index rather than vanishing from search.
  @Test("A contact indexed before the haystack existed is still findable")
  func nullHaystackFallsBack() async throws {
    let (index, database) = try searchIndex()
    try await seed(index)
    // Exactly what the migration leaves behind for a row indexed before it ran.
    try await database.write { db in
      try db.execute(sql: "UPDATE contact SET search_haystack = NULL WHERE id = '1'")
    }

    let byName = try await index.search(query: "lovelace", limit: 10, offset: 0)
    #expect(byName.total == 1, "a contact awaiting a re-index fell out of search entirely")
  }
}

//  Enablement: which contacts this server will serve.
//
//  Specified as: every contact enabled by default, switchable per contact and in bulk by the
//  Account column, and a disabled contact is not served ANYWHERE — including the lookups that
//  turn a phone number into a name, so a message from a disabled contact shows the raw address.
//
//  The property that decides the storage is the last one here: a choice has to survive a
//  re-index. `reindexAll` deletes every address-book row and re-inserts it, so enablement kept
//  on `contact` would revert the first time the address book was re-read.

@Suite("Contact enablement")
struct ContactEnablementTests {

  private func seed(_ index: ContactIndex) async throws {
    try await index.upsert([
      ContactRecord(
        id: "ab:1", source: .macOS, firstName: "Ada", lastName: "Lovelace",
        phoneNumbers: ["+1 (555) 010-1234"],
        account: ContactAccount(kind: .other, name: "iCloud")),
      ContactRecord(
        id: "ab:2", source: .macOS, firstName: "Grace", lastName: "Hopper",
        phoneNumbers: ["+1 (555) 010-9999"],
        account: ContactAccount(kind: .other, name: "Google")),
      ContactRecord(id: "local:3", source: .local, firstName: "Alan", lastName: "Turing"),
    ])
  }

  @Test("Every contact is enabled by default")
  func enabledByDefault() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    #expect(try await index.count() == 3)
    #expect(try await index.search(query: "", limit: 10, offset: 0).total == 3)
  }

  @Test("A disabled contact leaves the served list and the count")
  func disabledLeavesTheServedList() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    try await index.setEnabled(false, ids: ["ab:1"])

    #expect(try await index.count() == 2)
    let page = try await index.search(query: "", limit: 10, offset: 0)
    #expect(page.total == 2)
    #expect(!page.contacts.map(\.id).contains("ab:1"))
  }

  /// THE strong half of the decision: disabling reaches name resolution, so a message from
  /// this person shows a raw number rather than a name.
  @Test("A disabled contact stops resolving a phone number to a name")
  func disabledStopsResolving() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Ada")

    try await index.setEnabled(false, ids: ["ab:1"])
    #expect(
      try await index.findContact(address: "+15550101234") == nil,
      "a switched-off contact was still turning a handle into a name")
  }

  /// The lookup cache holds records by address, so without invalidation the setting appears
  /// not to work for as long as the entry lives.
  @Test("Switching a contact off is not hidden by the lookup cache")
  func cacheDoesNotOutliveTheSetting() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    // Warm it.
    _ = try await index.findContact(address: "+15550101234")
    try await index.setEnabled(false, ids: ["ab:1"])
    #expect(try await index.findContact(address: "+15550101234") == nil)

    // And back, which the cache must not hide either.
    try await index.setEnabled(true, ids: ["ab:1"])
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Ada")
  }

  @Test("The app can still see what it has switched off")
  func theAppSeesDisabledContacts() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    try await index.setEnabled(false, ids: ["ab:1"])

    let page = try await index.search(query: "", limit: 10, offset: 0, includeDisabled: true)
    #expect(page.total == 3, "a switch you cannot see is a switch you cannot undo")
    #expect(page.disabledIDs == ["ab:1"])
  }

  @Test("Bulk switching by Account label covers exactly that account")
  func bulkByAccount() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let changed = try await index.setEnabled(false, accountLabel: "Google")
    #expect(changed == 1)

    let page = try await index.search(query: "", limit: 10, offset: 0)
    #expect(page.contacts.map(\.id).sorted() == ["ab:1", "local:3"])
  }

  /// A contact with no account falls back to its source in that column, so the bulk control
  /// can reach it under the label the table shows.
  ///
  /// REGRESSION on the spelling. The fallback was `CAST(c.source AS TEXT)`, the stored enum's
  /// raw value, so a contact with no account grouped under "2" while the row beside it read
  /// "Local": the bulk menu offered a group nobody could see named. Measured on a real index —
  /// Google 249, iCloud 338, and "2" with three in it.
  @Test("Contacts with no account group under the label the table shows")
  func bulkBySourceFallback() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let labels = try await index.accountLabels()
    #expect(labels.contains { $0.label == "iCloud" && $0.count == 1 })
    #expect(labels.contains { $0.label == "Google" && $0.count == 1 })
    #expect(
      labels.contains { $0.label == ContactSource.local.label && $0.count == 1 },
      "grouped under something other than what the Account column displays: \(labels)")
    #expect(!labels.contains { Int($0.label) != nil }, "a raw enum value reached the menu")
  }

  /// The bulk action has to cover the same rows the label names, fallback included.
  @Test("Bulk switching by the source fallback label works")
  func bulkBySourceLabel() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    let changed = try await index.setEnabled(false, accountLabel: ContactSource.local.label)
    #expect(changed == 1)
    #expect(try await index.count() == 2)
  }

  /// THE storage decision. A re-index deletes and re-inserts every address-book contact; the
  /// choice has to outlive that, or it silently reverts the first time the address book is
  /// re-read.
  @Test("A choice survives a full re-index")
  func choiceSurvivesReindex() async throws {
    let (index, _) = try searchIndex()
    try await seed(index)
    try await index.setEnabled(false, ids: ["ab:1"])

    // Exactly what `reindexAll` does.
    try await index.removeAll(source: .macOS)
    try await seed(index)

    #expect(
      try await index.count() == 2,
      "the re-index re-enabled a contact the user had switched off")
    let page = try await index.search(query: "", limit: 10, offset: 0, includeDisabled: true)
    #expect(page.disabledIDs == ["ab:1"])
  }
}

//  The COST of reading a page, which is the half a behavioural test cannot see.
//
//  `hydrate(row:db:)` reads one contact's addresses, which is right for a single lookup and
//  wrong for a list: a page of a hundred cost a hundred and one queries, and the count grew
//  with the page rather than staying put. The batch reads them in one `IN` clause.
//
//  Asserted by COUNTING STATEMENTS through GRDB's trace hook rather than by timing anything: a
//  correct-but-N+1 implementation passes every test in the suite above, and a timing assertion
//  on a machine under test load is a coin toss.

@Suite("Contact page cost")
struct ContactPageCostTests {

  @Test("Reading a page does not cost a query per contact")
  func pageIsNotNPlusOne() async throws {
    let counter = StatementCounter()
    // Tracing is installed when the connection is prepared, which is the only hook that sees
    // every statement including the ones inside `database.read`.
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      db.trace { counter.record(String(describing: $0)) }
    }
    let queue = try DatabaseQueue(configuration: configuration)
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)

    try await index.upsert(
      (0..<60).map { number in
        ContactRecord(
          id: "c\(number)", source: .macOS, firstName: "Person\(number)",
          phoneNumbers: [String(format: "+1555%07d", number)],
          emailAddresses: ["person\(number)@example.com"])
      })

    // Migrating and seeding are not what is being measured.
    counter.reset()

    let page = try await index.search(query: "", limit: 50, offset: 0)
    let count = counter.selects

    #expect(page.contacts.count == 50)
    // The addresses are what the extra queries were FOR, so this has to prove they still
    // arrive: a batch that returned none would be very fast indeed.
    #expect(page.contacts.allSatisfy { !$0.phoneNumbers.isEmpty })
    #expect(page.contacts.allSatisfy { !$0.emailAddresses.isEmpty })
    // Count, page, addresses. A per-contact read would be fifty more than this.
    #expect(count <= 5, "reading a page of 50 issued \(count) selects; it is N+1 again")
  }
}

/// A counter the trace hook can write to from wherever GRDB calls it.
private final class StatementCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var selects: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    count = 0
  }

  func record(_ statement: String) {
    guard statement.uppercased().contains("SELECT") else { return }
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }
}

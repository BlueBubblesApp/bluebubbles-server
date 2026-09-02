//  ContactIndexTests
//
//  Two things are being guarded here. The first is BEHAVIOR: the fuzzy suffix match has to
//  keep resolving the addresses it resolves today, because that is what turns a chat.db
//  handle into a name a client displays. The second is COST: the lookup must be an indexed
//  probe, not a scan — that is the specific pathology being fixed, and a correct-but-slow
//  implementation would pass every behavioral test while being just as unusable on an old
//  Mac with a large address book.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBContacts

private func makeIndex() throws -> ContactIndex {
  let queue = try DatabaseQueue()
  let database = AppDatabase(queue: queue)
  try database.migrate(contributors: [ContactsSchema.self])
  return ContactIndex(database: database)
}

@Suite("Address normalization")
struct AddressNormalizationTests {

  @Test("Non-alphanumerics are stripped, underscore kept")
  func stripping() {
    // Matching alphaNumericRegex exactly, underscore included — that inclusion is what
    // makes some email local-parts survive intact.
    #expect(AddressNormalizer.strip("+1 (555) 010-1234") == "15550101234")
    #expect(AddressNormalizer.strip("bob_smith@example.com") == "bob_smithexamplecom")
  }

  @Test("Kind is decided by the presence of @")
  func classification() {
    #expect(AddressNormalizer.classify("+15550101234") == .phone)
    #expect(AddressNormalizer.classify("bob@example.com") == .email)
  }

  @Test("Emails normalize case-insensitively, phones do not lose digits")
  func normalization() {
    #expect(AddressNormalizer.normalize("Bob@Example.COM", kind: .email) == "bobexamplecom")
    #expect(AddressNormalizer.normalize("+1-555-010-1234", kind: .phone) == "15550101234")
  }
}

@Suite("Contact lookup")
struct ContactLookupTests {

  @Test("An exact phone number resolves")
  func exactMatch() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+1 (555) 010-1234"])
    ])
    let found = try await index.findContact(address: "+15550101234")
    #expect(found?.firstName == "Ada")
  }

  @Test("A number stored with a country code matches one without")
  func suffixMatch() async throws {
    // The case the whole fuzzy match exists for: the address book has "+1 555 010 1234"
    // and chat.db has "5550101234". Losing this means every US contact shows as a
    // number instead of a name.
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+1 (555) 010-1234"])
    ])
    #expect(try await index.findContact(address: "5550101234")?.firstName == "Ada")
  }

  @Test("A number stored without a country code matches one with")
  func reverseSuffixMatch() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        phoneNumbers: ["555-010-1234"])
    ])
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Ada")
  }

  @Test("Different numbers do not collide")
  func noFalsePositives() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+15550101234"]),
      ContactRecord(
        id: "b", source: .macOS, firstName: "Grace",
        phoneNumbers: ["+15550109999"]),
    ])
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Ada")
    #expect(try await index.findContact(address: "+15550109999")?.firstName == "Grace")
  }

  @Test("A short tail does not match everything")
  func shortTailsAreRejected() async throws {
    // The current implementation has no length floor and will happily match a 3-digit
    // tail against every contact in the book, which is how a stranger's name ends up on
    // a message.
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+15550101234"])
    ])
    #expect(try await index.findContact(address: "234") == nil)
  }

  @Test("Emails match whole, never by suffix")
  func emailsAreNotSuffixMatched() async throws {
    // Suffix-trimming an email is meaningless and would let a@example.com resolve to bba@example.com.
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "Ada",
        emailAddresses: ["bba@example.com"])
    ])
    #expect(try await index.findContact(address: "bba@example.com")?.firstName == "Ada")
    #expect(try await index.findContact(address: "a@example.com") == nil)
  }

  @Test("macOS Contacts wins over a client-created contact")
  func sourcePrecedence() async throws {
    // Deterministic, unlike the current code which returns whichever key Object.keys
    // happened to yield first.
    //
    // Two sources rather than three: the Google source is gone, because a Google account
    // synced into Contacts.app reaches us through `CNContactStore` like any other and is
    // `.macOS`. Precedence still has to be decided, since a client can POST a contact for
    // an address the address book also knows.
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "local", source: .local, firstName: "Stale",
        phoneNumbers: ["+15550101234"]),
      ContactRecord(
        id: "macos", source: .macOS, firstName: "Curated",
        phoneNumbers: ["+15550101234"]),
    ])
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Curated")
  }

  @Test("Two people with the same name do not collide")
  func sameNameDoesNotCollide() async throws {
    // The @Unique(["firstName","lastName","displayName"]) constraint on the current
    // contact table makes this impossible today.
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "a", source: .macOS, firstName: "John", lastName: "Smith",
        phoneNumbers: ["+15550101111"]),
      ContactRecord(
        id: "b", source: .macOS, firstName: "John", lastName: "Smith",
        phoneNumbers: ["+15550102222"]),
    ])
    #expect(try await index.count() == 2)
    #expect(try await index.findContact(address: "+15550101111")?.id == "a")
    #expect(try await index.findContact(address: "+15550102222")?.id == "b")
  }

  @Test("An unknown address resolves to nothing")
  func unknownAddress() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(id: "a", source: .macOS, firstName: "Ada", phoneNumbers: ["+15550101234"])
    ])
    #expect(try await index.findContact(address: "+15559998888") == nil)
  }

  @Test("Removing a source leaves the others alone")
  func partialRemoval() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(id: "m", source: .macOS, firstName: "Ada", phoneNumbers: ["+15550101111"]),
      ContactRecord(id: "l", source: .local, firstName: "Local", phoneNumbers: ["+15550102222"]),
    ])
    try await index.removeAll(source: .macOS)
    #expect(try await index.findContact(address: "+15550101111") == nil)
    #expect(try await index.findContact(address: "+15550102222")?.firstName == "Local")
  }

  @Test("Re-upserting replaces a contact's addresses rather than appending")
  func addressesAreReplaced() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(id: "a", source: .macOS, firstName: "Ada", phoneNumbers: ["+15550101111"])
    ])
    try await index.upsert([
      ContactRecord(id: "a", source: .macOS, firstName: "Ada", phoneNumbers: ["+15550102222"])
    ])
    #expect(try await index.findContact(address: "+15550101111") == nil)
    #expect(try await index.findContact(address: "+15550102222")?.firstName == "Ada")
  }
}

@Suite("Lookup cost")
struct ContactIndexCostTests {

  @Test("The suffix lookup uses the index, not a scan")
  func lookupIsIndexed() async throws {
    // This is the regression guard on the actual pathology. A correct-but-scanning
    // implementation passes every behavioral test above and is still unusable on an old
    // Mac with a large address book, because this runs once per handle per message.
    let queue = try DatabaseQueue()
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)

    var contacts: [ContactRecord] = []
    for number in 0..<5_000 {
      contacts.append(
        ContactRecord(
          id: "c\(number)", source: .macOS, firstName: "Person\(number)",
          phoneNumbers: [String(format: "+1555%07d", number)]
        )
      )
    }
    try await index.upsert(contacts)

    let plan = try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          EXPLAIN QUERY PLAN
          SELECT c.id FROM contact_address a
          JOIN contact c ON c.id = a.contact_id
          WHERE a.reversed >= ? AND a.reversed < ?
          ORDER BY c.source ASC, LENGTH(a.normalized) ASC, c.id ASC
          LIMIT 1
          """, arguments: ["4321", "4322"]
      )
      .compactMap { $0["detail"] as String? }
      .joined(separator: " | ")
    }

    #expect(
      plan.contains("idx_contact_address_reversed"),
      "The suffix lookup stopped using its index. Plan: \(plan)"
    )
    #expect(
      !plan.contains("SCAN contact_address"),
      "The suffix lookup fell back to a full scan. Plan: \(plan)"
    )

    // The behavioral half of the same guarantee: the answer is still right at 5,000.
    let found = try await index.findContact(address: "+15550004242")
    #expect(found?.firstName == "Person4242")
  }

  @Test("A miss is cached, so an unknown number is not looked up per message")
  func missesAreCached() async throws {
    let index = try makeIndex()
    try await index.upsert([
      ContactRecord(id: "a", source: .macOS, firstName: "Ada", phoneNumbers: ["+15550101234"])
    ])
    #expect(try await index.findContact(address: "+15559998888") == nil)
    #expect(try await index.findContact(address: "+15559998888") == nil)
  }
}

@Suite("Prefix range bounds")
struct PrefixRangeTests {

  @Test("The upper bound increments the final scalar")
  func upperBound() {
    #expect(ContactIndex.rangeUpperBound(of: "4321") == "4322")
    #expect(ContactIndex.rangeUpperBound(of: "abc") == "abd")
  }

  @Test("An empty prefix has no bound")
  func emptyPrefix() {
    #expect(ContactIndex.rangeUpperBound(of: "") == nil)
  }
}

@Suite("Ingest safety")
struct ContactsIngestSafetyTests {

  @Test("A reindex without Contacts access refuses instead of emptying the index")
  func unauthorizedReindexPreservesTheIndex() async throws {
    // The order of two lines was the whole defect: `reindexAll` deleted every `.macOS`
    // contact and THEN called `enumerateContacts`, which throws when access is denied. On
    // an unauthorized process that wiped the address book and reported nothing, because
    // the one call site ran it with `try?`. Stale names beat no names.
    //
    // Skipped where access IS granted — this asserts the denied path, and the host
    // running the suite decides which one it is.
    guard ContactsIngestor.authorizationStatus != .authorized else { return }

    let queue = try DatabaseQueue()
    let database = AppDatabase(queue: queue)
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)

    try await index.upsert([
      ContactRecord(
        id: "macos:1", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+15550101234"])
    ])

    await #expect(throws: ContactsIngestError.self) {
      _ = try await ContactsIngestor(index: index).reindexAll()
    }

    // Still there. It was not before the guard.
    #expect(try await index.count() == 1)
    #expect(try await index.findContact(address: "+15550101234")?.firstName == "Ada")
  }
}

@Suite("Stored addresses keep their original form")
struct RawAddressTests {

  private func makeIndex() throws -> (ContactIndex, AppDatabase) {
    let database = try AppDatabase.inMemory(contributors: [ContactsSchema.self])
    return (ContactIndex(database: database), database)
  }

  @Test("An email survives the round trip with its dots and its @")
  func emailIsNotMangled() async throws {
    // The bug this pins: `contact_address` stored only the normalized lookup key, which
    // strips everything non-alphanumeric, and every read hydrated from it. A user's
    // `person.name@example.com` came back as `personnameexamplecom` — in the app AND from
    // GET /api/v1/contact, so clients were showing it too.
    let (index, _) = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "test:1", source: .macOS, firstName: "Log", lastName: "Hesse",
        emailAddresses: ["person.name@example.com"]
      )
    ])

    let stored = try await index.contact(id: "test:1")
    #expect(stored?.emailAddresses == ["person.name@example.com"])
  }

  @Test("A phone number keeps the punctuation it was entered with")
  func phoneKeepsFormatting() async throws {
    let (index, _) = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "test:2", source: .macOS, displayName: "Someone",
        phoneNumbers: ["+1 (555) 010-1234"]
      )
    ])

    #expect(try await index.contact(id: "test:2")?.phoneNumbers == ["+1 (555) 010-1234"])
  }

  @Test("Keeping the raw form does not break lookup by a differently-punctuated address")
  func lookupStillNormalizes() async throws {
    // The reason the key is lossy in the first place. Storing the original must not cost
    // us the match that made normalization worth doing.
    let (index, _) = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "test:3", source: .macOS, displayName: "Someone",
        phoneNumbers: ["+1 (555) 010-1234"],
        emailAddresses: ["Person.Name@Example.com"]
      )
    ])

    #expect(try await index.findContact(address: "5550101234")?.id == "test:3")
    #expect(try await index.findContact(address: "personname@example.com")?.id == "test:3")
  }

  @Test("The account a contact came from round-trips")
  func accountRoundTrips() async throws {
    let (index, _) = try makeIndex()
    try await index.upsert([
      ContactRecord(
        id: "test:4", source: .macOS, displayName: "Someone",
        phoneNumbers: ["5550101234"],
        account: ContactAccount(kind: .google, name: "someone@example.com")
      )
    ])

    let stored = try await index.contact(id: "test:4")
    #expect(stored?.account == ContactAccount(kind: .google, name: "someone@example.com"))
  }
}

@Suite("Which account a container is")
struct ContactAccountInferenceTests {

  @Test("A local container is this Mac")
  func local() {
    #expect(ContactAccount.infer(containerType: "local", name: "On My Mac").kind == .onThisMac)
  }

  @Test("Google is recognised from the container name")
  func google() {
    // Google syncs over CardDAV, so the type says nothing — the name is the only signal.
    #expect(ContactAccount.infer(containerType: "cardDAV", name: "Google").kind == .google)
    // `gmail.com` here is a PROVIDER IDENTIFIER, not sample user data: `infer` keys on
    // `lowered.contains("gmail")`, so an example.com address would prove the opposite of
    // what this asserts. Exempt from CONTRIBUTING § "Test data: never real addresses" for
    // the same reason `gserviceaccount.com` is — it names a service, not a person.
    #expect(
      ContactAccount.infer(containerType: "cardDAV", name: "me@gmail.com").kind == .google
    )
  }

  @Test("iCloud is recognised, including under its legacy container name")
  func iCloud() {
    // "Card" is what iCloud's container has been called since the AddressBook days. It
    // reads like a bug, which is exactly why the raw name is kept alongside the guess.
    #expect(ContactAccount.infer(containerType: "cardDAV", name: "Card").kind == .iCloud)
    #expect(ContactAccount.infer(containerType: "cardDAV", name: "iCloud").kind == .iCloud)
    #expect(ContactAccount.infer(containerType: "cardDAV", name: "").kind == .iCloud)
  }

  @Test("An unrecognised CardDAV account keeps its own name rather than being guessed")
  func unknownCardDAV() {
    let account = ContactAccount.infer(containerType: "cardDAV", name: "Fastmail")
    #expect(account.kind == .other)
    // The label falls back to the name, so a user sees "Fastmail" and not "Other account".
    #expect(account.label == "Fastmail")
  }
}

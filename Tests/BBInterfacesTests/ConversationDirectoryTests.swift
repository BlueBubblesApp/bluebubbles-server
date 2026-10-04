//  ConversationDirectoryTests
//  How a conversation is named, searched and read for every picker in the app.
//
//  The fallback chain is the whole point and the part a screenshot cannot prove: a name when
//  the address book has one, the formatted number when it does not, an email as it is, and
//  the raw address kept for search either way. A server with no contact access takes the
//  same path as an address book that simply misses an address, and every row must still
//  read as a formatted address.
//
//  The second half is which rows keep their address beside the name: a one-to-one chat does,
//  a group does not, and a chat whose name IS its address must not show it twice.
//
//  NO REAL ADDRESSES: `+1555…` and the fixture's `+12025550143` are reserved ranges, and
//  `example.com` is RFC 2606. See CONTRIBUTING.md.

import BBContacts
import BBIMessage
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Conversation directory")
struct ConversationDirectoryTests {

  private typealias Conversation = ConversationDirectory.Conversation
  private typealias Participant = ConversationDirectory.Participant

  private let aaron = Participant(
    address: "+15550101234", service: "iMessage", name: "Aaron Example", nameSource: .contacts)
  private let unnamed = Participant(address: "+15550105678", service: "iMessage")

  private func direct(_ participant: Participant, displayName: String? = nil) -> Conversation {
    Conversation(
      guid: "iMessage;-;\(participant.address)", displayName: displayName, isGroup: false,
      participants: [participant])
  }

  // MARK: - Naming

  @Test("A known address is titled with its contact name, address alongside")
  func namesAKnownAddress() {
    let row = direct(aaron)
    #expect(row.title == "Aaron Example")
    #expect(row.subtitle == "+1 (555) 010-1234")
  }

  @Test("An unknown address keeps its formatted number, shown once")
  func fallsBackToTheFormattedNumber() {
    let row = direct(unnamed)
    #expect(row.title == "+1 (555) 010-5678")
    #expect(row.subtitle == nil)
  }

  @Test("An email is shown as it is")
  func emailsAreNotFormatted() {
    let row = direct(Participant(address: "someone@example.com"))
    #expect(row.title == "someone@example.com")
    #expect(row.subtitle == nil)
  }

  @Test("A group names the participants it can and leaves the rest as numbers")
  func namesGroupsPerParticipant() {
    let row = Conversation(guid: "iMessage;+;chat1", isGroup: true, participants: [aaron, unnamed])
    #expect(row.title == "Aaron Example, +1 (555) 010-5678")
    #expect(row.subtitle == nil)
  }

  @Test("A named group keeps its own name; a named direct chat still shows its address")
  func displayNameWins() {
    let group = Conversation(
      guid: "iMessage;+;chat1", displayName: "Weekend Plans", isGroup: true,
      participants: [aaron, unnamed])
    #expect(group.title == "Weekend Plans")
    #expect(group.subtitle == nil)
    let work = direct(aaron, displayName: "Work")
    #expect(work.title == "Work")
    #expect(work.subtitle == "+1 (555) 010-1234")
  }

  @Test("An empty display name is no name, and a chat with nobody falls back to its GUID")
  func emptyFallbacks() {
    let blank = direct(unnamed, displayName: "")
    #expect(blank.displayName == nil)
    #expect(blank.title == "+1 (555) 010-5678")
    let nobody = Conversation(guid: "iMessage;+;orphan", isGroup: true, participants: [])
    #expect(nobody.title == "iMessage;+;orphan")
  }

  @Test("A business handle reads as Business")
  func businessHandle() {
    #expect(Participant(address: "urn:biz:1234").displayName == "Business")
  }

  // MARK: - Searching

  @Test("A row is found by name, raw address, formatted address and GUID")
  func searchMatchesEverySpelling() {
    let rows = [direct(aaron), direct(unnamed)]
    let first = [rows[0].id]
    #expect(ConversationDirectory.filter(rows, query: "aaron").map(\.id) == first)
    #expect(ConversationDirectory.filter(rows, query: "EXAMPLE").map(\.id) == first)
    #expect(ConversationDirectory.filter(rows, query: "+15550101234").map(\.id) == first)
    #expect(ConversationDirectory.filter(rows, query: "(555) 010-1234").map(\.id) == first)
    #expect(ConversationDirectory.filter(rows, query: "555 0101234").map(\.id) == first)
    #expect(ConversationDirectory.filter(rows, query: "iMessage;-;").count == 2)
    #expect(ConversationDirectory.filter(rows, query: "Kyle").isEmpty)
  }

  @Test("A whitespace-only query is no query, and a query is trimmed")
  func queriesAreTrimmed() {
    let rows = [direct(aaron), direct(unnamed)]
    #expect(ConversationDirectory.filter(rows, query: " \t ").count == 2)
    #expect(ConversationDirectory.filter(rows, query: "  5678  ").map(\.id) == [rows[1].id])
  }

  // MARK: - Reading

  /// A directory over a copy of the sonoma fixture: a direct chat with `+12025550143`, a
  /// group "Weekend Plans" of that number and `person@example.com`, and an SMS chat with
  /// `+12025550144`. The writer is returned to be HELD: releasing it removes the WAL
  /// sidecars and the read-only connection with them (see `ChatFixtureCopy`).
  private struct Fixture {
    let directory: ConversationDirectory
    let path: String
    let writer: DatabaseQueue
    func tearDown() { ChatFixtureCopy.remove(path) }
  }

  private func fixture(contactsEnabled: Bool) async throws -> Fixture {
    let (path, writer) = try ChatFixtureCopy.make()
    let database = try ReadOnlyDatabase(path: path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 14)
    let appDatabase = AppDatabase(queue: try DatabaseQueue())
    try appDatabase.migrate(contributors: [ContactsSchema.self])
    let contacts = ContactIndex(database: appDatabase)
    try await contacts.upsert([
      ContactRecord(
        id: "local:aaron", source: .local, firstName: "Aaron", lastName: "Example",
        phoneNumbers: ["+12025550143"])
    ])
    let directory = ConversationDirectory(
      repository: MessageRepository(database: database, profile: profile),
      contacts: contacts, contactsEnabled: { contactsEnabled })
    return Fixture(directory: directory, path: path, writer: writer)
  }

  @Test("The list is every chat, newest first, named from contacts")
  func listsAndNames() async throws {
    let fixture = try await fixture(contactsEnabled: true)
    defer { fixture.tearDown() }
    let rows = try await fixture.directory.list()
    #expect(rows.count == 3)
    let dates = rows.compactMap(\.lastMessageDate)
    #expect(dates == dates.sorted(by: >), "newest first")
    let group = try #require(rows.first { $0.title == "Weekend Plans" })
    #expect(group.isGroup)
    #expect(group.participants.map(\.displayName).contains("Aaron Example"))
    #expect(group.participants.map(\.displayName).contains("person@example.com"))
    let direct = try #require(rows.first { $0.guid.hasSuffix("+12025550143") })
    #expect(direct.title == "Aaron Example")
    #expect(direct.subtitle == "+1 (202) 555-0143")
    #expect(direct.participants.first?.nameSource == .contacts)
  }

  @Test("A caller's names win over contacts, and Contacts off leaves addresses")
  func nameSources() async throws {
    let enabled = try await fixture(contactsEnabled: true)
    defer { enabled.tearDown() }
    let overridden = try await enabled.directory.conversation(
      guid: "iMessage;-;+12025550143", names: ["+12025550143": "From The Phone"])
    #expect(overridden.title == "From The Phone")
    #expect(overridden.participants.first?.nameSource == .client)
    // Matched across the service-prefix spellings, as every chat lookup is.
    let migrated = try await enabled.directory.conversation(guid: "any;-;+12025550143")
    #expect(migrated.title == "Aaron Example")

    let disabled = try await fixture(contactsEnabled: false)
    defer { disabled.tearDown() }
    let plain = try await disabled.directory.list()
    #expect(plain.allSatisfy { $0.participants.allSatisfy { $0.nameSource == .none } })
  }

  @Test("An unknown GUID is a not-found")
  func unknownConversation() async throws {
    let fixture = try await fixture(contactsEnabled: true)
    defer { fixture.tearDown() }
    await #expect(throws: InterfaceError.self) {
      _ = try await fixture.directory.conversation(guid: "iMessage;+;chat-no-such")
    }
  }
}

//  ContactBatchTests
//  A batch write commits what it can and names, by position, what it could not.
//
//  The batch routes echo each failed entry back as it was sent, which only the caller holds:
//  the interface takes typed drafts, so a failure carries the entry's INDEX and the handler
//  echoes its own copy. A failure reported against the wrong index tells a client the wrong
//  contact was refused.
//
//  A create of a contact already stored merges into it: a client that syncs its address book
//  re-sends every contact on every sync, and a row per send adds a full copy of the address
//  book each time.

import BBContacts
import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Contact batch writes")
struct ContactBatchTests {

  private func interface() throws -> ContactInterface {
    try fixture().interface
  }

  private func fixture() throws -> (interface: ContactInterface, index: ContactIndex) {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)
    return (ContactInterface(index: index), index)
  }

  @Test("A create batch commits the good entries and names the bad one by position")
  func createReportsByIndex() async throws {
    let outcome = try await interface().create(batch: [
      .init(firstName: "Ada", phoneNumbers: ["+12025550143"]),
      .init(firstName: "Nobody"),
      .init(displayName: "Grace", emailAddresses: ["someone@example.com"]),
    ])
    #expect(outcome.succeeded.map(\.firstName) == ["Ada", nil])
    #expect(outcome.failures.map(\.index) == [1])
    #expect(
      outcome.failures.first?.message
        == "a contact needs at least one phone number or email address")
  }

  @Test("An update entry with no id fails alone, at its own position")
  func updateWithoutAnID() async throws {
    let outcome = try await interface().update(batch: [
      (id: nil, draft: .init(firstName: "Ada", phoneNumbers: ["+12025550143"]))
    ])
    #expect(outcome.succeeded.isEmpty)
    #expect(outcome.failures.map(\.index) == [0])
    #expect(outcome.failures.first?.message == "`id` is required")
  }

  @Test("A v1 draft keeps a phone number sent as a JSON number, and both address spellings")
  func v1DraftReadsEveryAddressShape() throws {
    let body = try JSONValue.parse(
      Data(
        #"{"firstName":"Ada","phoneNumbers":["+12025550143",{"address":"+12025550144"},12025550145],"emails":["someone@example.com"]}"#
          .utf8))
    let draft = ContactInterface.ContactDraft(v1: body)
    #expect(draft.phoneNumbers == ["+12025550143", "+12025550144", "12025550145"])
    #expect(draft.emailAddresses == ["someone@example.com"])
  }

  @Test("Posting the same address book twice stores each contact once")
  func resentBatchDoesNotDuplicate() async throws {
    let (interface, index) = try fixture()
    let book: [ContactInterface.ContactDraft] = [
      .init(firstName: "Ada", lastName: "", displayName: "Ada", phoneNumbers: ["+12025550143"]),
      .init(displayName: "Grace", emailAddresses: ["someone@example.com"]),
    ]
    let first = try await interface.create(batch: book)
    let second = try await interface.create(batch: book)

    #expect(try await index.count() == 2)
    // The second sync answers with the contacts it matched, under their stored ids.
    #expect(second.succeeded.map(\.id) == first.succeeded.map(\.id))
    #expect(second.failures.isEmpty)
  }

  @Test("A re-sent contact gains a new address and keeps the ones it had")
  func resentContactGainsAddresses() async throws {
    let (interface, index) = try fixture()
    let created = try await interface.create(
      .init(firstName: "Ada", phoneNumbers: ["+12025550143"]))
    // An absent last name and an empty one are the same name.
    let merged = try await interface.create(
      .init(
        firstName: "Ada", lastName: "",
        phoneNumbers: ["+1 (202) 555-0143", "+12025550144"], emailAddresses: ["someone@example.com"]
      ))

    #expect(merged.id == created.id)
    #expect(merged.phoneNumbers == ["+12025550143", "+12025550144"])
    #expect(merged.emailAddresses == ["someone@example.com"])
    #expect(try await index.count() == 1)
    #expect(try await index.findContact(address: "+12025550144")?.id == created.id)
  }

  @Test("Copies written before the merge collapse into the oldest on the next create")
  func existingCopiesCollapse() async throws {
    let (interface, index) = try fixture()
    try await index.upsert([
      ContactRecord(id: "copy-a", source: .local, firstName: "Ada", phoneNumbers: ["+12025550143"])
    ])
    try await index.upsert([
      ContactRecord(id: "copy-b", source: .local, firstName: "Ada", phoneNumbers: ["+12025550144"])
    ])
    try await index.setEnabled(false, ids: ["copy-b"])

    let merged = try await interface.create(.init(firstName: "Ada", phoneNumbers: ["+12025550145"]))

    #expect(merged.id == "copy-a")
    #expect(merged.phoneNumbers == ["+12025550143", "+12025550144", "+12025550145"])
    #expect(try await index.contact(id: "copy-b") == nil)
    #expect(try await index.count() == 1)
    // The copy's switch went with it: a row written under that id later starts served.
    try await index.upsert([
      ContactRecord(id: "copy-b", source: .local, firstName: "Bea", phoneNumbers: ["+12025550146"])
    ])
    let page = try await index.search(
      query: "", order: .name, ascending: true, limit: 10, offset: 0, includeDisabled: true)
    #expect(page.total == 2)
    #expect(page.disabledIDs.isEmpty)
  }

  @Test("A matching external id merges even when the name changed")
  func externalIDIsIdentity() async throws {
    let (interface, index) = try fixture()
    let created = try await interface.create(
      .init(firstName: "Ada", externalID: "ext-1", phoneNumbers: ["+12025550143"]))
    let renamed = try await interface.create(
      .init(firstName: "Grace", externalID: "ext-1", phoneNumbers: ["+12025550143"]))

    #expect(renamed.id == created.id)
    #expect(renamed.firstName == "Grace")
    #expect(try await index.count() == 1)
  }

  @Test("A create never merges into an address-book contact with the same name")
  func addressBookIsNotACandidate() async throws {
    let (interface, index) = try fixture()
    try await index.upsert([
      ContactRecord(
        id: ContactIndex.addressBookPrefix + "card-1", source: .macOS, firstName: "Ada",
        phoneNumbers: ["+12025550143"])
    ])
    let created = try await interface.create(
      .init(firstName: "Ada", phoneNumbers: ["+12025550144"]))

    #expect(created.source == .local)
    #expect(created.id != ContactIndex.addressBookPrefix + "card-1")
    #expect(try await index.count() == 2)
  }
}

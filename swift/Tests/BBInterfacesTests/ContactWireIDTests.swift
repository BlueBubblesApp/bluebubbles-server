//  ContactWireIDTests
//  Updating and deleting by the id a client was GIVEN, not the one we store.
//
//  An address-book record is keyed `macos:<identifier>` in storage and serialised bare, so the
//  two spellings differ — and every write route takes the client's spelling. `ContactIndex`
//  resolves either, but that is only half of it: an update that FOUND the row by the bare id
//  and then wrote under it would create a SECOND row rather than update the first, and a
//  delete would report success and remove nothing. Both are silent.

import BBContacts
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Contact writes by wire id")
struct ContactWireIDTests {

  private static let identifier = "882BB792-0AD7-4F41-9C99-2E5F2BE8AEDF"
  private static var storedID: String { ContactIndex.addressBookPrefix + identifier }

  private func interface() async throws -> (ContactInterface, ContactIndex) {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)
    try await index.upsert([
      ContactRecord(
        id: Self.storedID, source: .macOS, firstName: "Sam",
        phoneNumbers: ["+12025550143"])
    ])
    return (ContactInterface(index: index), index)
  }

  @Test("An update by the bare id rewrites the stored row, not a second one")
  func updateResolvesToTheStoredID() async throws {
    let (contacts, index) = try await interface()

    let updated = try await contacts.update(
      id: Self.identifier,
      body: .object([
        "firstName": .string("Samantha"),
        "phoneNumbers": .array([.string("+12025550143")]),
      ])
    )

    #expect(updated.id == Self.storedID, "wrote under the wire id, creating a duplicate")
    #expect(updated.firstName == "Samantha")
    #expect(try await index.contact(id: Self.identifier)?.firstName == "Samantha")
    // And exactly one row, which is the half a passing update would still get wrong.
    #expect(try await index.count() == 1)
  }

  @Test("A delete by the bare id removes the stored row")
  func deleteResolvesToTheStoredID() async throws {
    let (contacts, index) = try await interface()
    try await contacts.delete(id: Self.identifier)
    #expect(try await index.contact(id: Self.identifier) == nil)
    #expect(try await index.count() == 0)
  }
}

//  ContactBatchTests
//  A batch write commits what it can and names, by position, what it could not.
//
//  The batch routes echo each failed entry back as it was sent, which only the caller holds:
//  the interface takes typed drafts, so a failure carries the entry's INDEX and the handler
//  echoes its own copy. A failure reported against the wrong index tells a client the wrong
//  contact was refused.

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
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    return ContactInterface(index: ContactIndex(database: database))
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
}

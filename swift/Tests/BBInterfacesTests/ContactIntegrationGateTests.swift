//  ContactIntegrationGateTests
//  Switching the Contacts integration off means contacts are neither used nor served.
//
//  It used to mean only that the address book stopped being RE-INDEXED: every read went
//  straight to the stored index, so the app still listed contacts and `GET /api/v1/contact`
//  still answered with them. The gate is on the interface rather than in the handlers so
//  that "off" means the same thing to the API, to the app, and to anything added later.

import BBContacts
import BBPersistence
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Contacts integration gate")
struct ContactIntegrationGateTests {

  private func makeIndex() throws -> ContactIndex {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    return ContactIndex(database: database)
  }

  private func interface(enabled: Bool) throws -> ContactInterface {
    ContactInterface(index: try makeIndex(), isEnabled: { enabled })
  }

  @Test("Reading refuses while the integration is off")
  func readingRefuses() async throws {
    let contacts = try interface(enabled: false)

    await #expect(throws: InterfaceError.self) { try await contacts.list() }
    await #expect(throws: InterfaceError.self) { try await contacts.count() }
    await #expect(throws: InterfaceError.self) { try await contacts.find(addresses: ["a@b.c"]) }
    await #expect(throws: InterfaceError.self) { try await contacts.contact(id: "x") }
    await #expect(throws: InterfaceError.self) {
      try await contacts.displayNames(for: ["a@b.c"])
    }
  }

  @Test("Writing refuses too")
  func writingRefuses() async throws {
    // A contact POSTed into an index nothing serves is a write with no reader.
    let contacts = try interface(enabled: false)
    await #expect(throws: InterfaceError.self) {
      try await contacts.create(.object(["firstName": .string("Ada")]))
    }
    await #expect(throws: InterfaceError.self) { try await contacts.delete(id: "x") }
    await #expect(throws: InterfaceError.self) { try await contacts.refresh() }
  }

  @Test("The refusal names the integration and the switch")
  func refusalIsActionable() async throws {
    let contacts = try interface(enabled: false)
    do {
      _ = try await contacts.list()
      Issue.record("expected a refusal")
    } catch let error as InterfaceError {
      guard case .serviceDisabled(_, let service) = error else {
        Issue.record("expected .serviceDisabled, got \(error)")
        return
      }
      #expect(service == "app.bluebubbles.core.contacts")
      // The sentence has to say what to do, because it is what a client shows a person.
      #expect(error.body.contains("Integrations"))
    }
  }

  @Test("Switched on, the same reads work: the index was never touched")
  func enabledStillReads() async throws {
    // The point of gating rather than clearing: turning it back on serves what was already
    // indexed, with no re-index needed.
    let contacts = try interface(enabled: true)
    #expect(try await contacts.count() == 0)
    #expect(try await contacts.list().isEmpty)
  }

  @Test("The gate is asked per call, not captured once")
  func gateIsLive() async throws {
    // `AppContext` caches the interfaces it builds, so a flag read at construction would
    // answer with whatever the setting said when the server started.
    let enabled = LiveFlag()
    let contacts = ContactInterface(index: try makeIndex(), isEnabled: { await enabled.value })

    #expect(try await contacts.count() == 0)
    await enabled.set(false)
    await #expect(throws: InterfaceError.self) { try await contacts.count() }
    await enabled.set(true)
    #expect(try await contacts.count() == 0)
  }
}

/// A setting somebody flips while the server is running.
private actor LiveFlag {
  private(set) var value = true
  func set(_ newValue: Bool) { value = newValue }
}

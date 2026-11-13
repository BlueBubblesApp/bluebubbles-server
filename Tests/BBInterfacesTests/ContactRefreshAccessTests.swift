//  ContactRefreshAccessTests
//  `contact/refresh` is a way to reach the Contacts dialog, on a server with no window as much
//  as on one with.
//
//  Moving the prompt out of `ContactsIngestor` took it away from this route as well as from the
//  service's start. This route is somebody asking for the address book, so it asks; and on a
//  headless server it is the one way to be asked again after the start has passed.

import BBContacts
import BBCore
import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBInterfaces

@Suite("Contact refresh asks for access")
struct ContactRefreshAccessTests {

  private func makeIndex() throws -> ContactIndex {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    return ContactIndex(database: database)
  }

  /// Skipped where access IS granted: `reindexAll` would then read the address book of
  /// whoever is running the suite, and this asserts the refusal.
  @Test("It asks before it reads, and answers with the refusal if nobody grants it")
  func asksFirst() async throws {
    guard ContactsIngestor.authorizationStatus != .authorized else { return }
    let index = try makeIndex()
    let asked = Locked(0)
    let contacts = ContactInterface(
      index: index, ingestor: ContactsIngestor(index: index),
      askForAccess: { asked.withLock { $0 += 1 } })

    await #expect(throws: ContactsIngestError.self) { _ = try await contacts.refresh() }
    #expect(asked.withLock { $0 } == 1)
  }

  /// No ingestor means the service is not running, and a dialog would be for nothing.
  @Test("With the service not running it does not ask")
  func noIngestorNoPrompt() async throws {
    let asked = Locked(0)
    let contacts = ContactInterface(
      index: try makeIndex(), askForAccess: { asked.withLock { $0 += 1 } })

    await #expect(throws: InterfaceError.self) { _ = try await contacts.refresh() }
    #expect(asked.withLock { $0 } == 0)
  }

  @Test("With the integration switched off it does not ask")
  func switchedOffNoPrompt() async throws {
    let index = try makeIndex()
    let asked = Locked(0)
    let contacts = ContactInterface(
      index: index, ingestor: ContactsIngestor(index: index), isEnabled: { false },
      askForAccess: { asked.withLock { $0 += 1 } })

    await #expect(throws: InterfaceError.self) { _ = try await contacts.refresh() }
    #expect(asked.withLock { $0 } == 0)
  }

  /// `.notDetermined` used to read "Contacts access is notDetermined", a Swift case at a person,
  /// sending them to a pane with no row in it for an app macOS has never asked about.
  @Test("Refusing for want of asking says so in words")
  func refusalReads() {
    let unasked = ContactsIngestError.notAuthorized(.notDetermined).description
    #expect(unasked.contains("has not been asked for"))
    #expect(!unasked.contains("notDetermined"))
  }
}

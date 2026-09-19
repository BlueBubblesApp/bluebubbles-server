//  PushDeviceStreamTests
//  The push device table can be followed, whichever path writes it.
//
//  The registered-devices page reads this table and has to see it change without asking:
//  a client re-registers on every launch and after every FCM token rotation, and the sender
//  PRUNES a row the moment FCM reports its token is no longer registered — a device
//  disappearing is how somebody learns their phone stopped being reachable. None of those
//  writes is an event on the bus, and one of them does not come from the app at all.
//
//  So this pins the three that matter: the first element is the table as it stands, a
//  registration reaches a follower, and a removal does too.

import BBPersistence
import Testing

@testable import BBAppStore
@testable import BBInterfaces
@testable import BBMedia

@Suite("Push device stream")
struct PushDeviceStreamTests {

  /// Not a real token; see CONTRIBUTING.md. A registration token is an address.
  private let token = "test-registration-token-0001"

  @Test("The first element is the current table; a registration and a removal each yield")
  func writesReachFollowers() async throws {
    let database = try AppDatabase.inMemory(contributors: [InterfacesSchema.self])
    let repository = DeviceRepository(database: database)
    var iterator = repository.changes().makeAsyncIterator()

    let initial = try await iterator.next()
    #expect(initial?.isEmpty == true)

    try await repository.register(name: "A phone", identifier: token)
    let afterRegister = try await iterator.next()
    #expect(afterRegister?.map(\.name) == ["A phone"])

    let id = try #require(try await repository.all().first?.id)
    #expect(try await repository.remove(id: id))
    let afterRemoval = try await iterator.next()
    #expect(afterRemoval?.isEmpty == true)
  }

  /// The case the page's Remove button depends on being honest about. A concurrent prune
  /// can take the row first, and a `remove` that answered "done" either way would have the
  /// screen report a success for something it did not do.
  @Test("Removing a row that is already gone says so rather than reporting success")
  func removingAGoneRowIsFalse() async throws {
    let database = try AppDatabase.inMemory(contributors: [InterfacesSchema.self])
    let repository = DeviceRepository(database: database)

    try await repository.register(name: "A phone", identifier: token)
    let id = try #require(try await repository.all().first?.id)

    #expect(try await repository.remove(id: id))
    #expect(try await repository.remove(id: id) == false)
  }

  /// `all()` is ordered by registration, not by activity, so the list a screen draws does
  /// not reshuffle under the reader every time a client checks in.
  @Test("The list keeps registration order when a device re-registers")
  func orderIsStable() async throws {
    let database = try AppDatabase.inMemory(contributors: [InterfacesSchema.self])
    let repository = DeviceRepository(database: database)

    try await repository.register(name: "First", identifier: "\(token)-a")
    try await repository.register(name: "Second", identifier: "\(token)-b")
    // The first one checks in again, which moves its `last_active_at` and nothing else.
    try await repository.register(name: "First", identifier: "\(token)-a")

    #expect(try await repository.all().map(\.name) == ["First", "Second"])
  }
}

//  FindMyWireShapeTests
//  The frozen `friends` payload, by type, and where a read of it comes from.
//
//  The parity diff never saw `findmy/friends` with a friend in it: both recorded fixtures
//  answer `data: []`, because nobody was sharing with the recording Mac. So the shape of one
//  entry is pinned here from the Objective-C helper that produced it, and the one divergence
//  between that helper and the reference's TypeScript type is the reason this file exists:
//  `is_locating_in_progress` is a JSON boolean on the wire, whatever the reference's
//  TypeScript type says, and the Flutter client refuses the whole list when it is a number.
//
//  `title` is the second thing pinned here. It names the PERSON: the client shows it as the
//  friend's name whenever it cannot resolve the handle to a chat of its own, so a place in it
//  lists that person as a city with a blank avatar.
//
//  The read's behaviour when the helper REFUSES is in `FindMyFailureTests`, with the walks.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBContacts
import BBCore
import BBPersistence
import BBPrivateAPIContract
import BBSystem
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("FindMy friends wire shape")
struct FindMyWireShapeTests {

  private static let handle = "someone@example.com"

  private static let located = FindMyFriend(
    handle: handle, isSharingWithMe: true, isFollowingMyLocation: false,
    location: FindMyLocation(
      latitude: 51.5, longitude: -0.12,
      shortAddress: "Westminster", longAddress: "1 Example Street, London", label: "Work",
      lastUpdated: Date(timeIntervalSince1970: 1_700_000_000.25),
      isLocatingInProgress: true, status: .live))

  private static let legacyKeys: Set<String> = [
    "handle", "coordinates", "long_address", "short_address", "subtitle", "title",
    "last_updated", "is_locating_in_progress", "status",
  ]

  // MARK: - Shape

  @Test("Every legacy field is present, with the type the Objective-C helper sent")
  func legacyTypes() throws {
    let payload = FindMyInterface.legacyPayload(Self.located)
    guard case .object(let fields) = payload else {
      Issue.record("a friend serialized as \(payload), not an object")
      return
    }
    #expect(Set(fields.keys) == Self.legacyKeys)
    #expect(payload["handle"] == .string(Self.handle))
    #expect(payload["coordinates"] == .array([.double(51.5), .double(-0.12)]))
    #expect(payload["short_address"] == .string("Westminster"))
    #expect(payload["long_address"] == .string("1 Example Street, London"))
    #expect(payload["title"] == .string(Self.handle))
    #expect(payload["subtitle"] == .string("Work"))
    #expect(payload["last_updated"] == .int(1_700_000_000_250))
    // A boolean, not 0 / 1: `[NSNumber numberWithBool:]` through `NSJSONSerialization`.
    #expect(payload["is_locating_in_progress"] == .bool(true))
    #expect(payload["status"] == .string("live"))
  }

  @Test("A friend with no fix is still listed, at the origin, with the flags the helper sent")
  func unlocated() {
    let friend = FindMyFriend(
      handle: Self.handle, isSharingWithMe: true, isFollowingMyLocation: false)
    let payload = FindMyInterface.legacyPayload(friend)
    #expect(payload["coordinates"] == .array([.double(0), .double(0)]))
    #expect(payload["is_locating_in_progress"] == .bool(false))
    #expect(payload["last_updated"] == .int(0))
    #expect(payload["status"] == .string("shallow"))
    #expect(payload["long_address"] == .null)
    #expect(payload["title"] == .string(Self.handle))
    #expect(payload["subtitle"] == .null)
  }

  @Test("`status` is one of the three spellings clients switch on, whatever IMCore said")
  func statusSpellings() {
    for status in FindMyLocationStatus.allCases {
      let friend = FindMyFriend(
        handle: Self.handle, isSharingWithMe: true, isFollowingMyLocation: false,
        location: FindMyLocation(status: status))
      let spelled = FindMyInterface.legacyPayload(friend)["status"]?.stringValue
      #expect(
        ["legacy", "live", "shallow"].contains(spelled ?? ""),
        "\(status) was spelled \(spelled ?? "nil")")
    }
  }

  // MARK: - Only people

  /// A made-up place, as `coarseAddressLabel` reports one: a city and a region.
  private static let place = "Springfield, ZZ"

  /// Someone whose position carries a coarse place label and no other address: the shape
  /// every modern-backend friend has, and the one that was listed as a city.
  private static let labelledByPlace = FindMyFriend(
    handle: "+12025550143", isSharingWithMe: true, isFollowingMyLocation: false,
    location: FindMyLocation(
      latitude: 40.1, longitude: -88.2, label: place,
      lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), status: .shallow))

  /// An entry naming nobody, carrying the same place.
  private static let nobody = FindMyFriend(
    handle: "", isSharingWithMe: true, isFollowingMyLocation: false,
    location: labelledByPlace.location)

  @Test("`title` is the person's handle, never the place, in the list and in the event")
  func titleNamesThePerson() {
    let listed = FindMyInterface.legacyPayload(Self.labelledByPlace)
    let announced = PrivateAPIGatedService.findMyEvent(for: Self.labelledByPlace).event

    for payload in [listed, announced.fullPayload, announced.notificationPayload] {
      #expect(payload["title"] == .string("+12025550143"))
      #expect(payload["handle"] == .string("+12025550143"))
      // The place is still sent, where the client reads a place from.
      #expect(payload["subtitle"] == .string(Self.place))
      #expect(payload["title"] != .string(Self.place))
    }
  }

  @Test("An entry naming nobody never reaches the friends list or an event")
  func nobodyIsDropped() async {
    let helper = StubFindMyAccess(friends: [Self.nobody, Self.labelledByPlace])
    let interface = FindMyInterface(runtime: FindMyRuntime(), privateAPI: helper)

    // `record` answering nil is what keeps the event pump from announcing it.
    #expect(await interface.record(Self.nobody) == nil)

    let friends = await interface.friends()
    #expect(friends == [Self.labelledByPlace])
    let titles = friends.map { FindMyInterface.legacyPayload($0)["title"] }
    #expect(!titles.contains(.string(Self.place)))
    #expect(!titles.contains(.string("")))
  }

  // MARK: - Names

  /// An address book holding one made-up person, reachable at `labelledByPlace`'s number.
  private static func addressBook(enabled: Bool = true) async throws -> ContactInterface {
    let database = AppDatabase(queue: try DatabaseQueue())
    try database.migrate(contributors: [ContactsSchema.self])
    let index = ContactIndex(database: database)
    try await index.upsert([
      ContactRecord(
        id: "fixture-ada", source: .macOS, firstName: "Ada", lastName: "Example",
        phoneNumbers: ["+1 (202) 555-0143"])
    ])
    return ContactInterface(index: index, isEnabled: { enabled })
  }

  @Test("A friend in the address book is titled by name; one who is not keeps the handle")
  func titleIsTheContactName() async throws {
    let helper = StubFindMyAccess(friends: [Self.located, Self.labelledByPlace])
    let interface = FindMyInterface(
      runtime: FindMyRuntime(), privateAPI: helper, contacts: try await Self.addressBook())

    let listed = await interface.legacyPayloads(await interface.friends())
    let titles = Dictionary(
      uniqueKeysWithValues: listed.compactMap { payload -> (String, JSONValue)? in
        guard let handle = payload["handle"]?.stringValue else { return nil }
        return (handle, payload["title"] ?? .null)
      })
    #expect(titles["+12025550143"] == .string("Ada Example"))
    #expect(titles[Self.handle] == .string(Self.handle))

    // The event goes through the same lookup, and `handle` is untouched by it.
    let name = await interface.contactName(for: Self.labelledByPlace.handle)
    #expect(name == "Ada Example")
    #expect(await interface.contactName(for: Self.handle) == nil)
    let announced = PrivateAPIGatedService.findMyEvent(for: Self.labelledByPlace, name: name)
      .event.fullPayload
    #expect(announced["title"] == .string("Ada Example"))
    #expect(announced["handle"] == .string("+12025550143"))
    #expect(announced["subtitle"] == .string(Self.place))
  }

  @Test("With the Contacts integration off, every friend is titled by handle")
  func noNamesWhileContactsAreOff() async throws {
    let interface = FindMyInterface(
      runtime: FindMyRuntime(), privateAPI: nil,
      contacts: try await Self.addressBook(enabled: false))

    #expect(await interface.contactName(for: Self.labelledByPlace.handle) == nil)
    let payload = await interface.legacyPayloads([Self.labelledByPlace])
    #expect(payload.first?["title"] == .string("+12025550143"))
  }

  // MARK: - Reading

  @Test("A read is seeded from the helper's own cache, with no refresh")
  func readSeedsFromHelper() async {
    let helper = StubFindMyAccess(friends: [Self.located])
    let interface = FindMyInterface(runtime: FindMyRuntime(), privateAPI: helper)

    let friends = await interface.friends()

    #expect(friends == [Self.located])
    #expect(helper.reads == 1)
  }

  @Test("A pushed position is recorded once, and the repeat is not an event")
  func recordedOnce() async {
    let interface = FindMyInterface(runtime: FindMyRuntime(), privateAPI: nil)

    let first = await interface.record(Self.located)
    let again = await interface.record(Self.located)

    #expect(first == Self.located)
    #expect(again == nil)
    let friends = await interface.friends()
    #expect(friends == [Self.located])
  }

  @Test("Without a helper the read is the cache alone")
  func readWithoutHelper() async {
    let interface = FindMyInterface(runtime: FindMyRuntime(), privateAPI: nil)
    let friends = await interface.friends()
    #expect(friends.isEmpty)
  }
}

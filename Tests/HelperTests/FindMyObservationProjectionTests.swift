//  FindMyObservationProjectionTests
//  A FindMy notification's object is reduced to the address it names, or dropped.
//
//  IMCore posts the three FindMy notifications with "the handle" as the object and nothing
//  documents which handle class that is: `IMFindMyHandle` and `FMLHandle` answer
//  `identifier`, `IMHandle` answers `id`. The friend is then looked up by that address, so
//  the projection is the one piece of `FindMyBridge+Observation` with a seam a test can hold.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BlueBubblesHelper

/// An `IMFindMyHandle` stand-in.
@objc final class StandInFindMyHandle: NSObject {
  @objc let identifier: String
  init(identifier: String) { self.identifier = identifier }
}

/// An `IMHandle` stand-in, which spells the address `id`.
@objc final class StandInIMHandle: NSObject {
  @objc let id: String
  init(id: String) { self.id = id }
}

@Suite("FindMy notification projection")
@MainActor
struct FindMyObservationProjectionTests {

  @Test("A FindMy handle names its address through `identifier`")
  func findMyHandle() {
    #expect(
      FindMyBridge.postedIdentifier(StandInFindMyHandle(identifier: "someone@example.com"))
        == "someone@example.com")
  }

  @Test("An IMHandle names its address through `id`")
  func imHandle() {
    #expect(FindMyBridge.postedIdentifier(StandInIMHandle(id: "+12025550143")) == "+12025550143")
  }

  @Test("Nothing, an empty address, or an object that is not a handle is dropped")
  func dropped() {
    #expect(FindMyBridge.postedIdentifier(nil) == nil)
    #expect(FindMyBridge.postedIdentifier(StandInFindMyHandle(identifier: "")) == nil)
    #expect(FindMyBridge.postedIdentifier(NSObject()) == nil)
  }

  @Test("All three notifications that can change a friend's entry are observed")
  func threeNotifications() {
    #expect(
      Set(FindMyBridge.locationNotifications.map(\.rawValue)) == [
        "__kIMFMFSessionLocationReceivedNotification",
        "__kIMFMFSessionHandleLocationRefreshedNotification",
        "__kIMFMFSessionRelationshipStatusDidChangeNotification",
      ])
  }
}

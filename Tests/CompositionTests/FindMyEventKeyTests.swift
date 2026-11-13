//  FindMyEventKeyTests
//  A pushed FindMy position is announced as the reference's `FindMyLocationItem`, keyed by
//  its `handle`.
//
//  The bus coalesces per key. With no key every device shared one bucket, so a burst of N
//  positions reached clients as two; the reference emits every item of a batch.
//  `EventBusTests` covers the bus; this pins the key the service hands it, and the SHAPE: the
//  event body is the same frozen item the friends route lists, because the Flutter client
//  parses both with one `FindMyFriend.fromJson`.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBEvents
import BBInterfaces
import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("FindMy event keys")
struct FindMyEventKeyTests {

  private static let friend = FindMyFriend(
    handle: "someone@example.com", isSharingWithMe: true, isFollowingMyLocation: false,
    location: FindMyLocation(
      latitude: 51.5, longitude: -0.12, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
      isLocatingInProgress: false, status: .live))

  @Test("A FindMy position is keyed by its friend's handle")
  func keyedByHandle() {
    let mapped = PrivateAPIGatedService.findMyEvent(for: Self.friend)
    #expect(mapped.event.name == .newFindMyLocation)
    #expect(mapped.rateLimitKey == "someone@example.com")
  }

  @Test("The event body is the frozen friends item, not the contract's shape")
  func bodyIsTheLegacyItem() {
    let mapped = PrivateAPIGatedService.findMyEvent(for: Self.friend)
    #expect(mapped.event.fullPayload == FindMyInterface.legacyPayload(Self.friend))
    #expect(mapped.event.fullPayload["coordinates"] == .array([.double(51.5), .double(-0.12)]))
    #expect(mapped.event.fullPayload["is_locating_in_progress"] == .bool(false))
    #expect(mapped.event.notificationPayload == mapped.event.fullPayload)
  }

  @Test("The static mapping leaves a pushed position to the pump, which merges first")
  func staticMappingDefersToThePump() {
    let mapped = PrivateAPIGatedService.serverEvent(
      for: .findMyLocationUpdated(friend: Self.friend))
    #expect(mapped == nil)
  }
}

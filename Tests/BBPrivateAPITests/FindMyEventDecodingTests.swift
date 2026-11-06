//  FindMyEventDecodingTests
//  A `new-findmy-location` frame decodes to the friend the helper read, through the same
//  codec as the `findmy-friends` reply.
//
//  The event used to be flattened to `[String: String]`, which turned `coordinates` into the
//  text `"[51.5,-0.12]"` and a boolean into `"false"`: nothing downstream could read it. It
//  now carries a `FindMyFriend`, so a pushed position and a requested one are the same type
//  by the time the server sees them.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBPrivateAPI

@Suite("FindMy event decoding")
struct FindMyEventDecodingTests {

  private static let friend = FindMyFriend(
    handle: "someone@example.com", isSharingWithMe: true, isFollowingMyLocation: true,
    location: FindMyLocation(
      latitude: 51.5, longitude: -0.12, horizontalAccuracy: 25, shortAddress: "Westminster",
      lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), isLocatingInProgress: true,
      status: .live))

  /// The frame as the socket delivers it: the helper's `WireObject`, serialised and read
  /// back as the decoder's `[String: WireJSON]`.
  private func fields(_ payload: WireObject) throws -> [String: WireJSON] {
    let data = try JSONSerialization.data(withJSONObject: payload.jsonObject)
    return try JSONDecoder().decode([String: WireJSON].self, from: data)
  }

  @Test("A pushed friend decodes to the friend the helper read")
  func roundTrips() throws {
    let event = HelperEventDecoder.decode(
      name: HelperEventName.newFindMyLocation.rawValue, payload: try fields(Self.friend.wire))
    guard case .findMyLocationUpdated(let decoded)? = event else {
      Issue.record("decoded as \(String(describing: event))")
      return
    }
    #expect(decoded == Self.friend)
  }

  @Test("A friend with no position still decodes, as a friend with no position")
  func unlocatedRoundTrips() throws {
    let unlocated = FindMyFriend(
      handle: "someone@example.com", isSharingWithMe: true, isFollowingMyLocation: false)
    let event = HelperEventDecoder.decode(
      name: HelperEventName.newFindMyLocation.rawValue, payload: try fields(unlocated.wire))
    guard case .findMyLocationUpdated(let decoded)? = event else {
      Issue.record("decoded as \(String(describing: event))")
      return
    }
    #expect(decoded == unlocated)
  }

  @Test("A frame naming nobody is dropped rather than cached under an empty handle")
  func noHandleIsDropped() throws {
    var payload = Self.friend.wire
    payload[.handle] = ""
    let event = HelperEventDecoder.decode(
      name: HelperEventName.newFindMyLocation.rawValue, payload: try fields(payload))
    #expect(event == nil)
  }
}

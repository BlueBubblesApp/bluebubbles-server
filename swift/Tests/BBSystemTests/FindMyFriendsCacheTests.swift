//  FindMyFriendsCacheTests
//  The merge rules, which are the whole of this type.
//
//  Storing a location is trivial; deciding whether an incoming one is an IMPROVEMENT is not,
//  and every rule here exists because taking the newest unconditionally produces a visible
//  bug — a pin that jumps to the Gulf of Guinea, a live fix overwritten by a coarse one
//  seconds later, or an event storm from positions that did not change.
//
//  NO REAL ADDRESSES — see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BBSystem

@Suite("FindMy friends cache")
struct FindMyFriendsCacheTests {

  private func friend(
    _ handle: String = "+15550000001",
    latitude: Double? = 37.3349,
    longitude: Double? = -122.009,
    status: FindMyLocationStatus = .live,
    updated: TimeInterval = 1_700_000_000,
    sharingWithMe: Bool = true,
    followingMe: Bool = false
  ) -> FindMyFriend {
    FindMyFriend(
      handle: handle,
      isSharingWithMe: sharingWithMe,
      isFollowingMyLocation: followingMe,
      location: FindMyLocation(
        latitude: latitude,
        longitude: longitude,
        lastUpdated: Date(timeIntervalSince1970: updated),
        status: status
      )
    )
  }

  @Test("The first sighting is always stored")
  func firstWins() async {
    let cache = FindMyFriendsCache()
    #expect(await cache.merge(friend()))
    #expect(await cache.all.count == 1)
  }

  @Test("A handle-less entry is refused")
  func emptyHandle() async {
    let cache = FindMyFriendsCache()
    #expect(await cache.merge(friend("")) == false)
    #expect(await cache.isEmpty)
  }

  /// Rule 1. `legacy` is a coarse push from the old mechanism; `live` was just measured.
  /// Letting the coarse one land makes a position that was accurate a second ago wrong.
  @Test("A legacy fix never displaces a live one")
  func legacyDoesNotBeatLive() async {
    let cache = FindMyFriendsCache()
    await cache.merge(friend(status: .live, updated: 1_700_000_000))

    let coarse = friend(latitude: 40, longitude: -70, status: .legacy, updated: 1_700_000_500)
    #expect(await cache.merge(coarse) == false)
    #expect(await cache.friend(handle: "+15550000001")?.location?.latitude == 37.3349)
  }

  /// And the other direction: a live fix always displaces a coarse one, even an older one,
  /// because precision beats recency when the coarse value may be hours stale anyway.
  @Test("A live fix displaces a legacy one")
  func liveBeatsLegacy() async {
    let cache = FindMyFriendsCache()
    await cache.merge(friend(status: .legacy, updated: 1_700_000_000))
    #expect(
      await cache.merge(
        friend(
          latitude: 40, longitude: -70, status: .live,
          updated: 1_700_000_500)))
    #expect(await cache.friend(handle: "+15550000001")?.location?.latitude == 40)
  }

  /// Rule 2. IMCore reports an unlocated friend at the origin rather than as nil, so
  /// `(0, 0)` is "no fix" and must not replace a real position.
  @Test("The origin does not displace a real position")
  func originIsNotAPosition() async {
    let cache = FindMyFriendsCache()
    await cache.merge(friend(status: .legacy, updated: 1_700_000_000))

    let nowhere = friend(latitude: 0, longitude: 0, status: .legacy, updated: 1_700_000_900)
    #expect(await cache.merge(nowhere) == false)
    #expect(await cache.friend(handle: "+15550000001")?.location?.latitude == 37.3349)
  }

  /// Rule 3. The boolean gates the event, so "nothing moved" has to answer false — or the
  /// server pushes an identical position to every client on every refresh.
  @Test("An identical update reports no change")
  func idempotent() async {
    let cache = FindMyFriendsCache()
    let position = friend()
    #expect(await cache.merge(position))
    #expect(await cache.merge(position) == false)
  }

  /// Rule 4. Updates arrive from more than one path and the transport does not order them.
  @Test("An older fix does not overwrite a newer one")
  func outOfOrder() async {
    let cache = FindMyFriendsCache()
    await cache.merge(friend(latitude: 37, updated: 1_700_000_500))

    #expect(await cache.merge(friend(latitude: 10, updated: 1_700_000_000)) == false)
    #expect(await cache.friend(handle: "+15550000001")?.location?.latitude == 37)
  }

  /// Someone who has just accepted a share has no fix yet. Refusing the update would leave
  /// them looking like a stranger until their first location arrives, which can be minutes.
  @Test("A relationship change lands even with no position")
  func relationshipOnlyUpdate() async {
    let cache = FindMyFriendsCache()
    await cache.merge(
      FindMyFriend(
        handle: "+15550000002", isSharingWithMe: false,
        isFollowingMyLocation: false)
    )
    #expect(
      await cache.merge(
        FindMyFriend(
          handle: "+15550000002", isSharingWithMe: true,
          isFollowingMyLocation: false)
      ))
    #expect(await cache.friend(handle: "+15550000002")?.isSharingWithMe == true)

    // ...but an identical relationship with no position still changes nothing.
    #expect(
      await cache.merge(
        FindMyFriend(
          handle: "+15550000002", isSharingWithMe: true,
          isFollowingMyLocation: false)
      ) == false)
  }

  @Test("A first position always lands on an entry that had none")
  func firstPositionForKnownFriend() async {
    let cache = FindMyFriendsCache()
    await cache.merge(
      FindMyFriend(
        handle: "+15550000003", isSharingWithMe: true,
        isFollowingMyLocation: false)
    )
    #expect(await cache.merge(friend("+15550000003")))
    #expect(await cache.friend(handle: "+15550000003")?.location != nil)
  }

  /// The batch form returns only what changed, because that is what decides which events
  /// go out — a forty-friend refresh where two people moved should emit two events.
  @Test("A batch reports only the entries that changed")
  func batchReportsChanges() async {
    let cache = FindMyFriendsCache()
    let first = friend("+15550000001", latitude: 37)
    let second = friend("+15550000002", latitude: 38)
    #expect(await cache.merge([first, second]).count == 2)

    let moved = friend("+15550000002", latitude: 39, updated: 1_700_001_000)
    #expect(await cache.merge([first, moved]).map(\.handle) == ["+15550000002"])
  }

  /// A dictionary's order does not survive a rehash, and a client diffing the list would
  /// see reorderings that never happened.
  @Test("The list is stably ordered")
  func stableOrder() async {
    let cache = FindMyFriendsCache()
    await cache.merge([friend("+15550000003"), friend("+15550000001"), friend("+15550000002")])
    #expect(
      await cache.all.map(\.handle)
        == ["+15550000001", "+15550000002", "+15550000003"])
  }
}

//  FindMyBridge+Observation
//  Location updates, pushed: the `new-findmy-location` event.
//
//  Rung 1 of the observation ladder. A refresh (`FindMyBridge.refreshAll`) only ASKS Apple;
//  the positions come back one device at a time, seconds to minutes later, and IMCore
//  announces each one by posting `__kIMFMFSessionLocationReceivedNotification` on the default
//  centre with the handle as its object and no userInfo (the FindMy notification table in
//  docs/headers/README.md). This file turns each announcement into one `new-findmy-location`
//  frame carrying the friend in the contract's codec, the same shape the `findmy-friends`
//  reply uses. The server merges it through `FindMyFriendsCache` and announces it to clients
//  only when the cache changed.
//
//  It replaces the `FMFSessionDataManager.setLocations:` swizzle the Objective-C helper
//  uses, which is dead on macOS 26 and later: that class is not loaded in Messages there,
//  so the shipping helper stops delivering locations with nothing in any log.
//
//  Three notifications, not one, because a position is not the only thing a client draws.
//  `…HandleLocationRefreshedNotification` fires when a targeted refresh lands, and
//  `…RelationshipStatusDidChangeNotification` when someone starts or stops sharing, which is
//  how a new friend appears before their first position. Each names a handle; the friend is
//  read fresh off the session either way, so the three collapse to one path.
//
//  MEASURED on macOS 27.0.1 (2026-11-02), against a live Messages.app: within a second of
//  the helper connecting, IMCore posted these notifications for every friend as its FindMy
//  session loaded, 15 frames for 6 friends, and the server decoded, merged and announced
//  each one. So the notifications fire, the object names a handle, and the frame decodes.
//  A refresh request in the same run produced no further frames inside two minutes; what
//  that run does not show is how long Apple takes to answer, which depends on the friend's
//  device.
//
//  Nothing here is logged with an address in it: the helper's log is public, and a count or
//  an event name is all a support log needs (`LogRedactionPolicyTests`).

import BBPrivateAPIContract
import Foundation
import HelperShared

extension FindMyBridge {

  /// The IMCore notifications after which a friend's entry may have changed.
  static let locationNotifications = [
    NSNotification.Name("__kIMFMFSessionLocationReceivedNotification"),
    NSNotification.Name("__kIMFMFSessionHandleLocationRefreshedNotification"),
    NSNotification.Name("__kIMFMFSessionRelationshipStatusDidChangeNotification"),
  ]

  /// Starts announcing location changes. Called once, from the helper's `onLaunch`, after
  /// `EventObservation.start` has given an emitted event somewhere to go.
  static func observeLocations() {
    for name in locationNotifications {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        notification in
        let posted = PostedHandle(object: notification.object as AnyObject?)
        MainActor.assumeIsolated { locationChanged(posted.object) }
      }
    }
    BlueBubblesHelper.log.info("Observing FindMy location notifications (rung 1)")
  }

  /// Announces the friend `object` names, with whatever position IMCore holds now.
  ///
  /// Looked up by identifier rather than used as posted: the relationship and targeted
  /// refresh notifications do not promise an `IMFindMyHandle`, and `handleWithIdentifier:`
  /// is how IMCore itself turns an address into one. An object naming no address is dropped,
  /// so a notification whose object is not what this expects costs the event, never the host.
  static func locationChanged(_ object: AnyObject?) {
    guard let identifier = postedIdentifier(object), let session = session() else { return }
    guard let findMyHandle = makeFindMyHandle(identifier) else { return }
    let friend = friend(identifier: identifier, findMyHandle: findMyHandle, session: session)
    EventObservation.emit(.newFindMyLocation, friend.wire)
  }

  /// The address a posted object names: an `IMFindMyHandle`'s or `FMLHandle`'s
  /// `identifier`, or an `IMHandle`'s `id`. Nil for anything else.
  static func postedIdentifier(_ object: AnyObject?) -> String? {
    guard let object,
      let accessor = IMCoreRuntime.firstResponding(object, among: ["identifier", "id"]),
      let value = ((try? IMCoreRuntime.string(object, accessor)) ?? nil),
      !value.isEmpty
    else { return nil }
    return value
  }
}

/// A notification's object, carried into the main actor.
///
/// Unchecked because an `IMFindMyHandle` is an Objective-C object IMCore owns. It does not
/// cross a thread: the observer runs on the main queue, and the main actor reads it there.
private struct PostedHandle: @unchecked Sendable {
  let object: AnyObject?
}

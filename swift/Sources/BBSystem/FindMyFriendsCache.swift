//  FindMyFriendsCache
//  The server's own record of where people are.
//
//  WHY THIS EXISTS AT ALL
//  Devices come off disk — the FindMy app writes `Devices.data` and reading it needs nothing
//  but Full Disk Access. **Friends do not.** There is no friends cache file; the previous
//  server keeps friends in memory, fed by the helper's refresh replies and by location
//  events as they arrive (`FindMyFriendsCache.ts`). An earlier pass here pointed the friends
//  route at `Items.data`, which is a different thing entirely — that file holds AirTags and
//  accessories, which the previous server folds into DEVICES. So `GET findmy/friends` was
//  answering with the wrong list, and on most Macs with an empty one.
//
//  WHY MERGING IS NOT "LAST WRITE WINS"
//  Updates arrive from several places at different qualities, out of order. A `legacy` fix is
//  a coarse position from the old mechanism; a `live` one was just measured. IMCore reports a
//  friend it cannot locate as being at the origin rather than as having no position. Take the
//  newest of those unconditionally and a live fix gets replaced by a stale coarse one seconds
//  later, and someone's pin jumps to the Gulf of Guinea and back.
//
//  The three rules below are the previous server's, preserved deliberately: clients have been
//  built against this behaviour, and "the pin stopped flickering" is not a fix anyone asked
//  for if it comes with positions that used to update and now do not.

import BBPrivateAPIContract
import Foundation

/// In-memory, keyed by handle, newest-good-wins.
///
/// An actor because updates arrive from the helper's reply path and, in time, from the event
/// stream — two tasks writing the same dictionary. It holds one entry per person the account
/// shares with, so there is no eviction policy: the bound is the size of someone's FindMy
/// friends list.
public actor FindMyFriendsCache {

  private var entries: [String: FindMyFriend] = [:]

  public init() {}

  /// Merges an update, and says whether it changed anything.
  ///
  /// The boolean is not decoration — it is what decides whether an event goes out. Emitting
  /// on every update rather than on every CHANGE is how a server ends up pushing forty
  /// identical positions a minute to every connected client.
  @discardableResult
  public func merge(_ friend: FindMyFriend) -> Bool {
    guard !friend.handle.isEmpty else { return false }

    guard let existing = entries[friend.handle] else {
      entries[friend.handle] = friend
      return true
    }
    guard shouldReplace(existing, with: friend) else { return false }
    entries[friend.handle] = friend
    return true
  }

  /// Merges a batch, returning only the entries that actually changed.
  @discardableResult
  public func merge(_ friends: [FindMyFriend]) -> [FindMyFriend] {
    friends.filter { merge($0) }
  }

  public var all: [FindMyFriend] {
    // Sorted by handle so two calls agree. A dictionary's order does not survive a
    // rehash, and a client diffing the list would see phantom reorderings.
    entries.values.sorted { $0.handle < $1.handle }
  }

  public func friend(handle: String) -> FindMyFriend? { entries[handle] }

  public var isEmpty: Bool { entries.isEmpty }

  /// Whether an incoming fix is an improvement on the one held.
  ///
  /// Transcribed from `FindMyFriendsCache.add` in the previous server, with its reasoning
  /// made explicit rather than left in the shape of the conditions.
  private func shouldReplace(_ existing: FindMyFriend, with incoming: FindMyFriend) -> Bool {
    guard let new = incoming.location else {
      // No position at all. Still worth storing when the RELATIONSHIP changed — someone
      // who just started sharing has no fix yet, and refusing the update would leave
      // them looking like a stranger until their first location arrives.
      return existing.isSharingWithMe != incoming.isSharingWithMe
        || existing.isFollowingMyLocation != incoming.isFollowingMyLocation
    }
    guard let old = existing.location else { return true }

    // 1. A coarse fix never displaces a precise one. `legacy` is the old FindMyFriends
    //    push; `live` and `shallow` both come from an actual locate.
    if new.status == .legacy && old.status != .legacy { return false }

    // 2. The origin is IMCore's way of saying "no fix", so it never displaces a real
    //    position. Restricted to the legacy-to-legacy case, matching the previous
    //    server: a live update reporting the origin is a genuine measurement failure and
    //    the client should see it.
    if old.status == .legacy, new.status == .legacy,
      old.hasCoordinates, !new.hasCoordinates
    {
      return false
    }

    // 3. Nothing moved and nothing aged. Storing it would be free; EMITTING it would not,
    //    and this answer is what gates the emit.
    if old.status == new.status,
      old.latitude == new.latitude, old.longitude == new.longitude,
      old.lastUpdated == new.lastUpdated
    {
      return false
    }

    // 4. Out of order. Updates arrive from more than one path and the transport does not
    //    order them, so an older fix overtaking a newer one is ordinary rather than
    //    exceptional.
    if let oldStamp = old.lastUpdated, let newStamp = new.lastUpdated,
      newStamp < oldStamp
    {
      return false
    }

    return true
  }
}

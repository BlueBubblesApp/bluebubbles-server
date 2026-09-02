//  FindMyBridge
//  FindMy against IMCore, from inside Messages.app.
//
//  WHY THIS IS REACHABLE AT ALL
//  It looks as though it should not be — FindMy has its own app and its own frameworks, which
//  Messages never loads. Two facts make it work anyway, and a header dump of an iOS 16 SDK
//  will tell you the opposite:
//
//    - `IMFMFSession` is an **IMCore** class. It is in Messages.app's address space from
//      launch, and `_initializeFindMySessionIfInAllowedProcess` gates on
//      `IMIsRunningInMessagesUIProcess()`, which Messages satisfies — so the session is live.
//    - The classes that really are absent on macOS 26 are the LEGACY ones —
//      `FMFSessionDataManager`, `FMFSession`, `FMFHandle`. Probing for those and concluding
//      "FindMy is unreachable" is a false negative, and the trap to avoid here. The modern
//      types (`FindMyLocateSession`, `FMLHandle`, `FMLLocation`) live in
//      `FindMyLocateObjCWrapper.framework`, which `IMFMFSession` dlopens itself.
//
//  Verified on macOS 26.5.2; headers in docs/headers/macos-26.5.2/.
//
//  NO VERSION FORK
//  The Objective-C helper branches on `majorVersion > 13` to pick between `FindMyLocateSession`
//  and `FMFSession`. That is not carried over, because IMCore now makes the same choice
//  itself off an internal feature flag: `findMyHandlesSharingLocationWithMe` reads
//  `isFindMyLocateSessionEnabled` and dispatches to whichever half is live, handing back
//  `IMFindMyHandle` either way. Preferring the `IMFMFSession` wrapper absorbs the fork
//  entirely, and it is the layer Messages itself calls.
//
//  Only the two operations the wrapper does NOT cover — a one-shot refresh with a completion,
//  and a friendship invite — reach past it to `fmlSession`, and each degrades to a clear
//  `unavailableOnThisOS` when the modern session is not the one running.
//
//  EVERY LOOKUP IS GUARDED. This runs in the user's Messages.app: an unrecognised selector
//  raises, and an uncaught Objective-C exception here calls `abort()` on their Messages. A
//  moved selector must produce a missing field, never a crash.

import BBPrivateAPIContract
import CoreLocation
import Foundation
import HelperShared
import ObjectiveC

/// FindMy reads and actions, in one place.
///
/// `@MainActor` for the same reason `IMCoreBridge` is: IMCore asserts the main queue with
/// `dispatch_assert_queue()`, which traps rather than raising, so no barrier can catch it.
@MainActor
enum FindMyBridge {

  // MARK: - Sessions

  /// The IMCore-side FindMy session, or nil on a system that has no such class.
  ///
  /// Nil is a real answer rather than an error: a Mac with FindMy removed by policy is a
  /// supported configuration, and callers turn this into `FindMyStatus.unavailable`.
  static func session() -> AnyObject? {
    try? IMCoreRuntime.sharedInstance(ofClass: "IMFMFSession")
  }

  /// `FindMyLocateSession`, when that is the half IMCore is running.
  ///
  /// Typed as `AnyObject` because the class is not linked — it arrives through a framework
  /// IMCore dlopens on demand, so there is nothing to import.
  static func locateSession(_ session: AnyObject) -> AnyObject? {
    guard let value = try? IMCoreRuntime.send(session, "fmlSession") else { return nil }
    return value
  }

  /// The legacy `FMFSession`, when THAT is the half running. Absent on macOS 26.
  static func legacySession(_ session: AnyObject) -> AnyObject? {
    guard let value = try? IMCoreRuntime.send(session, "session") else { return nil }
    return value
  }

  static func backend(_ session: AnyObject) -> FindMyBackend {
    if locateSession(session) != nil { return .findMyLocate }
    if legacySession(session) != nil { return .legacyFindMyFriends }
    return .none
  }

  // MARK: - Status

  /// Whether FindMy is usable, and why not when it is not.
  ///
  /// Never throws. This is the call a client makes to decide whether to show the feature at
  /// all, so it has to answer on a Mac where every part of FindMy is missing — an error
  /// there would be indistinguishable from a server fault.
  static func status() -> FindMyStatus {
    guard let session = session() else { return .unavailable }

    let backend = backend(session)
    // Each of these is a bare BOOL getter, read through a typed cast: through `perform`
    // the single returned byte would be read as a pointer, so NO becomes nil and YES
    // becomes an address that is not an object.
    let provisioned =
      (try? IMCoreRuntime.bool(session, "imIsProvisionedForLocationSharing"))
      ?? false
    let restricted = (try? IMCoreRuntime.bool(session, "restrictLocationSharing")) ?? false
    let disabled = (try? IMCoreRuntime.bool(session, "disableLocationSharing")) ?? false

    return FindMyStatus(
      // A session with no backend can answer nothing, so it is not "available" however
      // provisioned the account looks.
      isAvailable: backend != .none,
      isProvisioned: provisioned,
      isRestricted: restricted,
      isSharingDisabled: disabled,
      backend: backend,
      activeDevice: activeDevice(session)
    )
  }

  private static func activeDevice(_ session: AnyObject) -> FindMyDeviceSummary? {
    guard let device = try? IMCoreRuntime.send(session, "activeDevice") else { return nil }
    return FindMyDeviceSummary(
      name: (try? IMCoreRuntime.string(device, "deviceName")) ?? nil,
      isThisDevice: (try? IMCoreRuntime.bool(device, "isThisDevice")) ?? false
    )
  }

  // MARK: - Reading friends

  /// Everyone sharing with us or following us, with whatever position IMCore already holds.
  ///
  /// Caches only — nothing here reaches Apple, which is why it carries no rate limit.
  ///
  /// BOTH DIRECTIONS, and that takes two calls because IMCore only wraps one of them.
  /// `findMyHandlesSharingLocationWithMe` covers people whose position we can see;
  /// people who can see OURS and do not share back have no wrapper accessor at all and
  /// have to come off the modern session's own cache. Reading only the first list would
  /// silently omit them, and "who can see where I am" is the half a privacy-minded user
  /// most wants to check.
  static func friends() throws -> [FindMyFriend] {
    let session = try requireSession()

    // Returns IMFindMyHandle regardless of which backend is live: the wrapper reads
    // `isFindMyLocateSessionEnabled` and picks `cachedFriendsSharingLocationsWithMe` or
    // `getHandlesSharingLocationsWithMe` behind this one selector.
    let sharing = collection(
      try? IMCoreRuntime.send(session, "findMyHandlesSharingLocationWithMe")
    )

    // Ordered, and de-duplicated by identifier: someone can be in both lists, and a
    // person appearing twice in a friends list is a client-visible bug.
    var identifiers: [String] = []
    var seen = Set<String>()
    var handles: [String: AnyObject] = [:]

    for handle in sharing {
      guard let identifier = ((try? IMCoreRuntime.string(handle, "identifier")) ?? nil),
        !identifier.isEmpty, seen.insert(identifier).inserted
      else { continue }
      identifiers.append(identifier)
      handles[identifier] = handle
    }

    for identifier in followerIdentifiers(session) where seen.insert(identifier).inserted {
      identifiers.append(identifier)
    }

    return identifiers.compactMap { identifier in
      // A follower has no `IMFindMyHandle` to hand, so one is built the same way IMCore
      // builds them internally — `findMyHandlesForChat:` does exactly this.
      guard let handle = handles[identifier] ?? makeFindMyHandle(identifier) else {
        return nil
      }
      return friend(identifier: identifier, findMyHandle: handle, session: session)
    }
  }

  /// People following our location, off the modern session's cache.
  ///
  /// Empty on the legacy backend rather than an error: `FMFSession` has
  /// `getHandlesFollowingMyLocation`, but it answers with `FMFHandle` rather than
  /// `FMLFriend` and that whole family is absent on macOS 26, so there is nothing to test
  /// the code path against. Reporting an incomplete list beats failing the whole read.
  private static func followerIdentifiers(_ session: AnyObject) -> [String] {
    guard let locate = locateSession(session) else { return [] }
    let followers = collection(
      try? IMCoreRuntime.send(locate, "cachedFriendsFollowingMyLocation")
    )
    return followers.compactMap { entry in
      // `FMLFriend` wraps an `FMLHandle`; the identifier is one level down.
      guard let handle = try? IMCoreRuntime.send(entry, "handle") else { return nil }
      guard let identifier = ((try? IMCoreRuntime.string(handle, "identifier")) ?? nil),
        !identifier.isEmpty
      else { return nil }
      return identifier
    }
  }

  /// One person, addressed by the phone number or email FindMy knows them by.
  static func friend(handle identifier: String) throws -> FindMyFriend {
    let session = try requireSession()
    guard let findMyHandle = makeFindMyHandle(identifier) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "findMyFriend",
        requires: "IMFindMyHandle, which is not present on this macOS"
      )
    }
    return friend(identifier: identifier, findMyHandle: findMyHandle, session: session)
  }

  /// Assembles the contract's view of one person from IMCore's several.
  private static func friend(
    identifier: String,
    findMyHandle: AnyObject,
    session: AnyObject
  ) -> FindMyFriend {
    FindMyFriend(
      handle: identifier,
      isSharingWithMe: (try? IMCoreRuntime.bool(
        session, "findMyHandleIsSharingLocationWithMe:", with: findMyHandle)) ?? false,
      isFollowingMyLocation: (try? IMCoreRuntime.bool(
        session, "findMyHandleIsFollowingMyLocation:", with: findMyHandle)) ?? false,
      location: location(for: findMyHandle, session: session)
    )
  }

  /// `+[IMFindMyHandle handleWithIdentifier:]` — IMCore's own way of turning an address
  /// into a FindMy handle, and the same one `findMyHandlesForChat:` uses internally.
  private static func makeFindMyHandle(_ identifier: String) -> AnyObject? {
    guard let type = IMCoreRuntime.lookUpClass("IMFindMyHandle") else { return nil }
    return try? IMCoreRuntime.send(type as AnyObject, "handleWithIdentifier:", identifier)
  }

  /// `+[FMLHandle handleWithIdentifier:]`. Only the modern session takes these.
  private static func makeLocateHandle(_ identifier: String) -> AnyObject? {
    guard let type = IMCoreRuntime.lookUpClass("FMLHandle") else { return nil }
    return try? IMCoreRuntime.send(type as AnyObject, "handleWithIdentifier:", identifier)
  }

  // MARK: - Reading a location

  /// The position IMCore holds for a handle, normalised across both backends.
  ///
  /// `IMFindMyLocation` is a wrapper carrying an `FMLLocation`, an `FMFLocation`, or both.
  /// Reading whichever is present — rather than picking by OS version — is what keeps this
  /// working across the switch between them.
  private static func location(for findMyHandle: AnyObject, session: AnyObject) -> FindMyLocation? {
    guard
      let wrapper = try? IMCoreRuntime.send(
        session, "findMyLocationForFindMyHandle:", findMyHandle
      )
    else { return nil }

    // The wrapper's own reverse-geocoded one-liner, populated only when the refresh that
    // produced this asked for geocoding.
    let shortAddress = ((try? IMCoreRuntime.string(wrapper, "shortAddress")) ?? nil)
      .flatMap { $0.isEmpty ? nil : $0 }

    if let modern = try? IMCoreRuntime.send(wrapper, "fmlLocation") {
      return locateLocation(modern, shortAddress: shortAddress)
    }
    if let legacy = try? IMCoreRuntime.send(wrapper, "fmfLocation") {
      return legacyLocation(legacy, shortAddress: shortAddress)
    }
    return nil
  }

  /// An `FMLLocation` — the modern shape, all bare primitives.
  private static func locateLocation(
    _ location: AnyObject,
    shortAddress: String?
  ) -> FindMyLocation {
    let placemark = try? IMCoreRuntime.send(location, "address")

    return FindMyLocation(
      // Every one of these is a `double` getter and MUST go through the typed cast.
      // Through `perform` a latitude of 37.33 would be read as a pointer.
      latitude: try? IMCoreRuntime.double(location, "latitude"),
      longitude: try? IMCoreRuntime.double(location, "longitude"),
      horizontalAccuracy: try? IMCoreRuntime.double(location, "horizontalAccuracy"),
      altitude: try? IMCoreRuntime.double(location, "altitude"),
      shortAddress: shortAddress,
      longAddress: placemark.flatMap(formattedAddress),
      label: ((try? IMCoreRuntime.string(location, "coarseAddressLabel")) ?? nil)
        .flatMap { $0.isEmpty ? nil : $0 },
      lastUpdated: (try? IMCoreRuntime.double(location, "timestamp")).flatMap(date(fromRaw:)),
      // `FMLLocation` has no in-progress flag; only the legacy `FMFLocation` carries
      // one. Reported as false rather than invented.
      isLocatingInProgress: false,
      status: FindMyLocationStatus(
        locationTypeDescription: (try? IMCoreRuntime.string(
          location, "locationTypeDescription")) ?? nil
      )
    )
  }

  /// An `FMFLocation` — the legacy shape, where the position is a `CLLocation` and the
  /// timestamp an `NSDate`.
  private static func legacyLocation(
    _ location: AnyObject,
    shortAddress: String?
  ) -> FindMyLocation {
    // Read off the `CLLocation` rather than `FMFLocation.coordinate`. That property
    // returns a `CLLocationCoordinate2D` — a struct, which neither `perform` nor any of
    // the typed casts can carry. CoreLocation is public, so the object it hands back can
    // simply be cast and read normally.
    let fix = (try? IMCoreRuntime.send(location, "location")) as? CLLocation
    let timestamp = (try? IMCoreRuntime.send(location, "timestamp")) as? Date

    return FindMyLocation(
      latitude: fix?.coordinate.latitude,
      longitude: fix?.coordinate.longitude,
      horizontalAccuracy: fix?.horizontalAccuracy
        ?? (try? IMCoreRuntime.double(location, "horizontalAccuracy")),
      altitude: fix?.altitude,
      shortAddress: shortAddress
        ?? ((try? IMCoreRuntime.string(location, "shortAddress")) ?? nil),
      longAddress: (try? IMCoreRuntime.string(location, "longAddress")) ?? nil,
      label: (try? IMCoreRuntime.string(location, "label")) ?? nil,
      lastUpdated: timestamp,
      isLocatingInProgress: (try? IMCoreRuntime.bool(location, "isLocatingInProgress"))
        ?? false,
      status: FindMyLocationStatus(
        legacyLocationType: (try? IMCoreRuntime.integer(location, "locationType")) ?? 0
      )
    )
  }

  /// An `FMLPlaceMark` flattened to one line.
  ///
  /// `formattedAddressLines` is Apple's own locale-correct breakdown, so it is joined
  /// rather than reassembled from the individual fields — which would put the house number
  /// on the wrong side of the street name in most of the world.
  private static func formattedAddress(_ placemark: AnyObject) -> String? {
    if let lines = (try? IMCoreRuntime.send(placemark, "formattedAddressLines")) as? [String],
      !lines.isEmpty
    {
      return lines.joined(separator: ", ")
    }
    let street = ((try? IMCoreRuntime.string(placemark, "streetAddress")) ?? nil)
    return street.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// `FMLLocation.timestamp` is a bare double whose unit is not declared.
  ///
  /// FindMy's service speaks milliseconds and its on-disk caches store milliseconds, but
  /// the property is typed as a plain `double` with no name to say so — and Apple's other
  /// candidate for an undeclared double is `CFAbsoluteTime`, which counts from 2001.
  ///
  /// So the magnitude decides, and the three ranges do not overlap for any date this could
  /// plausibly be:
  ///
  ///   - past 1e11 — cannot be seconds since 1970 (that would be the year 5138), so it is
  ///     milliseconds
  ///   - below 1e9 — cannot be seconds since 1970 either (that would be before 2001, which
  ///     predates the service), so it is seconds since 2001
  ///   - between them — seconds since 1970, the ordinary reading
  ///
  /// Getting this wrong does not fail; it produces a plausible-looking timestamp off by a
  /// factor of a thousand or by thirty-one years, which surfaces as "last seen in 1970".
  /// Not private: this is a heuristic on an undeclared unit, which is exactly the kind of
  /// thing that should be pinned by a test rather than trusted.
  static func date(fromRaw raw: Double) -> Date? {
    guard raw > 0 else { return nil }
    if raw > 1e11 { return Date(timeIntervalSince1970: raw / 1000) }
    if raw < 1e9 { return Date(timeIntervalSinceReferenceDate: raw) }
    return Date(timeIntervalSince1970: raw)
  }

  // MARK: - Refreshing

  /// Asks Apple for a fresh fix on everyone, then reports what came back.
  ///
  /// The modern session offers a completion, so this genuinely waits for the fetch rather
  /// than returning the cache and hoping. The legacy session's `forceRefresh` has no
  /// completion at all — there it kicks the refresh and returns what is cached, which is
  /// the same thing the Objective-C helper does.
  static func refreshAll() async throws -> [FindMyFriend] {
    let session = try requireSession()
    // Only the people whose position we can actually get. The friends list now includes
    // followers — people who see US and do not share back — and asking Apple to locate
    // one of those is a request that cannot succeed, sent on every refresh.
    let identifiers = try friends().filter(\.isSharingWithMe).map(\.handle)

    if let locate = locateSession(session) {
      await refreshThroughLocateSession(locate, identifiers: identifiers)
    } else if let legacy = legacySession(session) {
      refreshThroughLegacySession(legacy)
    } else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "refreshFindMyFriends",
        requires: "a FindMy session; this Mac has none configured"
      )
    }

    return try friends()
  }

  /// Asks for a fresh fix on ONE person.
  ///
  /// Worth having as its own call rather than filtering the full refresh: the full one asks
  /// Apple for every friend at once, and a client showing a single conversation should not
  /// be the reason forty locate requests go out.
  static func refresh(handle identifier: String) async throws -> FindMyFriend {
    let session = try requireSession()

    guard let locate = locateSession(session) else {
      // The legacy session refreshes wholesale or not at all. Reported rather than
      // silently upgraded to a full refresh, which would defeat the point of asking
      // for one person.
      throw PrivateAPIError.unavailableOnThisOS(
        method: "refreshFindMyLocation",
        requires: "FindMyLocateSession; the legacy FindMy session refreshes all "
          + "friends at once and cannot target one"
      )
    }

    await refreshThroughLocateSession(locate, identifiers: [identifier])
    return try friend(handle: identifier)
  }

  private static func refreshThroughLocateSession(
    _ locate: AnyObject,
    identifiers: [String]
  ) async {
    let handles = identifiers.compactMap(makeLocateHandle)
    guard !handles.isEmpty else { return }

    await withCompletion { finish in
      let block: @convention(block) () -> Void = { finish() }
      try IMCoreRuntime.invoke(
        locate,
        "startRefreshingLocationForHandles:priority:isFromGroup:reverseGeocode:completion:",
        [
          handles,
          // The priority the Objective-C helper uses. IMCore treats it as an
          // ordering hint among queued locate requests, not as a rate.
          NSNumber(value: 1000),
          NSNumber(value: false),
          // Reverse geocoding is what populates the address fields. Without it a
          // client gets coordinates and nothing a person can read.
          NSNumber(value: true),
          // Passed as a bare object. `BBInvoke` promotes it to the heap off the
          // method's own `@?` declaration — see HelperObjC.
          unsafeBitCast(block, to: AnyObject.self),
        ]
      )
    }
  }

  /// The legacy path: re-seed the session's handle set, then force a fetch.
  ///
  /// Transcribed from the Objective-C helper (BlueBubblesHelper.m:1434). The remove/add
  /// pair is not decorative — `forceRefresh` fetches for the session's registered handles,
  /// and a session that has drifted refreshes the wrong set.
  private static func refreshThroughLegacySession(_ legacy: AnyObject) {
    if let handles = try? IMCoreRuntime.send(legacy, "getHandlesSharingLocationsWithMe") {
      if let existing = try? IMCoreRuntime.send(legacy, "handles") {
        _ = try? IMCoreRuntime.invoke(legacy, "removeHandles:", [existing])
      }
      _ = try? IMCoreRuntime.invoke(legacy, "addHandles:", [handles])
    }
    _ = try? IMCoreRuntime.invoke(legacy, "forceRefresh")
  }

  // MARK: - Friendship

  /// Asks someone to share their location with us.
  ///
  /// A FindMy friendship INVITE, which is the "ask" direction — it prompts them to share
  /// with us. Distinct from an offer, which shares ours with them; that is
  /// `startSharing(_:)` below and it is the one behind a feature flag.
  static func requestLocationShare(handle identifier: String) async throws {
    let session = try requireSession()
    guard let locate = locateSession(session) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "requestFindMyLocationShare",
        requires: "FindMyLocateSession, which this Mac is not running"
      )
    }
    guard let handle = makeLocateHandle(identifier) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "requestFindMyLocationShare",
        requires: "FMLHandle, which is not present on this macOS"
      )
    }

    await withCompletion { finish in
      // Declared as taking NOTHING, deliberately. IMCore's real block may pass an
      // error; a Swift block that declares fewer parameters than the caller passes is
      // safe on arm64 — the extra arguments sit unread in registers — whereas one that
      // declares MORE reads whatever was in those registers as an object. So the
      // outcome is not reported, and that is the honest trade: an invite that Apple
      // rejects looks like one that was sent.
      let block: @convention(block) () -> Void = { finish() }
      try IMCoreRuntime.invoke(
        locate,
        "sendFriendshipInviteToHandle:isFromGroup:completion:",
        [handle, NSNumber(value: false), unsafeBitCast(block, to: AnyObject.self)]
      )
    }
  }

  // MARK: - Sharing our location

  /// Starts sharing THIS MAC's location.
  ///
  /// Addressed by chat because IMCore is: `startSharingWithHandle:inChat:withDuration:` uses
  /// the chat to choose the alias the offer is sent from, and there is no chat-less form.
  static func startSharing(_ request: FindMyShareRequest) throws {
    let session = try requireSession()
    let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
    let duration = NSNumber(value: request.duration.imCoreValue)

    if let address = request.address {
      let handle = try requireIMHandle(address)
      try IMCoreRuntime.invoke(
        session, "startSharingWithHandle:inChat:withDuration:",
        [handle.object, chat.object, duration]
      )
    } else {
      try IMCoreRuntime.invoke(
        session, "startSharingWithChat:withDuration:", [chat.object, duration]
      )
    }
  }

  static func stopSharing(chat guid: ChatGUID, address: String?) throws {
    let session = try requireSession()
    let chat = try IMChatRegistry.requireChat(guid: guid.rawValue)

    if let address {
      let handle = try requireIMHandle(address)
      try IMCoreRuntime.invoke(
        session, "stopSharingWithHandle:inChat:", [handle.object, chat.object]
      )
    } else {
      try IMCoreRuntime.invoke(session, "stopSharingWithChat:", [chat.object])
    }
  }

  /// An `IMHandle`, which is what the sharing selectors take.
  ///
  /// Not an `IMFindMyHandle`: `startSharingWithHandle:inChat:withDuration:` calls
  /// `findMyHandle` on its argument, so it wants the IMCore handle and derives the FindMy
  /// one itself. Passing the FindMy handle would raise on an unrecognised selector.
  private static func requireIMHandle(_ address: String) throws -> IMHandle {
    guard let handle = try IMAccountController.handle(for: address) else {
      throw PrivateAPIErrorBridge.noSuchHandle(address)
    }
    return handle
  }

  // MARK: - Plumbing

  private static func requireSession() throws -> AnyObject {
    guard let session = session() else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "FindMy",
        requires: "IMFMFSession, which is not present on this macOS"
      )
    }
    return session
  }

  /// IMCore returns handle collections as `NSSet` in some places and `NSArray` in others.
  ///
  /// Normalised here rather than at each call site, because the difference is not stable:
  /// `findMyHandlesSharingLocationWithMe` builds a set today and the same selector returned
  /// an array in an earlier release. A cast that assumes one silently yields nothing when
  /// the other arrives — an empty friends list rather than an error.
  private static func collection(_ value: AnyObject?) -> [AnyObject] {
    guard let value else { return [] }
    if let array = value as? [AnyObject] { return array }
    if let set = value as? NSSet { return set.allObjects as [AnyObject] }
    if let set = value as? Set<AnyHashable> { return set.map { $0 as AnyObject } }
    return []
  }

  /// Runs an IMCore call that reports through a completion block, and waits for it.
  ///
  /// The call itself is made HERE, on the main actor, synchronously — not inside a child
  /// task. IMCore asserts the main queue with `dispatch_assert_queue()`, which traps rather
  /// than raising, so starting the call anywhere else would take Messages.app down. Only
  /// the waiting is asynchronous.
  ///
  /// Bounded, because "the completion never fires" is a real outcome — Apple's locate
  /// service can simply not answer, and an unbounded wait holds the helper's request slot
  /// until the server's own timeout kills it, with no explanation on either side. A timeout
  /// is not reported as an error: the caller reads the cache afterwards either way, so a
  /// slow fetch degrades to a stale position rather than to a failure.
  private static func withCompletion(
    timeout: Duration = .seconds(20),
    _ body: (@escaping @Sendable () -> Void) throws -> Void
  ) async {
    let sentinel = CompletionSentinel()

    do {
      try body { sentinel.finish() }
    } catch {
      // The call did not even start — a moved selector, or an argument IMCore refused.
      // There will be no completion, so release the wait now rather than sitting out
      // the full timeout for an answer that is never coming.
      sentinel.finish()
    }

    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      sentinel.finish()
    }
    await sentinel.wait()
    watchdog.cancel()
  }
}

/// One-shot resume, safe to call from any thread.
///
/// IMCore's completions arrive on whatever queue the locate session happens to use, and more
/// than one of them can be in flight; `CheckedContinuation` traps on a second resume. A class
/// with a lock is the smallest thing that makes "first caller wins" true.
private final class CompletionSentinel: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var finished = false

  /// Suspends until `finish` is called, or returns immediately if it already has been.
  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      attach(continuation)
    }
  }

  private func attach(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    // Already finished: the call failed synchronously before the continuation was
    // installed. Resume immediately rather than storing a continuation nothing will
    // resume, which would hang until the timeout.
    if finished {
      lock.unlock()
      continuation.resume()
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume()
  }
}

//  FindMyInterface
//  What each FindMy operation MEANS: the cache, the two gated refreshes, and sharing.
//
//  RATE LIMITING IS GLOBAL. Every refresh reaches Apple, and Apple counts this server as one
//  FindMy client however many phones are talking to it. The gates live on `FindMyRuntime`,
//  shared by every caller, and a refused refresh answers with the CACHED positions and how
//  long until the next attempt, never an error, which would make a client retry straight
//  into the limiter.
//
//  The feature gates (`findmy_location_sharing`) stay in the handlers: they are refusals
//  with an HTTP spelling. The wire shapes stay there too: `friends` is frozen to the
//  previous server's `FindMyLocationItem`, and that is a projection, not a meaning.

import BBPrivateAPIContract
import BBSystem
import Foundation
import Logging

public struct FindMyInterface: MessagesBackedInterface {

  public typealias Helper = any FindMyAccess

  let privateAPI: Helper?
  let logger: Logger
  private let runtime: FindMyRuntime

  public init(
    runtime: FindMyRuntime,
    privateAPI: Helper?,
    logger: Logger = Logger(label: "bluebubbles.interface.findmy")
  ) {
    self.runtime = runtime
    self.privateAPI = privateAPI
    self.logger = logger
  }

  /// The outcome of a gated refresh.
  ///
  /// `tooSoon` carries what the cache already held, so a caller can answer with the position
  /// it has rather than a failure: the whole point of refusing politely.
  public enum Refresh<Value: Sendable>: Sendable {
    case refreshed(Value)
    case tooSoon(Value, retryAfter: Duration)
  }

  // MARK: - Reading

  /// Everyone the cache knows about. Served from memory rather than from disk: there IS no
  /// friends file; see `FindMyFriendsCache`.
  public func friends() async -> [FindMyFriend] {
    await runtime.friends.all
  }

  /// FindMy's own state, with the helper's absence REPORTED rather than raised.
  ///
  /// This is the call a client makes to decide whether to show FindMy at all, so it has to
  /// answer when the helper is disconnected: that is one of the answers. `try?` for the
  /// same reason: a helper that cannot say is a FindMy that is unavailable.
  public func status() async -> FindMyStatus {
    guard let api = privateAPI else { return .unavailable }
    return (try? await api.findMyStatus()) ?? .unavailable
  }

  // MARK: - Refreshing

  /// Asks Apple for a fresh fix on every friend, gated globally, and returns the whole cache.
  public func refreshFriends() async throws -> Refresh<[FindMyFriend]> {
    let api = try requirePrivateAPI(for: "refreshing FindMy friends")
    switch await runtime.refreshGate.attempt() {
    case .allowed:
      let friends = try await throughMessages { try await api.refreshFindMyFriends() }
      await runtime.friends.merge(friends)
      return .refreshed(await runtime.friends.all)
    case .tooSoon(let retryAfter):
      return .tooSoon(await runtime.friends.all, retryAfter: retryAfter)
    }
  }

  /// Asks for a fresh fix on ONE person, gated separately and more loosely.
  ///
  /// Refused, the cached entry comes back. A handle the cache has never seen is `.notFound`:
  /// there is nothing to answer with, and the gate has not opened to go and find out.
  public func refreshLocation(handle: String) async throws -> Refresh<FindMyFriend> {
    let api = try requirePrivateAPI(for: "refreshing a FindMy location")
    switch await runtime.handleRefreshGate.attempt() {
    case .allowed:
      let friend = try await throughMessages {
        try await api.refreshFindMyLocation(handle: handle)
      }
      await runtime.friends.merge(friend)
      return .refreshed(friend)
    case .tooSoon(let retryAfter):
      guard let cached = await runtime.friends.friend(handle: handle) else {
        throw InterfaceError.notFound("No FindMy location is known for \(handle) yet")
      }
      return .tooSoon(cached, retryAfter: retryAfter)
    }
  }

  // MARK: - Sharing

  /// Asks someone to share their location with us. No location comes back, and none should:
  /// the invite has been sent, and whether it is accepted happens on someone else's device,
  /// minutes or days later.
  public func requestShare(handle: String) async throws {
    let api = try requirePrivateAPI(for: "requesting a location share")
    try await throughMessages { try await api.requestFindMyLocationShare(handle: handle) }
  }

  /// Starts sharing THIS MAC's location with a chat's participants.
  public func startSharing(_ request: FindMyShareRequest) async throws {
    let api = try requirePrivateAPI(for: "sharing a FindMy location")
    try await throughMessages { try await api.startSharingFindMyLocation(request) }
  }

  /// Stops sharing with a chat, or with one participant of it.
  public func stopSharing(chat: ChatIdentifier, address: String?) async throws {
    let api = try requirePrivateAPI(for: "stopping a FindMy share")
    try await throughMessages {
      try await api.stopSharingFindMyLocation(chat: chat, address: address)
    }
  }
}

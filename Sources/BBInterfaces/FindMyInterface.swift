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
//  with an HTTP spelling. The wire shapes, including `friends`' frozen `FindMyLocationItem`,
//  are `FindMyInterface+Serialization`.

import BBCore
import BBPrivateAPIContract
import BBSystem
import Foundation
import Logging

public struct FindMyInterface: MessagesBackedInterface {

  public typealias Helper = any FindMyAccess

  let privateAPI: Helper?
  let logger: Logger
  private let runtime: FindMyRuntime
  private let contacts: ContactInterface?

  /// - Parameter contacts: where a friend's NAME comes from for the v1 `title`. Nil means
  ///   no address book, and every `title` is the handle; see `legacyPayload(_:name:)`.
  public init(
    runtime: FindMyRuntime,
    privateAPI: Helper?,
    contacts: ContactInterface? = nil,
    logger: Logger = Logger(label: "bluebubbles.interface.findmy")
  ) {
    self.runtime = runtime
    self.privateAPI = privateAPI
    self.contacts = contacts
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

  /// Everyone the cache knows about, topped up from IMCore's own cache when the helper is
  /// connected. There is no friends file; see `FindMyFriendsCache`.
  ///
  /// The reference answers from memory alone, which is empty until a refresh or a location
  /// event has filled it, so a client's first read of `findmy/friends` is `[]` however many
  /// people are sharing. IMCore already holds the relationship graph and the last position
  /// it saw for each person, and `findMyFriends` reads that cache without asking Apple, so
  /// there is nothing to rate-limit here; the merge keeps whatever a refresh found when it
  /// is the better fix.
  ///
  /// A helper that cannot answer does not fail a READ: the cache is still the answer, and
  /// the refusal goes to the log. The operations that reach Apple throw instead; see
  /// `FindMyFailureTests`.
  public func friends() async -> [FindMyFriend] {
    if let api = privateAPI {
      do {
        let known = try await throughMessages { try await api.findMyFriends() }
        await runtime.friends.merge(known)
      } catch {
        logger.debug(
          "Could not read FindMy friends from the helper; answering from the cache",
          metadata: ["error": .string(Redaction.error(error))])
      }
    }
    return await runtime.friends.all
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

  /// A friend's entry as the helper pushed it, unprompted, after IMCore received a position
  /// or a share started or stopped.
  ///
  /// This is how a refresh's RESULT arrives: `refreshFriends` only asks Apple, and the
  /// positions come back one device at a time, later. Merged through the cache's rules, and
  /// the friend comes back only when the cache changed, which is what decides whether
  /// clients hear about it: an update that moved nothing is not an event, and announcing
  /// every one would push forty identical positions a minute to every connected device.
  public func record(_ friend: FindMyFriend) async -> FindMyFriend? {
    guard await runtime.friends.merge(friend) else { return nil }
    logger.debug(
      "Recorded a pushed FindMy position",
      metadata: ["handle": .string(Redaction.address(friend.handle))])
    return friend
  }

  // MARK: - Names

  /// Friends in the frozen v1 shape, each `title` the person's contact name where the
  /// address book has one.
  ///
  /// The names are looked up once for the whole list, BEFORE serializing, so the
  /// projection itself stays a pure function of its arguments.
  public func legacyPayloads(_ friends: [FindMyFriend]) async -> [JSONValue] {
    let names = await contactNames(for: friends.map(\.handle))
    return friends.map { Self.legacyPayload($0, name: names[$0.handle]) }
  }

  /// One person's contact name, for the `title` of the `new-findmy-location` they are in.
  /// Nil when the address book has nobody at that address, or cannot be read.
  public func contactName(for handle: String) async -> String? {
    await contactNames(for: [handle])[handle]
  }

  /// Contact names by handle, with an address that matches nobody omitted.
  ///
  /// A failure is not the route's: the Contacts integration switched off throws, and so
  /// does an unreadable index, and either way the answer is the handle, which is what the
  /// reference's `title` was for anyone not in the address book. Logged, not raised.
  private func contactNames(for handles: [String]) async -> [String: String] {
    guard let contacts, !handles.isEmpty else { return [:] }
    do {
      return try await contacts.displayNames(for: handles)
    } catch {
      logger.debug(
        "No contact names for FindMy friends; titling them by handle",
        metadata: ["error": .string(Redaction.error(error))])
      return [:]
    }
  }

  // MARK: - Refreshing

  /// Asks Apple for a fresh fix on every friend, gated globally, and returns the whole cache.
  public func refreshFriends() async throws -> Refresh<[FindMyFriend]> {
    let api = try requirePrivateAPI(for: "refreshing FindMy friends")
    switch await runtime.refreshGate.attempt() {
    case .allowed:
      let friends = try await throughMessages { try await api.refreshFindMyFriends() }
      await runtime.friends.merge(friends)
      logger.debug(
        "Refreshed FindMy friends", metadata: ["friends": .stringConvertible(friends.count)])
      return .refreshed(await runtime.friends.all)
    case .tooSoon(let retryAfter):
      logger.debug(
        "FindMy friends refresh refused by the gate",
        metadata: ["retryAfterS": .stringConvertible(Int(retryAfter.seconds))])
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
      logger.debug(
        "Refreshed a FindMy location",
        metadata: ["handle": .string(Redaction.address(handle))])
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
    logger.info(
      "Requesting a FindMy location share",
      metadata: ["handle": .string(Redaction.address(handle))])
    try await throughMessages { try await api.requestFindMyLocationShare(handle: handle) }
  }

  /// Starts sharing THIS MAC's location with a chat's participants.
  public func startSharing(_ request: FindMyShareRequest) async throws {
    let api = try requirePrivateAPI(for: "sharing a FindMy location")
    logger.info(
      "Sharing this Mac's location",
      metadata: ["chat": .string(Redaction.chatGUID(request.chat.rawValue))])
    try await throughMessages { try await api.startSharingFindMyLocation(request) }
  }

  /// Stops sharing with a chat, or with one participant of it.
  public func stopSharing(chat: ChatIdentifier, address: String?) async throws {
    let api = try requirePrivateAPI(for: "stopping a FindMy share")
    logger.info(
      "Stopping a FindMy location share",
      metadata: [
        "chat": .string(Redaction.chatGUID(chat.rawValue)),
        "address": .string(address.map(Redaction.address) ?? "-"),
      ])
    try await throughMessages {
      try await api.stopSharingFindMyLocation(chat: chat, address: address)
    }
  }
}

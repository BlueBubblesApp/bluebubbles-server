//  PrivateAPIClient+FindMy
//  The `FindMyAccess` role: friends' locations and location sharing, through the Messages
//  helper.
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: FindMyAccess {

  // The helper answers in the contract's vocabulary, not IMCore's: the narrowing happens
  // inside Messages.app, so a DSID never crosses this socket in the first place. Each reply
  // is decoded by the contract's codec (`WireCodecs.swift`), the same one that encoded it.

  public func findMyStatus() async throws -> FindMyStatus {
    let result = try await transport.request(
      action: .findMyStatus, data: .emptyObject)
    return try FindMyStatus(reply: result, to: .findMyStatus)
  }

  public func findMyFriends() async throws -> [FindMyFriend] {
    let result = try await transport.request(
      action: .findMyFriends, data: .emptyObject)
    return try Self.friends(from: result, to: .findMyFriends)
  }

  public func refreshFindMyFriends() async throws -> [FindMyFriend] {
    let result = try await transport.request(
      action: .refreshFindMyFriends, data: .emptyObject
    )
    return try Self.friends(from: result, to: .refreshFindMyFriends)
  }

  public func refreshFindMyLocation(handle: String) async throws -> FindMyFriend {
    let result = try await transport.request(
      action: .refreshFindMyLocation,
      data: .object([.address: .string(handle)])
    )
    return try WireReader(reply: result, to: .refreshFindMyLocation).decode(.friend)
  }

  public func requestFindMyLocationShare(handle: String) async throws {
    try await transport.request(
      action: .requestFindMyLocationShare,
      data: .object([.address: .string(handle)])
    )
  }

  public func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws {
    try await transport.request(
      action: .startSharingFindMyLocation,
      data: .object(dropping: [
        .chatGuid: .string(request.chat.rawValue),
        .address: request.address.map(WireJSON.string),
        .duration: .string(request.duration.rawValue),
      ])
    )
  }

  public func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws {
    try await transport.request(
      action: .stopSharingFindMyLocation,
      data: .object(dropping: [
        .chatGuid: .string(chat.rawValue),
        .address: address.map(WireJSON.string),
      ])
    )
  }

  // MARK: FindMy decoding

  /// An entry with an empty handle is not a friend: it can never be looked up or refreshed,
  /// so it is left out rather than stored.
  private static func friends(from result: WireJSON?, to action: MessagesHelperAction) throws
    -> [FindMyFriend]
  {
    try WireReader(reply: result, to: action).decodeList(.friends, as: FindMyFriend.self)
      .filter { !$0.handle.isEmpty }
  }
}

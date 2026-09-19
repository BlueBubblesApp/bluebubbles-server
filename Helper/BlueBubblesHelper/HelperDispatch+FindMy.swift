//  HelperDispatch+FindMy
//  FindMy. Each reply is the CONTRACT's shape, encoded here rather than IMCore's: the
//  narrowing described in BBPrivateAPIContract/FindMy.swift: a DSID or a hashed DSID would
//  travel just as easily and identifies an Apple account, so it never leaves this process.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func findMyStatus(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    return encode(try await bridge.findMyStatus())
  }

  @MainActor
  static func findMyFriends(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.friends: try await bridge.findMyFriends().map(encode)]
  }

  @MainActor
  static func refreshFindMyFriends(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.friends: try await bridge.refreshFindMyFriends().map(encode)]
  }

  @MainActor
  static func refreshFindMyLocation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [
      .friend: encode(
        try await bridge.refreshFindMyLocation(handle: try data.string(.address))
      )
    ]
  }

  @MainActor
  static func requestFindMyLocationShare(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.requestFindMyLocationShare(handle: try data.string(.address))
    return nil
  }

  @MainActor
  static func startSharingFindMyLocation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    let requestedDuration = try data.string(.duration)
    guard let duration = FindMyShareDuration(rawValue: requestedDuration) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "unknown share duration '\(requestedDuration)'; expected one of "
          + FindMyShareDuration.allCases.map(\.rawValue).joined(separator: ", ")
      )
    }
    try await bridge.startSharingFindMyLocation(
      FindMyShareRequest(
        chat: try data.chat(), address: data.optionalString(.address), duration: duration
      )
    )
    return nil
  }

  @MainActor
  static func stopSharingFindMyLocation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.stopSharingFindMyLocation(
      chat: try data.chat(), address: data.optionalString(.address)
    )
    return nil
  }

  static func encode(_ status: FindMyStatus) -> WireObject {
    WireObject([
      .available: status.isAvailable,
      .provisioned: status.isProvisioned,
      .restricted: status.isRestricted,
      .sharingDisabled: status.isSharingDisabled,
      .backend: status.backend.rawValue,
      .activeDevice: status.activeDevice.map { device in
        WireObject([.name: device.name, .isThisDevice: device.isThisDevice])
      },
    ])
  }

  static func encode(_ friend: FindMyFriend) -> WireObject {
    WireObject([
      .handle: friend.handle,
      .isSharingWithMe: friend.isSharingWithMe,
      .isFollowingMyLocation: friend.isFollowingMyLocation,
      .location: friend.location.map(encode),
    ])
  }

  static func encode(_ location: FindMyLocation) -> WireObject {
    WireObject([
      // Emitted only when there IS a fix. IMCore reports an unlocated friend at the
      // origin rather than as nil, and a client that trusts that drops a pin in the
      // Gulf of Guinea, so the check is here, once, rather than in every client.
      .latitude: location.hasCoordinates ? location.latitude : nil,
      .longitude: location.hasCoordinates ? location.longitude : nil,
      .horizontalAccuracy: location.horizontalAccuracy,
      .altitude: location.altitude,
      .shortAddress: location.shortAddress,
      .longAddress: location.longAddress,
      .label: location.label,
      // Milliseconds since the epoch, matching every other timestamp on this wire.
      .lastUpdated: location.lastUpdated.map {
        Int(($0.timeIntervalSince1970 * 1000).rounded())
      },
      .isLocatingInProgress: location.isLocatingInProgress,
      .status: location.status.rawValue,
    ])
  }
}

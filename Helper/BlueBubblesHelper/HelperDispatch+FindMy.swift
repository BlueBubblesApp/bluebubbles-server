//  HelperDispatch+FindMy
//  FindMy. Each reply is the CONTRACT's shape, encoded by the contract's own codec
//  (`WireCodecs.swift`) rather than from IMCore's: the narrowing described in
//  BBPrivateAPIContract/FindMy.swift: a DSID or a hashed DSID would travel just as easily
//  and identifies an Apple account, so it never leaves this process.
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
    return try await bridge.findMyStatus().wire
  }

  @MainActor
  static func findMyFriends(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.friends: try await bridge.findMyFriends().map(\.wire)]
  }

  @MainActor
  static func refreshFindMyFriends(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.friends: try await bridge.refreshFindMyFriends().map(\.wire)]
  }

  @MainActor
  static func refreshFindMyLocation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [
      .friend: try await bridge.refreshFindMyLocation(handle: try data.string(.address)).wire
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
}

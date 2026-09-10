//  HelperDispatch+Identity
//  Handles, the account and its aliases, and the shared contact card.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func checkIMessageAvailability(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [
      .available: try await bridge.checkIMessageAvailability(
        address: try data.string(.address)
      )
    ]
  }

  @MainActor
  static func checkFaceTimeAvailability(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [
      .available: try await bridge.checkFaceTimeAvailability(
        address: try data.string(.address)
      )
    ]
  }

  @MainActor
  static func checkFocusStatus(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.status: try await bridge.checkFocusStatus(address: try data.string(.address))]
  }

  @MainActor
  static func getAccountInfo(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    let info = try await bridge.accountInfo()
    return [
      .appleId: info.appleId,
      .activeAlias: info.activeAlias,
      .aliases: info.aliases,
      .vettedAliases: info.vettedAliases,
    ]
  }

  @MainActor
  static func getNicknameInfo(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    // OPTIONAL, deliberately. An absent address means the local user's own contact card,
    // which is the default form of `GET /api/v1/icloud/contact` and the one the
    // reference server's fixture records. Requiring the key would turn that into a 400.
    let info = try await bridge.nicknameInfo(for: data.optionalString(.address))
    return [
      .handle: info.handle,
      .name: info.name,
      .hasSharedNickname: info.hasSharedNickname,
      .avatarPath: info.avatarPath,
    ]
  }

  @MainActor
  static func shouldOfferNicknameSharing(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.shouldOffer: try await bridge.shouldOfferNicknameSharing(chat: try data.chat())]
  }

  @MainActor
  static func shareNickname(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.shareNickname(chat: try data.chat())
    return nil
  }

  @MainActor
  static func modifyActiveAlias(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.modifyActiveAlias(try data.string(.alias))
    return nil
  }
}

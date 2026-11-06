//  HelperDispatch+Muting
//  Muting a conversation. Milliseconds on the wire, and an ABSENT `mutedUntil`
//  means indefinitely, not the same as a null, which is why the key is read as an optional
//  rather than defaulted. The reply is `ChatMuteState`'s contract codec.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func getChatMute(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    return try await bridge.muteState(chat: try data.chat()).wire
  }

  @MainActor
  static func setChatMute(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    return try await bridge.setMute(
      ChatMuteRequest(
        chat: try data.chat(),
        until: data.optionalDate(.mutedUntil),
        // Defaults to TRUE, so a client that does not think about it gets the
        // behaviour Messages' own UI has.
        syncToPairedDevice: data[.syncToPairedDevice]?.boolValue ?? true
      )
    ).wire
  }

  @MainActor
  static func unmuteChat(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    return try await bridge.unmute(
      chat: try data.chat(),
      syncToPairedDevice: data[.syncToPairedDevice]?.boolValue ?? true
    ).wire
  }
}

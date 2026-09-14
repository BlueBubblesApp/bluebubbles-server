//  HelperDispatch+Muting
//  Muting a conversation. Milliseconds on the wire, and an ABSENT `mutedUntil`
//  means indefinitely, not the same as a null, which is why the key is read with `map`
//  rather than defaulted.
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
    return encode(try await bridge.muteState(chat: try data.chat()))
  }

  @MainActor
  static func setChatMute(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    let until = data[.mutedUntil]?.intValue
      .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    return encode(
      try await bridge.setMute(
        ChatMuteRequest(
          chat: try data.chat(),
          until: until,
          // Defaults to TRUE, so a client that does not think about it gets the
          // behaviour Messages' own UI has.
          syncToPairedDevice: data[.syncToPairedDevice]?.boolValue ?? true
        )
      ))
  }

  @MainActor
  static func unmuteChat(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    return encode(
      try await bridge.unmute(
        chat: try data.chat(),
        syncToPairedDevice: data[.syncToPairedDevice]?.boolValue ?? true
      ))
  }

  /// `mutedUntil` is OMITTED for an indefinite mute rather than sent as the year 4001.
  /// A client showing "muted until <date>" would otherwise render a sentinel as a date.
  static func encode(_ state: ChatMuteState) -> WireObject {
    WireObject([
      .isMuted: state.isMuted,
      .isIndefinite: state.isIndefinite,
      .mutedUntil: state.mutedUntil.map {
        Int(($0.timeIntervalSince1970 * 1000).rounded())
      },
    ])
  }
}

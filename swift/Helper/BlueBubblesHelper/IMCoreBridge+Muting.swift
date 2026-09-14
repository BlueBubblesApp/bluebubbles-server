//  IMCoreBridge+Muting
//  Per-chat mute state. `ChatMuting`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. New: the shipping Objective-C helper cannot mute at all.
  public func muteState(chat: ChatIdentifier) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      return try Self.muteState(of: conversation)
    }
  }

  public func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      // A mute that has already expired is a no-op dressed as a success, and the client
      // that computed the date from a stale clock would never find out.
      if let until = request.until, until <= Date() {
        throw PrivateAPIErrorShim.rejected(
          "that mute expires in the past; pass a future date, or omit it to mute "
            + "indefinitely"
        )
      }
      try IMMutedChats.mute(
        conversation, until: request.until, sync: request.syncToPairedDevice
      )
      return try Self.muteState(of: conversation)
    }
  }

  public func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      try IMMutedChats.unmute(conversation, sync: syncToPairedDevice)
      return try Self.muteState(of: conversation)
    }
  }

  /// The state as IMCore sees it, read the same way after a write as before one.
  ///
  /// The DATE is authoritative and `-isMutedChat:` is the cross-check, not the other way
  /// round: the date carries "until when", which is the half a client cannot recompute.
  /// They disagree only in one direction (an entry whose instant has passed) and the
  /// date's reading of that (not muted) is IMCore's own.
  private static func muteState(of chat: IMChat) throws -> ChatMuteState {
    let byDate = ChatMuteState.from(unmuteDate: try IMMutedChats.unmuteDate(for: chat))
    guard let byList = try? IMMutedChats.isMuted(chat), byList != byDate.isMuted else {
      return byDate
    }
    // Trust IMCore's own answer for the boolean, keep the date for the detail. Reaching
    // here means the two disagree, which is worth a log and is not worth failing over.
    BlueBubblesHelper.Logging.log(
      "mute: isMutedChat: says \(byList) and the unmute date says \(byDate.isMuted)"
    )
    return ChatMuteState(
      isMuted: byList,
      mutedUntil: byList ? byDate.mutedUntil : nil,
      isIndefinite: byList && byDate.isIndefinite
    )
  }
}

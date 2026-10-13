//  HelperDispatch+Presence
//  Typing and read state.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func startTyping(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    try await bridge.startTyping(chat: try data.chat())
    return nil
  }

  @MainActor
  static func stopTyping(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    try await bridge.stopTyping(chat: try data.chat())
    return nil
  }

  @MainActor
  static func checkTypingStatus(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.typing: try await bridge.checkTypingStatus(chat: try data.chat())]
  }

  @MainActor
  static func markChatRead(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    try await bridge.markRead(chat: try data.chat())
    return nil
  }

  @MainActor
  static func markChatUnread(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.markUnread(chat: try data.chat())
    return nil
  }
}

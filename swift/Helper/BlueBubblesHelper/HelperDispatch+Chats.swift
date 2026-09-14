//  HelperDispatch+Chats
//  Conversations: creating, leaving, naming, membership, pins and wallpaper.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func createChat(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    let addresses = (data[.addresses]?.arrayValue ?? []).compactMap(\.stringValue)
    let created = try await bridge.createChat(
      addresses: addresses,
      service: data.optionalString(.service) ?? "iMessage",
      message: data.optionalString(.message)
    )
    return [.identifier: created.rawValue]
  }

  @MainActor
  static func deleteChat(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    try await bridge.deleteChat(try data.chat())
    return nil
  }

  @MainActor
  static func leaveChat(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject? {
    try await bridge.leaveChat(try data.chat())
    return nil
  }

  @MainActor
  static func setDisplayName(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.setDisplayName(chat: try data.chat(), to: try data.string(.newName))
    return nil
  }

  @MainActor
  static func updateGroupPhoto(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.updateGroupPhoto(chat: try data.chat(), imagePath: try data.string(.filePath))
    return nil
  }

  @MainActor
  static func addParticipant(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.addParticipant(try data.string(.address), to: try data.chat())
    return nil
  }

  @MainActor
  static func removeParticipant(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.removeParticipant(try data.string(.address), from: try data.chat())
    return nil
  }

  @MainActor
  static func updateChatPinned(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.setPinned(chat: try data.chat(), pinned: data.flag(.pinned))
    return nil
  }

  /// An ARRAY, because pins render in this order and a client syncing them has to keep
  /// it. Wrapped in an object rather than returned bare so the reply can grow a field
  /// later without becoming a different type.
  @MainActor
  static func getPinnedChats(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.chats: try await bridge.pinnedChats().map(\.rawValue)]
  }

  @MainActor
  static func refetchChatBackground(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    try await bridge.refetchChatBackground(chat: try data.chat())
    return nil
  }
}

//  HelperDispatch+Filtering
//  Filtering, spam and history: one piece of IMCore state with four ways in.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func clearChatHistory(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.deleted: try await bridge.clearChatHistory(try data.chat())]
  }

  @MainActor
  static func getChatFilter(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return try await bridge.chatFilterState(chat: try data.chat()).wire
  }

  @MainActor
  static func markSenderKnown(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return try await bridge.markSenderKnown(
      chat: try data.chat(), saveInContacts: data.flag(.saveInContacts)
    ).wire
  }

  @MainActor
  static func getChatPresentation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return try await bridge.chatPresentationState(chat: try data.chat()).wire
  }

  @MainActor
  static func markChatSpam(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    return try await bridge.markChatAsSpam(
      ChatSpamRequest(
        chat: try data.chat(),
        reportToCarrier: data.flag(.reportToCarrier),
        dryRun: data.flag(.dryRun)
      )
    ).wire
  }

  @MainActor
  static func reportChatJunk(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return try await bridge.reportChatAsJunk(
      ChatSpamRequest(
        chat: try data.chat(),
        reportToCarrier: data.flag(.reportToCarrier),
        dryRun: data.flag(.dryRun)
      )
    ).wire
  }

  @MainActor
  static func setChatFilter(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    guard let category = data[.category]?.intValue else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "set-chat-filter requires 'category'"
      )
    }
    return try await bridge.setChatFilter(chat: try data.chat(), category: category).wire
  }
}

//  IMCoreBridge+Scheduling
//  Messages Messages will send later, and changing one before it goes.
//  `ScheduledMessaging`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// NEW. See `IMChat.editScheduledMessage(item:scheduleType:deliveryTime:)`.
  public func rescheduleMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, to date: Date
  ) async throws {
    try await editScheduled(guid, in: chat, scheduleType: ScheduledSend.type, deliveryTime: date)
  }

  /// Send now: schedule type 0 and no delivery time, which is what the transcript's own
  /// "Send Now" passes.
  public func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    try await editScheduled(guid, in: chat, scheduleType: 0, deliveryTime: nil)
  }

  /// NEW. See `IMChat.editScheduledMessageText(item:partIndex:text:)`.
  public func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).editScheduledMessageText(
        item: item, partIndex: partIndex, text: NSAttributedString(string: newText))
    }
  }

  private func editScheduled(
    _ guid: MessageGUID, in chat: ChatIdentifier, scheduleType: UInt, deliveryTime: Date?
  ) async throws {
    // The message ITEM, as cancelling needs; see `cancelScheduledMessage`.
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).editScheduledMessage(
        item: item, scheduleType: scheduleType, deliveryTime: deliveryTime)
    }
  }

  /// NEW: no Objective-C counterpart. See `IMChat.cancelScheduledMessage(guid:)`.
  public func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    let item = try await IMChatHistory.messageItem(guid: guid.rawValue)
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).cancelScheduledMessage(item: item)
    }
  }
}

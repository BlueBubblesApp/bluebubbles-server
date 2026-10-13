//  IMCoreBridge+Presence
//  Typing indicators and read state: what the other end can see about you.
//  `ChatPresence`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: `[chat setLocalUserIsTyping:YES]` (BlueBubblesHelper.m:194).
  public func startTyping(chat: ChatIdentifier) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setLocalUserIsTyping(true)
    }
  }

  /// PORTED. ObjC: `[chat setLocalUserIsTyping:NO]` (BlueBubblesHelper.m:194).
  public func stopTyping(chat: ChatIdentifier) async throws {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).setLocalUserIsTyping(false)
    }
  }

  /// PORTED. ObjC: `chat.lastIncomingMessage.isTypingMessage` (BlueBubblesHelper.m:205).
  ///
  /// Derived from the last incoming message rather than read directly: IMCore has no "is
  /// the other person typing" property, only a message that *is* a typing indicator.
  public func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).isRemoteTyping()
    }
  }

  /// PORTED. ObjC: `handleReadStatusForChat:` (BlueBubblesHelper.m:384).
  ///
  /// Read state lives on the CONVERSATION. Calling it on IMChat (which the previous pass
  /// did) reaches a different object graph.
  public func markRead(chat: ChatIdentifier) async throws {
    try translating {
      try requireConversation(chat).markAllMessagesAsRead()
    }
  }

  /// PORTED. ObjC: `handleReadStatusForChat:` (BlueBubblesHelper.m:384). Ventura and later.
  public func markUnread(chat: ChatIdentifier) async throws {
    try translating {
      try requireConversation(chat).markLastMessageAsUnread()
    }
  }
}

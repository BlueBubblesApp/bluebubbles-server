//  IMCoreBridge+Polls
//  Polls, the newest and least settled of these surfaces. `PollControl`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// NEW. See `IMPolls`. One synchronous block, as every ChatKit send.
  public func createPoll(_ request: PollCreateRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)
      let composition = try IMPolls.composition(title: request.title, options: request.options)
      guard conversation.canSend(composition) else {
        throw PrivateAPIErrorShim.rejected(
          "ChatKit will not send a poll to this conversation: polls need iMessage on both "
            + "ends and macOS 26")
      }
      let messages = try conversation.messages(from: composition)
      for message in messages { try conversation.send(message) }
      let guid =
        messages.first.flatMap { ((try? IMCoreRuntime.string($0, "guid")) ?? nil) } ?? ""
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// NEW. See `IMPolls.updateComposition`: the same send as a create, in the poll's session.
  public func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)
      let message = try IMPolls.updateMessage(request)
      try conversation.send(message, newComposition: false)
      let guid = ((try? IMCoreRuntime.string(message, "guid")) ?? nil) ?? ""
      guard !guid.isEmpty else {
        throw PrivateAPIErrorShim.rejected("Messages accepted the poll update but reported no GUID")
      }
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }

  /// NEW. See `IMPolls.voteMessage`.
  public func votePoll(_ request: PollVoteRequest) async throws -> SentMessage {
    try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let message = try IMPolls.voteMessage(request)
      try chat.send(message)
      var guid = ((try? IMCoreRuntime.string(message, "guid")) ?? nil)
      if guid == nil || guid?.isEmpty == true { guid = try chat.lastSentMessageGUID() }
      guard let guid else {
        throw PrivateAPIErrorShim.rejected("Messages accepted the vote but reported no GUID")
      }
      return SentMessage(guid: MessageGUID(guid), chat: request.chat, sentAt: Date())
    }
  }
}

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
      return try sent(messages, to: request.chat, sending: "poll")
    }
  }

  /// NEW. See `IMPolls.updateComposition`: the same send as a create, in the poll's session.
  public func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage {
    try translating {
      let conversation = try requireConversation(request.chat)
      let message = try IMPolls.updateMessage(request)
      try conversation.send(message, newComposition: false)
      return try sent([message], to: request.chat, sending: "poll update")
    }
  }

  /// NEW. See `IMPolls.voteMessage`.
  public func votePoll(_ request: PollVoteRequest) async throws -> SentMessage {
    try translating {
      let chat = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let message = try IMPolls.voteMessage(request)
      // Built by a class factory, so the GUID is read or given before the send rather
      // than passed to an initialiser; see `IMMessageBuilder.assignedGUID(of:)`.
      let guid = try IMMessageBuilder.assignedGUID(of: message)
      try chat.send(message)
      return try sent([message], to: request.chat, assignedGUID: guid, sending: "vote")
    }
  }
}

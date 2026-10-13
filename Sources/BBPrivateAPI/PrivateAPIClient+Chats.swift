//  PrivateAPIClient+Chats
//  The roles that act on a conversation: `ChatAdministration`, `ChatMuting`,
//  `ChatFiltering` and `ChatPresence`. The mute and filter calls answer with the chat's
//  state, decoded by the contract's codec (`WireCodecs.swift`), so a reply in the wrong
//  shape throws rather than reading as a default a client would act on.
//
//  One slice of `PrivateAPIClient`; the type, its transport and the payload shapes every
//  role shares are in `PrivateAPIClient.swift`.

import BBPrivateAPIContract
import Foundation

extension PrivateAPIClient: ChatAdministration {

  public func createChat(
    addresses: [String],
    service: String,
    message: String?
  ) async throws -> NewChat {
    let result = try await transport.request(
      action: .createChat,
      data: .object(dropping: [
        .addresses: .array(addresses.map { .string($0) }),
        .service: .string(service),
        .message: message.map(WireJSON.string),
      ]))
    // `identifier` is what a helper built before the two fields were named sent, and it
    // was the chat's GUID there too: this helper has never answered with a message GUID.
    guard
      let chat = result?[.chatGuid]?.stringValue ?? result?[.identifier]?.stringValue,
      !chat.isEmpty
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "create-chat returned no chat GUID")
    }
    return NewChat(
      chat: ChatIdentifier(chat),
      firstMessage: result?[.messageGuid]?.stringValue.flatMap {
        $0.isEmpty ? nil : MessageGUID($0)
      }
    )
  }

  public func deleteChat(_ chat: ChatIdentifier) async throws {
    try await chatAction(.deleteChat, chat)
  }

  public func leaveChat(_ chat: ChatIdentifier) async throws {
    try await chatAction(.leaveChat, chat)
  }

  public func setDisplayName(chat: ChatIdentifier, to name: String) async throws {
    try await transport.request(
      action: .setDisplayName,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .newName: .string(name),
      ]))
  }

  public func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws {
    try await transport.request(
      action: .updateGroupPhoto,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .filePath: .string(imagePath),
      ]))
  }

  public func addParticipant(_ address: String, to chat: ChatIdentifier) async throws {
    try await participantAction(.addParticipant, address: address, chat: chat)
  }

  public func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws {
    try await participantAction(.removeParticipant, address: address, chat: chat)
  }

  /// Pinning has no route in the Node server, so it reaches the API only through the
  /// additive chat group. The helper action name matches the shipping helper's
  /// (`update-chat-pinned`) so an older helper understands it too.
  public func setPinned(chat: ChatIdentifier, pinned: Bool) async throws {
    try await transport.request(
      action: .updateChatPinned,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .pinned: .bool(pinned),
      ]))
  }

  /// The pinned conversations, in display order.
  ///
  /// A NEW action rather than one the shipping Objective-C helper knows: that one only
  /// writes. An older helper answers `notImplemented`, which is the honest result and is why
  /// the route reports the helper's error rather than an empty list: "no pins" and "this
  /// helper cannot tell you" are different answers, and a client syncing pins would treat
  /// the first as instruction to unpin everything.
  public func pinnedChats() async throws -> [ChatIdentifier] {
    let reply = try await transport.request(
      action: .getPinnedChats, data: .emptyObject)
    return try WireReader(reply: reply, to: .getPinnedChats).strings(.chats)
      .map { ChatIdentifier($0) }
  }

  public func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool {
    let reply = try await transport.request(
      action: .clearChatHistory,
      data: .object([.chatGuid: .string(chat.rawValue)])
    )
    return try WireReader(reply: reply, to: .clearChatHistory).bool(.deleted)
  }

  public func refetchChatBackground(chat: ChatIdentifier) async throws {
    try await chatAction(.refetchChatBackground, chat)
  }

  private func participantAction(
    _ action: MessagesHelperAction, address: String, chat: ChatIdentifier
  )
    async throws
  {
    try await transport.request(
      action: action,
      data: .object([
        .chatGuid: .string(chat.rawValue),
        .address: .string(address),
      ]))
  }
}

extension PrivateAPIClient: ChatMuting {

  /// A reply with no `isMuted` is a helper from another build, and throws as one rather
  /// than decoding into "not muted", which a client would act on by letting the user "mute"
  /// an already-muted chat.
  public func muteState(chat: ChatIdentifier) async throws -> ChatMuteState {
    try ChatMuteState(
      reply: await transport.request(
        action: .getChatMute,
        data: .object([.chatGuid: .string(chat.rawValue)])
      ), to: .getChatMute)
  }

  public func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState {
    let payload = WireJSON.object(dropping: [
      .chatGuid: .string(request.chat.rawValue),
      // OMITTED for an indefinite mute. A null would be read as "no date" by the
      // helper too, but the absence is the contract and a null is a different message.
      .mutedUntil: request.until.map { .number(Double($0.wireMilliseconds)) },
      .syncToPairedDevice: .bool(request.syncToPairedDevice),
    ])
    return try ChatMuteState(
      reply: await transport.request(action: .setChatMute, data: payload), to: .setChatMute)
  }

  public func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    try ChatMuteState(
      reply: await transport.request(
        action: .unmuteChat,
        data: .object([
          .chatGuid: .string(chat.rawValue),
          .syncToPairedDevice: .bool(syncToPairedDevice),
        ])
      ), to: .unmuteChat)
  }
}

extension PrivateAPIClient: ChatFiltering {

  public func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState {
    try ChatFilterState(
      reply: await transport.request(
        action: .getChatFilter,
        data: .object([.chatGuid: .string(chat.rawValue)])
      ), to: .getChatFilter)
  }

  public func chatPresentationState(chat: ChatIdentifier) async throws -> ChatPresentationState {
    try ChatPresentationState(
      reply: await transport.request(
        action: .getChatPresentation,
        data: .object([.chatGuid: .string(chat.rawValue)])
      ), to: .getChatPresentation)
  }

  public func markSenderKnown(
    chat: ChatIdentifier, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    try ChatFilterState(
      reply: await transport.request(
        action: .markSenderKnown,
        data: .object([
          .chatGuid: .string(chat.rawValue),
          .saveInContacts: .bool(saveInContacts),
        ])
      ), to: .markSenderKnown)
  }

  public func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try ChatSpamResult(
      reply: await transport.request(action: .markChatSpam, data: Self.spamPayload(request)),
      to: .markChatSpam)
  }

  public func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try ChatSpamResult(
      reply: await transport.request(action: .reportChatJunk, data: Self.spamPayload(request)),
      to: .reportChatJunk)
  }

  public func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState {
    try ChatFilterState(
      reply: await transport.request(
        action: .setChatFilter,
        data: .object([
          .chatGuid: .string(chat.rawValue),
          .category: .number(Double(category)),
        ])
      ), to: .setChatFilter)
  }

  private static func spamPayload(_ request: ChatSpamRequest) -> WireJSON {
    .object([
      .chatGuid: .string(request.chat.rawValue),
      .reportToCarrier: .bool(request.reportToCarrier),
      .dryRun: .bool(request.dryRun),
    ])
  }
}

extension PrivateAPIClient: ChatPresence {

  public func startTyping(chat: ChatIdentifier) async throws {
    try await chatAction(.startTyping, chat)
  }

  public func stopTyping(chat: ChatIdentifier) async throws {
    try await chatAction(.stopTyping, chat)
  }

  public func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool {
    let result = try await transport.request(
      action: .checkTypingStatus,
      data: .object([.chatGuid: .string(chat.rawValue)])
    )
    return try WireReader(reply: result, to: .checkTypingStatus).bool(.typing)
  }

  public func markRead(chat: ChatIdentifier) async throws {
    try await chatAction(.markChatRead, chat)
  }

  public func markUnread(chat: ChatIdentifier) async throws {
    try await chatAction(.markChatUnread, chat)
  }
}

//  ChatInterface+Administration
//  Everything that changes a chat, and therefore everything that needs the Private API.
//
//  Pinning, muting, filtering, junk reporting, group membership and typing indicators. Each
//  is a thin call through `requirePrivateAPI` and `throughMessages`, so what is worth reading
//  here is which capability each one asks for, not the bodies.

import BBAppleScript
import BBCore
import BBIMessage
import BBPrivateAPI
import BBPrivateAPIContract
import BBSerialization
import BBShortcuts
import Foundation
import Logging

extension ChatInterface {

  // MARK: - Private-API-only operations

  public func delete(guid: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a chat")
    try await throughMessages { try await api.deleteChat(ChatIdentifier(guid)) }
  }

  public func leave(guid: String) async throws {
    let api = try requirePrivateAPI(for: "leaving a chat")
    try await throughMessages { try await api.leaveChat(ChatIdentifier(guid)) }
  }

  public func setPinned(guid: String, pinned: Bool) async throws {
    let api = try requirePrivateAPI(for: "pinning a chat")
    try await throughMessages {
      try await api.setPinned(chat: ChatIdentifier(guid), pinned: pinned)
    }
  }

  /// The pinned conversations, in display order, each serialized as a full chat.
  ///
  /// Full chats rather than bare GUIDs. A client syncing pins has to show them, and a list
  /// of GUIDs would mean a request per pin to render a name, on the one call whose entire
  /// purpose is "tell me the state so I can mirror it elsewhere".
  ///
  /// A GUID the helper reports that this database no longer has is DROPPED, not returned as
  /// a stub: it means Messages is holding a pin for a conversation that is gone, and a
  /// client cannot act on it.
  public func pinned(query: Query = Query()) async throws -> [ChatProjection] {
    let api = try requirePrivateAPI(for: "reading pinned chats")
    var rows: [ChatRow] = []
    for guid in try await throughMessages({ try await api.pinnedChats() }) {
      // One lookup per pin, and people pin a handful. Order is preserved by appending
      // in the order the helper gave, which IS the display order.
      if let row = try await repository.chats(guid: guid.rawValue).first {
        rows.append(row)
      }
    }
    return try await project(rows, query: query)
  }

  // MARK: Mute

  public func muteState(guid: String) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "reading a chat's mute state")
    return try await throughMessages { try await api.muteState(chat: ChatIdentifier(guid)) }
  }

  /// Mutes until `until`, or indefinitely when it is nil.
  ///
  /// The date arrives absolute. Every granularity a client offers (an hour, this evening,
  /// tomorrow, forever) is a date it computes, so the server never grows a menu of
  /// durations that has to be kept in step with someone's UI.
  public func setMute(
    guid: String, until: Date?, syncToPairedDevice: Bool
  ) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "muting a chat")
    // A mute that has already expired is a no-op reported as a success. The helper
    // refuses it too, but a rejection from Messages surfaces as a 500, and this is a
    // client mistake, which is a 400. Both checks stay: one is the API's contract, the
    // other is the last line before IMCore.
    if let until, until <= Date() {
      throw InterfaceError.invalidRequest(
        "`mutedUntil` is in the past; send a future date, `durationSeconds`, or "
          + "`indefinite: true`"
      )
    }
    return try await throughMessages {
      try await api.setMute(
        ChatMuteRequest(
          chat: ChatIdentifier(guid), until: until, syncToPairedDevice: syncToPairedDevice
        )
      )
    }
  }

  public func unmute(guid: String, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    let api = try requirePrivateAPI(for: "unmuting a chat")
    return try await throughMessages {
      try await api.unmute(
        chat: ChatIdentifier(guid), syncToPairedDevice: syncToPairedDevice
      )
    }
  }

  /// Asks Messages to download this conversation's background asset from iCloud.
  public func refetchBackground(guid: String) async throws {
    let api = try requirePrivateAPI(for: "downloading a chat background")
    try await throughMessages { try await api.refetchChatBackground(chat: ChatIdentifier(guid)) }
  }

  // MARK: History and filtering

  /// Deletes every message in a conversation. The conversation itself stays.
  ///
  /// Destructive and synced: the messages leave every device on the account. The
  /// confirmation and the user-visible alert live in the handler; this layer does the work.
  public func clearHistory(guid: String) async throws -> Bool {
    let api = try requirePrivateAPI(for: "clearing a chat's history")
    return try await throughMessages { try await api.clearChatHistory(ChatIdentifier(guid)) }
  }

  public func filterState(guid: String) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "reading a chat's filter state")
    return try await throughMessages { try await api.chatFilterState(chat: ChatIdentifier(guid)) }
  }

  public func markSenderKnown(
    guid: String, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "marking a sender as known")
    return try await throughMessages {
      try await api.markSenderKnown(chat: ChatIdentifier(guid), saveInContacts: saveInContacts)
    }
  }

  public func markSpam(
    guid: String, reportToCarrier: Bool, dryRun: Bool
  ) async throws -> ChatSpamResult {
    let api = try requirePrivateAPI(for: "marking a chat as spam")
    return try await throughMessages {
      try await api.markChatAsSpam(
        ChatSpamRequest(
          chat: ChatIdentifier(guid), reportToCarrier: reportToCarrier, dryRun: dryRun
        )
      )
    }
  }

  public func reportJunk(
    guid: String, reportToCarrier: Bool, dryRun: Bool
  ) async throws -> ChatSpamResult {
    let api = try requirePrivateAPI(for: "reporting a chat as junk")
    return try await throughMessages {
      try await api.reportChatAsJunk(
        ChatSpamRequest(
          chat: ChatIdentifier(guid), reportToCarrier: reportToCarrier, dryRun: dryRun
        )
      )
    }
  }

  public func setFilter(guid: String, category: Int) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "changing a chat's filter")
    guard category >= 0 else {
      throw InterfaceError.invalidRequest("`category` must be zero or greater")
    }
    return try await throughMessages {
      try await api.setChatFilter(chat: ChatIdentifier(guid), category: category)
    }
  }

  public static func serialize(_ state: ChatFilterState) -> JSONValue {
    .object([
      "is_filtered": .int(state.isFiltered),
      "filter_category": .int(state.filterCategory),
      "is_known_sender": .bool(state.isKnownSender),
      "is_in_unknown_senders_filter": .bool(state.isInUnknownSendersFilter),
      "was_detected_as_sms_spam": .bool(state.wasDetectedAsSMSSpam),
      "can_report_junk": .bool(state.canReportJunk),
    ])
  }

  public static func serialize(_ result: ChatSpamResult) -> JSONValue {
    .object([
      "message_count": .int(result.messageCount),
      "reported_to_carrier": .bool(result.reportedToCarrier),
      "dry_run": .bool(result.wasDryRun),
      "filter": serialize(result.filter),
    ])
  }

  /// The mute state as JSON. Epoch milliseconds, per the serializer convention: this is
  /// not a TypeORM entity, so `WireDate.iso` does not apply.
  public static func serialize(_ state: ChatMuteState) -> JSONValue {
    .object([
      "is_muted": .bool(state.isMuted),
      "is_indefinite": .bool(state.isIndefinite),
      "muted_until": state.mutedUntil
        .map { JSONValue.int64(Int64(($0.timeIntervalSince1970 * 1000).rounded())) }
        ?? .null,
    ])
  }

  public func setDisplayName(guid: String, to name: String) async throws {
    let api = try requirePrivateAPI(for: "renaming a chat")
    try await throughMessages { try await api.setDisplayName(chat: ChatIdentifier(guid), to: name) }
  }

  public func setGroupPhoto(guid: String, imagePath: String) async throws {
    let api = try requirePrivateAPI(for: "setting a group photo")
    guard FileManager.default.fileExists(atPath: imagePath) else {
      throw InterfaceError.invalidRequest("no file at \(imagePath)")
    }
    try await throughMessages {
      try await api.updateGroupPhoto(chat: ChatIdentifier(guid), imagePath: imagePath)
    }
  }

  public func addParticipant(_ address: String, to guid: String) async throws {
    let api = try requirePrivateAPI(for: "adding a participant")
    try await throughMessages { try await api.addParticipant(address, to: ChatIdentifier(guid)) }
  }

  public func removeParticipant(_ address: String, from guid: String) async throws {
    let api = try requirePrivateAPI(for: "removing a participant")
    try await throughMessages {
      try await api.removeParticipant(address, from: ChatIdentifier(guid))
    }
  }

  public func setTyping(guid: String, typing: Bool) async throws {
    let api = try requirePrivateAPI(for: "typing indicators")
    try await throughMessages {
      if typing {
        try await api.startTyping(chat: ChatIdentifier(guid))
      } else {
        try await api.stopTyping(chat: ChatIdentifier(guid))
      }
    }
  }

  public func markRead(guid: String) async throws {
    let api = try requirePrivateAPI(for: "marking a chat read")
    try await throughMessages { try await api.markRead(chat: ChatIdentifier(guid)) }
  }

  public func markUnread(guid: String) async throws {
    let api = try requirePrivateAPI(for: "marking a chat unread")
    try await throughMessages { try await api.markUnread(chat: ChatIdentifier(guid)) }
  }

  public func deleteMessage(_ messageGUID: String, in chatGUID: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a message")
    try await throughMessages {
      try await api.deleteMessage(MessageGUID(messageGUID), in: ChatIdentifier(chatGUID))
    }
  }
}

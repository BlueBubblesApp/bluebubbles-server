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
import BBPrivateAPICatalog
import BBPrivateAPIContract
import BBSerialization
import BBShortcuts
import Foundation
import Logging

extension ChatInterface {

  // MARK: - Private-API-only operations

  public func delete(guid: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a chat")
    logChatOperation("Deleting chat", guid: guid)
    try await throughMessages { try await api.deleteChat(ChatIdentifier(guid)) }
  }

  public func leave(guid: String) async throws {
    let api = try requirePrivateAPI(for: "leaving a chat")
    logChatOperation("Leaving chat", guid: guid)
    try await throughMessages { try await api.leaveChat(ChatIdentifier(guid)) }
  }

  public func setPinned(guid: String, pinned: Bool) async throws {
    let api = try requirePrivateAPI(for: "pinning a chat")
    logChatOperation("Pinning chat", guid: guid, extra: ["pinned": .stringConvertible(pinned)])
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
    logChatOperation(
      "Muting chat", guid: guid,
      extra: ["until": .string(until.map { "\($0)" } ?? "indefinite")])
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
    logChatOperation("Unmuting chat", guid: guid)
    return try await throughMessages {
      try await api.unmute(
        chat: ChatIdentifier(guid), syncToPairedDevice: syncToPairedDevice
      )
    }
  }

  /// Conversation backgrounds are macOS 26 and later.
  ///
  /// Gated for the same reason as `checkScreenUnknownSendersSupported`, though this one was
  /// never wrong, only late: `-refetchLocalTranscriptBackgroundAssetIfNecessary` is absent
  /// below 26 and the helper already reported `unavailableOnThisOS` through `translating`.
  /// The refusal now arrives before the request is accepted rather than after, and it names
  /// the release rather than the selector, which is the half a user can act on.
  static func checkChatBackgroundsSupported(majorVersion: Int) throws {
    let capability = PrivateAPICapability.chatBackgrounds
    guard majorVersion >= capability.minimumMacOS else {
      throw InterfaceError.invalidRequest(
        "Conversation backgrounds need "
          + "\(PrivateAPICapability.releaseName(capability.minimumMacOS)) or newer")
    }
  }

  /// Asks Messages to download this conversation's background asset from iCloud.
  ///
  /// **Only the DOWNLOAD is gated, not the reads.** `GET :guid/background` and
  /// `:guid/background/info` serve bytes Messages already cached on disk, need no helper,
  /// and answer "no background" on a release that has none, which is true rather than an
  /// error. `MediaHandlers.requestBackgroundDownload`, the best-effort request the bytes
  /// route makes on the way past, calls this and reads any refusal as "did not ask": below
  /// 26 there is no background to ask for, so `false` is the honest answer there too.
  public func refetchBackground(guid: String) async throws {
    try Self.checkChatBackgroundsSupported(majorVersion: osMajorVersion)
    let api = try requirePrivateAPI(for: "downloading a chat background")
    logChatOperation("Refetching chat background", guid: guid)
    try await throughMessages { try await api.refetchChatBackground(chat: ChatIdentifier(guid)) }
  }

  // MARK: History and filtering

  /// Deletes every message in a conversation. The conversation itself stays.
  ///
  /// Destructive and synced: the messages leave every device on the account. The
  /// confirmation and the user-visible alert live in the handler; this layer does the work.
  public func clearHistory(guid: String) async throws -> Bool {
    let api = try requirePrivateAPI(for: "clearing a chat's history")
    logChatOperation("Clearing chat history", guid: guid)
    return try await throughMessages { try await api.clearChatHistory(ChatIdentifier(guid)) }
  }

  public func filterState(guid: String) async throws -> ChatFilterState {
    let api = try requirePrivateAPI(for: "reading a chat's filter state")
    return try await throughMessages { try await api.chatFilterState(chat: ChatIdentifier(guid)) }
  }

  /// What Messages' own transcript would present for this conversation.
  ///
  /// Read from ChatKit rather than IMCore: `-shouldPresentSpamReasonPicker` is the question
  /// the transcript asks before offering to report a conversation, and no IMCore property
  /// answers it. A client that wants to behave like the Messages window asks this instead of
  /// inferring a banner from a message count that was never about banners.
  public func presentationState(guid: String) async throws -> ChatPresentationState {
    let api = try requirePrivateAPI(for: "reading what Messages would present for a chat")
    return try await throughMessages {
      try await api.chatPresentationState(chat: ChatIdentifier(guid))
    }
  }

  /// Screening unknown senders is macOS 26 and later.
  ///
  /// **The gate is here because without it the route answered 200 and did nothing.**
  /// `-markAsKnownAndSaveInContacts:completion:` does not exist below 26, the helper's
  /// invoke threw, the throw was swallowed, and the unchanged filter state was serialised
  /// as a success. A client on Sonoma asking to accept a sender got the same response it
  /// would get if the call had worked and the flag had simply not moved, which is
  /// indistinguishable from the operation being unsupported. `PollInterface` already gated
  /// its own 26-only feature this way; this one did not, and nothing failed when it did not,
  /// because `screenUnknownSenders.minimumMacOS` was declared and never read.
  static func checkScreenUnknownSendersSupported(majorVersion: Int) throws {
    let capability = PrivateAPICapability.screenUnknownSenders
    guard majorVersion >= capability.minimumMacOS else {
      throw InterfaceError.invalidRequest(
        "Screening unknown senders needs "
          + "\(PrivateAPICapability.releaseName(capability.minimumMacOS)) or newer")
    }
  }

  public func markSenderKnown(
    guid: String, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    try Self.checkScreenUnknownSendersSupported(majorVersion: osMajorVersion)
    let api = try requirePrivateAPI(for: "marking a sender as known")
    logChatOperation("Marking sender known", guid: guid)
    return try await throughMessages {
      try await api.markSenderKnown(chat: ChatIdentifier(guid), saveInContacts: saveInContacts)
    }
  }

  public func markSpam(
    guid: String, reportToCarrier: Bool, dryRun: Bool
  ) async throws -> ChatSpamResult {
    let api = try requirePrivateAPI(for: "marking a chat as spam")
    logChatOperation(
      "Marking chat as spam", guid: guid, extra: ["dryRun": .stringConvertible(dryRun)])
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
    logChatOperation(
      "Reporting chat as junk", guid: guid, extra: ["dryRun": .stringConvertible(dryRun)])
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
    logChatOperation(
      "Setting chat filter", guid: guid, extra: ["category": .stringConvertible(category)])
    guard ChatFilterCategory(rawValue: category) != nil else {
      throw InterfaceError.invalidRequest(
        "`category` must be one of "
          + ChatFilterCategory.allCases.map { "\($0.rawValue) (\($0.label))" }
          .joined(separator: ", ")
      )
    }
    return try await throughMessages {
      try await api.setChatFilter(chat: ChatIdentifier(guid), category: category)
    }
  }

  /// The filter buckets a chat can be moved to.
  ///
  /// **`>= 0` was the only check, and the values above this range are not inert.** IMCore
  /// takes whatever it is given, so a `category: 7` wrote a bucket Messages' own sidebar has
  /// no row for: the conversation left the inbox and appeared nowhere, with a 200 saying it
  /// had worked.
  ///
  /// MEASURED on macOS 26.5.2, reading `filterCategory` through the helper for every chat
  /// this Mac holds: 14 filtered chats answered 0 or 1, and 25 unfiltered ones answered 0.
  /// `2` is junk, which `IMCoreBridge.setChatFilter` already treats specially (leaving it
  /// goes through `recoverFromJunkTo:` rather than `updateIsFiltered:`), and no conversation
  /// here is in it.
  ///
  /// Apple's own sidebar also offers Transactions and Promotions, so a fourth and fifth
  /// bucket may well exist; nothing here has seen one. If a client needs one, the fix is a
  /// measurement — put a conversation in that bucket in Messages and read `filterCategory`
  /// back — not a wider range accepted on the strength of the names.
  public enum ChatFilterCategory: Int, CaseIterable, Sendable {
    case inbox = 0
    case unknownSenders = 1
    case junk = 2

    var label: String {
      switch self {
      case .inbox: "inbox"
      case .unknownSenders: "unknown senders"
      case .junk: "junk"
      }
    }
  }

  /// `filter_category` is ABSENT on a release that cannot read it, macOS 27 among them, for
  /// the reason the presentation state below gives: a client must read a missing key as
  /// "unknown". A 0 there would file every Junk conversation under the inbox.
  public static func serialize(_ state: ChatFilterState) -> JSONValue {
    var object: [String: JSONValue] = [
      "is_filtered": .int(state.isFiltered),
      "is_known_sender": .bool(state.isKnownSender),
      "is_in_unknown_senders_filter": .bool(state.isInUnknownSendersFilter),
      "was_detected_as_sms_spam": .bool(state.wasDetectedAsSMSSpam),
      "can_report_junk": .bool(state.canReportJunk),
    ]
    if let category = state.filterCategory { object["filter_category"] = .int(category) }
    return .object(object)
  }

  /// Absent keys, not false ones. A release that cannot answer omits the field, and a
  /// client must treat a missing key as "unknown" rather than as "no": `false` for
  /// `should_present_spam_reason_picker` hides a control that works.
  public static func serialize(_ state: ChatPresentationState) -> JSONValue {
    var object: [String: JSONValue] = [:]
    if let value = state.shouldPresentSpamReasonPicker {
      object["should_present_spam_reason_picker"] = .bool(value)
    }
    if let value = state.isReportedAsSpam { object["is_reported_as_spam"] = .bool(value) }
    if let value = state.wasDetectedAsSMSSpam {
      object["was_detected_as_sms_spam"] = .bool(value)
    }
    if let value = state.wasDetectedAsSpam { object["was_detected_as_spam"] = .bool(value) }
    if let value = state.isKnownChat { object["is_known_chat"] = .bool(value) }
    if let value = state.completedInitialChatMessagesLoad {
      object["transcript_loaded"] = .bool(value)
    }
    if let value = state.isSMSSpamFilteringEnabled {
      object["sms_spam_filtering_enabled"] = .bool(value)
    }
    return .object(object)
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
        .map { JSONValue.int64($0.epochMilliseconds(rounded: .toNearestOrAwayFromZero)) }
        ?? .null,
    ])
  }

  /// What `update` did: the chat as it reads now, and the fields it applied.
  public struct ChatUpdate: Sendable {
    public let chat: ChatProjection
    /// Wire names of the fields applied, in order. Empty when the request named none.
    public let updatedFields: [String]
  }

  /// A rename asked of a chat that is not a group.
  ///
  /// Its own type rather than an `InterfaceError` because it is a refusal of a particular
  /// kind with a particular pair of sentences, and the HTTP spelling of those is the
  /// reference's (`ChatRenameRefusal+HTTP` in `BBHandlers`).
  public enum RenameRefusal: BBError, Equatable {
    case notAGroup

    public var code: String { "chat.rename_not_a_group" }
    public var domain: String { "Interfaces" }
    public var isUserFacing: Bool { false }
    public var title: String { "That chat cannot be renamed" }
    public var body: String { "Only a group chat can be renamed." }
  }

  /// Applies the fields a chat update names, then reads the chat back.
  ///
  /// READ FIRST, so an update to a chat that does not exist is a "not found" naming the chat
  /// rather than whatever Messages says about a GUID it has never seen. Participants are
  /// loaded both times because they are part of what a caller is handed.
  ///
  /// A rename is refused for a one-to-one chat BEFORE Messages is asked. Measured on macOS
  /// 26.5.2: renaming a one-to-one chat through the helper reported success and did nothing
  /// (`chat.display_name` unchanged, no group-action row, nothing sent), so the refusal takes
  /// away no capability; it replaces a false success.
  ///
  /// - Parameter displayName: the new name, or nil (or empty) to leave it alone.
  public func update(guid: String, displayName: String?) async throws -> ChatUpdate {
    let query = Query(withParticipants: true)
    guard let before = try await find(guid: guid, query: query) else {
      throw InterfaceError.notFound(ReferenceMessages.chatNotFound)
    }

    var updated: [String] = []
    if let displayName, !displayName.isEmpty {
      guard before.participants.count > 1 else { throw RenameRefusal.notAGroup }
      try await setDisplayName(guid: guid, to: displayName)
      updated.append("displayName")
    }

    // Re-read, so the caller holds the name that is now set rather than the one it had.
    guard let after = try await find(guid: guid, query: query) else {
      throw InterfaceError.notFound(ReferenceMessages.chatNotFound)
    }
    return ChatUpdate(chat: after, updatedFields: updated)
  }

  public func setDisplayName(guid: String, to name: String) async throws {
    let api = try requirePrivateAPI(for: "renaming a chat")
    // The new name is what the person typed, and stays out.
    logChatOperation("Renaming chat", guid: guid)
    try await throughMessages { try await api.setDisplayName(chat: ChatIdentifier(guid), to: name) }
  }

  // Each mutation below looks its chat up first, after the Private API gate and before
  // Messages is asked: the reference answers an unknown chat with 404 "Chat does not
  // exist!" on every one of these routes (`chatRouter.ts`), and this server sent the GUID
  // to Messages instead and answered whatever came back, a 500 or a 200.

  public func setGroupPhoto(guid: String, imagePath: String) async throws {
    let api = try requirePrivateAPI(for: "setting a group photo")
    _ = try await row(guid: guid)
    logChatOperation("Setting group photo", guid: guid)
    guard FileManager.default.fileExists(atPath: imagePath) else {
      throw InterfaceError.invalidRequest(
        "the file named by this request is not available; upload it again with "
          + "/api/v1/attachment/upload")
    }
    try await throughMessages {
      try await api.updateGroupPhoto(chat: ChatIdentifier(guid), imagePath: imagePath)
    }
  }

  public func removeGroupPhoto(guid: String) async throws {
    let api = try requirePrivateAPI(for: "removing a group photo")
    _ = try await row(guid: guid)
    logChatOperation("Removing group photo", guid: guid)
    // An empty path is how IMCore is told to clear the photo rather than set one.
    try await throughMessages {
      try await api.updateGroupPhoto(chat: ChatIdentifier(guid), imagePath: "")
    }
  }

  public func addParticipant(_ address: String, to guid: String) async throws {
    let api = try requirePrivateAPI(for: "adding a participant")
    _ = try await row(guid: guid)
    logChatOperation(
      "Adding participant", guid: guid,
      extra: ["address": .string(Redaction.address(address))])
    try await throughMessages { try await api.addParticipant(address, to: ChatIdentifier(guid)) }
  }

  public func removeParticipant(_ address: String, from guid: String) async throws {
    let api = try requirePrivateAPI(for: "removing a participant")
    _ = try await row(guid: guid)
    logChatOperation(
      "Removing participant", guid: guid,
      extra: ["address": .string(Redaction.address(address))])
    try await throughMessages {
      try await api.removeParticipant(address, from: ChatIdentifier(guid))
    }
  }

  public func setTyping(guid: String, typing: Bool) async throws {
    let api = try requirePrivateAPI(for: "typing indicators")
    // Trace: a client sends one of these per keystroke burst.
    logChatOperation(
      "Setting typing indicator", guid: guid, level: .trace,
      extra: ["typing": .stringConvertible(typing)])
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
    logChatOperation("Marking chat read", guid: guid)
    try await throughMessages { try await api.markRead(chat: ChatIdentifier(guid)) }
  }

  /// Announces `read: false` itself, after Messages accepts the change, because nothing else
  /// can: change detection sees `last_read_message_timestamp` only when it rises, and marking
  /// a chat unread leaves it where it was (measured on macOS 27: the last incoming message's
  /// `is_read` went to 0 and the chat's column did not move). The GUID is the one the client
  /// sent, as the reference sends it.
  ///
  /// `markRead` has no counterpart: a read that changes anything moves the column, and change
  /// detection announces it (measured the same way). A mark-read on a chat Messages already
  /// holds as read changes nothing and so announces nothing, where the reference announces
  /// `read: true` regardless. Deliberate: an emit there would duplicate detection's whenever
  /// the read does change something. See `.claude/docs/decisions.md`.
  public func markUnread(guid: String) async throws {
    let api = try requirePrivateAPI(for: "marking a chat unread")
    logChatOperation("Marking chat unread", guid: guid)
    try await throughMessages { try await api.markUnread(chat: ChatIdentifier(guid)) }
    await events?.emit(.chatReadStatusChanged(chatGUID: guid, read: false), rateLimitKey: guid)
  }

  /// One line per chat mutation, on entry. The chat is redacted because a direct chat's
  /// GUID is the other party's address; a display name never appears at all.
  func logChatOperation(
    _ what: String, guid: String, level: Logger.Level = .debug, extra: Logger.Metadata = [:]
  ) {
    var metadata: Logger.Metadata = ["chat": .string(Redaction.chatGUID(guid))]
    metadata.merge(extra) { _, new in new }
    logger.log(level: level, "\(what)", metadata: metadata)
  }

  public func deleteMessage(_ messageGUID: String, in chatGUID: String) async throws {
    let api = try requirePrivateAPI(for: "deleting a message")
    // Both looked up first, as the reference does (`chatRouter.deleteChatMessage`), so an
    // unknown chat or message is its 404 rather than whatever Messages makes of a GUID it
    // has never seen, which reached a client as a 500.
    _ = try await row(guid: chatGUID)
    guard try await repository.message(guid: messageGUID) != nil else {
      throw InterfaceError.notFound(ReferenceMessages.messageNotFound)
    }
    logChatOperation("Deleting message", guid: chatGUID, extra: ["message": .string(messageGUID)])
    try await throughMessages {
      try await api.deleteMessage(MessageGUID(messageGUID), in: ChatIdentifier(chatGUID))
    }
  }
}

//  PrivateAPIClient
//  The typed contract, expressed over whichever transport is connected.
//
//  This is the only place in the server that knows the helper's action names and payload
//  keys. Everything above it calls typed methods; everything below it moves bytes. That split
//  is what lets the legacy Objective-C helper and the Swift one coexist behind one API.
//
//  The action names and field spellings below are the SHIPPING helper's, verbatim —
//  `backwardsCompatibilityMessage`, `selectedMessageGuid`, `ddScan` as 0/1 rather than a
//  boolean. They look inconsistent because they are; they are also the wire, so they are
//  reproduced rather than tidied. The Swift helper will accept exactly these.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Foundation
import Logging

public actor PrivateAPIClient: PrivateAPI {

  private let transport: any PrivateAPITransport
  private let logger: Logger

  public init(
    transport: any PrivateAPITransport,
    logger: Logger = Logger(label: "bluebubbles.privateapi")
  ) {
    self.transport = transport
    self.logger = logger
  }

  public var isConnected: Bool {
    get async { await transport.isConnected }
  }

  public nonisolated var events: AsyncStream<PrivateAPIEvent> {
    // The transport owns the stream; this is a pass-through so callers do not need to
    // know which transport is in play.
    let transport = transport
    return AsyncStream { continuation in
      let task = Task {
        for await event in await transport.events {
          continuation.yield(event)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Messages

  public func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage {
    let payload = WireJSON.object(dropping: [
      "chatGuid": .string(request.chat.rawValue),
      "message": .string(request.text),
      "subject": request.subject.map(WireJSON.string),
      "effectId": request.effectId.map(WireJSON.string),
      "selectedMessageGuid": request.replyTo.map { .string($0.rawValue) },
      "partIndex": .number(Double(request.replyPartIndex ?? 0)),
      // 0/1 rather than a boolean: the helper reads it as a number.
      "ddScan": .number(request.scanForLinks ? 1 : 0),
    ])
    let result = try await transport.request(action: "send-message", data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    let parts = request.parts.map { part in
      WireJSON.object(dropping: [
        "text": part.text.map(WireJSON.string),
        "attachment": part.attachmentPath.map(WireJSON.string),
        "mention": part.mention.map(WireJSON.string),
      ])
    }
    let payload = WireJSON.object(dropping: [
      "chatGuid": .string(request.chat.rawValue),
      "parts": .array(parts),
      "subject": request.subject.map(WireJSON.string),
      "effectId": request.effectId.map(WireJSON.string),
      "selectedMessageGuid": request.replyTo.map { .string($0.rawValue) },
      "partIndex": .number(Double(request.replyPartIndex ?? 0)),
    ])
    let result = try await transport.request(action: "send-multipart", data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    // Checked here, because the helper reports a missing file as a generic failure and
    // the caller then has no idea which path was wrong.
    guard FileManager.default.fileExists(atPath: request.filePath) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "attachment not found at \(request.filePath)"
      )
    }
    let payload = WireJSON.object([
      "chatGuid": .string(request.chat.rawValue),
      "filePath": .string(request.filePath),
      "isAudioMessage": .number(request.isAudioMessage ? 1 : 0),
    ])
    let result = try await transport.request(action: "send-attachment", data: payload)
    return try sentMessage(from: result, chat: request.chat)
  }

  public func react(_ request: ReactionRequest) async throws {
    try await transport.request(
      action: "send-reaction",
      data: .object([
        "chatGuid": .string(request.chat.rawValue),
        "selectedMessageGuid": .string(request.target.rawValue),
        "reactionType": .string(request.reaction.rawValue),
        "partIndex": .number(Double(request.partIndex)),
      ]))
  }

  /// Editing needs the chat, and the helper cannot derive it.
  ///
  /// MEASURED: an `IMMessageItem` retrieved by GUID reports `chatIdentifier = nil`, so
  /// there is nothing on the message to look a conversation up by. The chat-less form of
  /// this call is deliberately absent — it could only ever fail. The server resolves the
  /// chat from chat.db instead, which is authoritative and free.
  public func editMessage(
    _ guid: MessageGUID,
    in chat: ChatIdentifier,
    partIndex: Int,
    newText: String,
    backwardCompatibilityText: String
  ) async throws {
    try await transport.request(
      action: "edit-message",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "messageGuid": .string(guid.rawValue),
        "editedMessage": .string(newText),
        "backwardsCompatibilityMessage": .string(backwardCompatibilityText),
        "partIndex": .number(Double(partIndex)),
      ]))
  }

  public func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int)
    async throws
  {
    try await transport.request(
      action: "unsend-message",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "messageGuid": .string(guid.rawValue),
        "partIndex": .number(Double(partIndex)),
      ]))
  }

  public func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    try await transport.request(
      action: "delete-message",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "messageGuid": .string(guid.rawValue),
      ]))
  }

  public func notifyAnyways(_ guid: MessageGUID) async throws {
    try await transport.request(
      action: "notify-anyways",
      data: .object([
        "messageGuid": .string(guid.rawValue)
      ]))
  }

  public func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    let result = try await transport.request(
      action: "search-messages",
      data: .object([
        "query": .string(request.query),
        "matchType": .string("contains"),
      ]))
    guard let list = result?["results"]?.arrayValue ?? result?.arrayValue else { return [] }
    return list.compactMap(\.stringValue).map { MessageGUID($0) }
  }

  public func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String {
    let result = try await transport.request(
      action: "balloon-bundle-media-path",
      data: .object(["messageGuid": .string(guid.rawValue)])
    )
    guard let path = result?["path"]?.stringValue ?? result?.stringValue else {
      throw PrivateAPIError.rejectedByMessages(reason: "no media path returned")
    }
    return path
  }

  // MARK: - Chats

  public func createChat(
    addresses: [String],
    service: String,
    message: String?
  ) async throws -> ChatIdentifier {
    let result = try await transport.request(
      action: "create-chat",
      data: .object(dropping: [
        "addresses": .array(addresses.map { .string($0) }),
        "service": .string(service),
        "message": message.map(WireJSON.string),
      ]))
    // Named `identifier` on the wire, and it is a MESSAGE guid rather than a chat guid —
    // flagged in the current server as "Yes this is correct". The caller resolves the
    // chat from it through chat.db.
    guard
      let identifier = result?["identifier"]?.stringValue
        ?? result?["chatGuid"]?.stringValue
        ?? result?.stringValue
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "create-chat returned no identifier")
    }
    return ChatIdentifier(identifier)
  }

  public func deleteChat(_ chat: ChatIdentifier) async throws {
    try await chatAction("delete-chat", chat)
  }

  public func leaveChat(_ chat: ChatIdentifier) async throws {
    try await chatAction("leave-chat", chat)
  }

  public func setDisplayName(chat: ChatIdentifier, to name: String) async throws {
    try await transport.request(
      action: "set-display-name",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "newName": .string(name),
      ]))
  }

  public func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws {
    try await transport.request(
      action: "update-group-photo",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "filePath": .string(imagePath),
      ]))
  }

  public func addParticipant(_ address: String, to chat: ChatIdentifier) async throws {
    try await participantAction("add-participant", address: address, chat: chat)
  }

  public func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws {
    try await participantAction("remove-participant", address: address, chat: chat)
  }

  /// Pinning has no route in the Node server, so it reaches the API only through the
  /// additive chat group. The helper action name matches the shipping helper's
  /// (`update-chat-pinned`) so an older helper understands it too.
  public func setPinned(chat: ChatIdentifier, pinned: Bool) async throws {
    try await transport.request(
      action: "update-chat-pinned",
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "pinned": .bool(pinned),
      ]))
  }

  /// The pinned conversations, in display order.
  ///
  /// A NEW action rather than one the shipping Objective-C helper knows — that one only
  /// writes. An older helper answers `notImplemented`, which is the honest result and is why
  /// the route reports the helper's error rather than an empty list: "no pins" and "this
  /// helper cannot tell you" are different answers, and a client syncing pins would treat
  /// the first as instruction to unpin everything.
  public func pinnedChats() async throws -> [ChatIdentifier] {
    let reply = try await transport.request(action: "get-pinned-chats", data: .object([:]))
    return (reply?["chats"]?.arrayValue ?? [])
      .compactMap(\.stringValue)
      .compactMap { ChatIdentifier($0) }
  }

  // MARK: - Mute

  public func muteState(chat: ChatIdentifier) async throws -> ChatMuteState {
    try Self.muteState(
      from: await transport.request(
        action: "get-chat-mute", data: .object(["chatGuid": .string(chat.rawValue)])
      ))
  }

  public func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState {
    let payload = WireJSON.object(dropping: [
      "chatGuid": .string(request.chat.rawValue),
      // OMITTED for an indefinite mute. A null would be read as "no date" by the
      // helper too, but the absence is the contract and a null is a different message.
      "mutedUntil": request.until.map {
        .number(($0.timeIntervalSince1970 * 1000).rounded())
      },
      "syncToPairedDevice": .bool(request.syncToPairedDevice),
    ])
    return try Self.muteState(
      from: await transport.request(
        action: "set-chat-mute", data: payload
      ))
  }

  public func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    try Self.muteState(
      from: await transport.request(
        action: "unmute-chat",
        data: .object([
          "chatGuid": .string(chat.rawValue),
          "syncToPairedDevice": .bool(syncToPairedDevice),
        ])
      ))
  }

  /// A reply with no `isMuted` is a helper that does not know this action — reported as
  /// such rather than decoded into "not muted", which a client would act on by showing the
  /// conversation as unmuted and letting the user "mute" an already-muted chat.
  private static func muteState(from reply: WireJSON?) throws -> ChatMuteState {
    guard let isMuted = reply?["isMuted"]?.boolValue else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "the helper did not report a mute state"
      )
    }
    return ChatMuteState(
      isMuted: isMuted,
      mutedUntil: (reply?["mutedUntil"]?.doubleValue).map {
        Date(timeIntervalSince1970: $0 / 1000)
      },
      isIndefinite: reply?["isIndefinite"]?.boolValue ?? false
    )
  }

  // MARK: - History and filtering

  public func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool {
    let reply = try await transport.request(
      action: "clear-chat-history", data: .object(["chatGuid": .string(chat.rawValue)])
    )
    // An older helper answers nothing at all. Reported as true rather than false: the
    // action reached a helper that did not report "unknown action", so the clear
    // happened — it is the RESULT that is unknown, and claiming nothing was deleted
    // would be a stronger statement than the reply supports.
    return reply?["deleted"]?.boolValue ?? true
  }

  public func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState {
    try Self.filterState(
      from: await transport.request(
        action: "get-chat-filter", data: .object(["chatGuid": .string(chat.rawValue)])
      ))
  }

  public func markSenderKnown(
    chat: ChatIdentifier, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    try Self.filterState(
      from: await transport.request(
        action: "mark-sender-known",
        data: .object([
          "chatGuid": .string(chat.rawValue),
          "saveInContacts": .bool(saveInContacts),
        ])
      ))
  }

  public func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try Self.spamResult(
      from: await transport.request(
        action: "mark-chat-spam", data: Self.spamPayload(request)
      ))
  }

  public func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try Self.spamResult(
      from: await transport.request(
        action: "report-chat-junk", data: Self.spamPayload(request)
      ))
  }

  public func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState {
    try Self.filterState(
      from: await transport.request(
        action: "set-chat-filter",
        data: .object([
          "chatGuid": .string(chat.rawValue),
          "category": .number(Double(category)),
        ])
      ))
  }

  private static func spamPayload(_ request: ChatSpamRequest) -> WireJSON {
    .object([
      "chatGuid": .string(request.chat.rawValue),
      "reportToCarrier": .bool(request.reportToCarrier),
      "dryRun": .bool(request.dryRun),
    ])
  }

  private static func filterState(from reply: WireJSON?) throws -> ChatFilterState {
    guard let reply, reply["isFiltered"] != nil else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "the helper did not report a filter state"
      )
    }
    return ChatFilterState(
      isFiltered: reply["isFiltered"]?.intValue ?? 0,
      filterCategory: reply["filterCategory"]?.intValue ?? 0,
      isKnownSender: reply["isKnownSender"]?.boolValue ?? false,
      isInUnknownSendersFilter: reply["isInUnknownSendersFilter"]?.boolValue ?? false,
      wasDetectedAsSMSSpam: reply["wasDetectedAsSMSSpam"]?.boolValue ?? false,
      canReportJunk: reply["canReportJunk"]?.boolValue ?? false
    )
  }

  private static func spamResult(from reply: WireJSON?) throws -> ChatSpamResult {
    ChatSpamResult(
      messageCount: reply?["messageCount"]?.intValue ?? 0,
      reportedToCarrier: reply?["reportedToCarrier"]?.boolValue ?? false,
      wasDryRun: reply?["dryRun"]?.boolValue ?? false,
      filter: try filterState(from: reply?["filter"])
    )
  }

  // MARK: - Chat background

  public func refetchChatBackground(chat: ChatIdentifier) async throws {
    try await chatAction("refetch-chat-background", chat)
  }

  // MARK: - Presence

  public func startTyping(chat: ChatIdentifier) async throws {
    try await chatAction("start-typing", chat)
  }

  public func stopTyping(chat: ChatIdentifier) async throws {
    try await chatAction("stop-typing", chat)
  }

  public func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool {
    let result = try await transport.request(
      action: "check-typing-status",
      data: .object(["chatGuid": .string(chat.rawValue)])
    )
    return result?["typing"]?.boolValue ?? result?.boolValue ?? false
  }

  public func markRead(chat: ChatIdentifier) async throws {
    try await chatAction("mark-chat-read", chat)
  }

  public func markUnread(chat: ChatIdentifier) async throws {
    try await chatAction("mark-chat-unread", chat)
  }

  // MARK: - Handles

  public func checkIMessageAvailability(address: String) async throws -> Bool {
    try await availability("check-imessage-availability", address: address)
  }

  public func checkFaceTimeAvailability(address: String) async throws -> Bool {
    try await availability("check-facetime-availability", address: address)
  }

  public func checkFocusStatus(address: String) async throws -> String {
    let result = try await transport.request(
      action: "check-focus-status",
      data: .object(["address": .string(address)])
    )
    return result?["status"]?.stringValue ?? result?.stringValue ?? "unknown"
  }

  // MARK: - Account

  public func accountInfo() async throws -> AccountInfo {
    let result = try await transport.request(action: "get-account-info", data: .object([:]))
    return AccountInfo(
      appleId: result?["appleId"]?.stringValue,
      activeAlias: result?["activeAlias"]?.stringValue,
      aliases: result?["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? [],
      vettedAliases: result?["vettedAliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
    )
  }

  public func nicknameInfo(for address: String?) async throws -> NicknameInfo {
    // The key is OMITTED rather than sent as null when there is no address: the helper
    // reads it with `optionalString`, and an explicit null would be indistinguishable from
    // a caller that meant to send one.
    let result = try await transport.request(
      action: "get-nickname-info",
      data: .object(address.map { ["address": .string($0)] } ?? [:])
    )
    return NicknameInfo(
      handle: address ?? result?["handle"]?.stringValue,
      name: result?["name"]?.stringValue,
      hasSharedNickname: result?["hasSharedNickname"]?.boolValue ?? false,
      avatarPath: result?["avatar_path"]?.stringValue
    )
  }

  public func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool {
    let result = try await transport.request(
      action: "should-offer-nickname-sharing",
      data: .object(["chatGuid": .string(chat.rawValue)])
    )
    return result?["shouldOffer"]?.boolValue ?? result?.boolValue ?? false
  }

  public func shareNickname(chat: ChatIdentifier) async throws {
    try await chatAction("share-nickname", chat)
  }

  public func modifyActiveAlias(_ alias: String) async throws {
    try await transport.request(
      action: "modify-active-alias",
      data: .object([
        "alias": .string(alias)
      ]))
  }

  // MARK: - Attachments

  public func downloadPurgedAttachment(guid: String) async throws -> String {
    let result = try await transport.request(
      action: "download-purged-attachment",
      data: .object(["attachmentGuid": .string(guid)])
    )
    guard let path = result?["path"]?.stringValue ?? result?.stringValue else {
      throw PrivateAPIError.rejectedByMessages(reason: "no path returned for the attachment")
    }
    return path
  }

  // MARK: - FindMy
  //
  // The helper answers in the contract's vocabulary, not IMCore's — the narrowing happens
  // inside Messages.app, so a DSID never crosses this socket in the first place. Decoding
  // here is therefore total: every field is one the contract declares.

  public func findMyStatus() async throws -> FindMyStatus {
    let result = try await transport.request(action: "findmy-status", data: .object([:]))
    return Self.status(from: result) ?? .unavailable
  }

  public func findMyFriends() async throws -> [FindMyFriend] {
    let result = try await transport.request(action: "findmy-friends", data: .object([:]))
    return Self.friends(from: result)
  }

  public func refreshFindMyFriends() async throws -> [FindMyFriend] {
    let result = try await transport.request(
      action: "refresh-findmy-friends", data: .object([:])
    )
    return Self.friends(from: result)
  }

  public func refreshFindMyLocation(handle: String) async throws -> FindMyFriend {
    let result = try await transport.request(
      action: "refresh-findmy-location", data: .object(["address": .string(handle)])
    )
    guard let friend = (result?["friend"]).flatMap(Self.friend(from:)) else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "the helper returned no location for \(handle)"
      )
    }
    return friend
  }

  public func requestFindMyLocationShare(handle: String) async throws {
    try await transport.request(
      action: "request-findmy-location-share",
      data: .object(["address": .string(handle)])
    )
  }

  public func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws {
    try await transport.request(
      action: "start-sharing-findmy-location",
      data: .object(dropping: [
        "chatGuid": .string(request.chat.rawValue),
        "address": request.address.map(WireJSON.string),
        "duration": .string(request.duration.rawValue),
      ])
    )
  }

  public func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws {
    try await transport.request(
      action: "stop-sharing-findmy-location",
      data: .object(dropping: [
        "chatGuid": .string(chat.rawValue),
        "address": address.map(WireJSON.string),
      ])
    )
  }

  // MARK: FindMy decoding

  private static func status(from result: WireJSON?) -> FindMyStatus? {
    guard let result, result["backend"] != nil else { return nil }
    let device = result["activeDevice"].map { device in
      FindMyDeviceSummary(
        name: device["name"]?.stringValue,
        isThisDevice: device["isThisDevice"]?.boolValue ?? false
      )
    }
    return FindMyStatus(
      isAvailable: result["available"]?.boolValue ?? false,
      isProvisioned: result["provisioned"]?.boolValue ?? false,
      isRestricted: result["restricted"]?.boolValue ?? false,
      // Defaults to DISABLED when the helper did not say. Every default here is the
      // pessimistic reading on purpose: a client that shows FindMy because a field was
      // missing gets errors, whereas one that hides it gets a feature back as soon as
      // the helper reports properly.
      isSharingDisabled: result["sharingDisabled"]?.boolValue ?? true,
      backend: result["backend"]?.stringValue.flatMap(FindMyBackend.init(rawValue:))
        ?? .none,
      activeDevice: device
    )
  }

  private static func friends(from result: WireJSON?) -> [FindMyFriend] {
    (result?["friends"]?.arrayValue ?? []).compactMap(friend(from:))
  }

  private static func friend(from value: WireJSON) -> FindMyFriend? {
    guard let handle = value["handle"]?.stringValue, !handle.isEmpty else { return nil }
    return FindMyFriend(
      handle: handle,
      isSharingWithMe: value["isSharingWithMe"]?.boolValue ?? false,
      isFollowingMyLocation: value["isFollowingMyLocation"]?.boolValue ?? false,
      location: value["location"].flatMap(location(from:))
    )
  }

  private static func location(from value: WireJSON) -> FindMyLocation {
    FindMyLocation(
      latitude: value["latitude"]?.doubleValue,
      longitude: value["longitude"]?.doubleValue,
      horizontalAccuracy: value["horizontalAccuracy"]?.doubleValue,
      altitude: value["altitude"]?.doubleValue,
      shortAddress: value["shortAddress"]?.stringValue,
      longAddress: value["longAddress"]?.stringValue,
      label: value["label"]?.stringValue,
      // Milliseconds on the wire, seconds in Foundation.
      lastUpdated: value["lastUpdated"]?.doubleValue.map {
        Date(timeIntervalSince1970: $0 / 1000)
      },
      isLocatingInProgress: value["isLocatingInProgress"]?.boolValue ?? false,
      status: value["status"]?.stringValue
        .flatMap(FindMyLocationStatus.init(rawValue:)) ?? .unknown
    )
  }

  // MARK: - FaceTime
  //
  // Action names match the Objective-C helper's where one exists (`generate-link`,
  // `answer-call`, `leave-call`, `admit-pending-member`) so an older FaceTime helper
  // understands them; the new ones (`dial-facetime`, `facetime-members`) are additive. The
  // helper answers in the contract's vocabulary — the narrowing happens in-process.

  public func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink {
    let data: WireJSON =
      invitedAddresses.isEmpty
      ? .object([:])
      : .object(["addresses": .array(invitedAddresses.map(WireJSON.string))])
    let result = try await transport.request(
      action: "generate-link", data: data, process: HelperHost.faceTime
    )
    return try Self.requireLink(from: result)
  }

  public func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink {
    let result = try await transport.request(
      action: "generate-link", data: .object(["callUUID": .string(callUUID)]),
      process: HelperHost.faceTime
    )
    return try Self.requireLink(from: result)
  }

  public func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    let result = try await transport.request(
      action: "dial-facetime",
      data: .object([
        "addresses": .array(request.addresses.map { .string($0) }),
        "video": .bool(request.video),
      ]), process: HelperHost.faceTime)
    guard let call = (result?["call"]).flatMap(Self.call(from:)) ?? Self.call(from: result) else {
      throw PrivateAPIError.rejectedByMessages(reason: "the helper placed no call")
    }
    return call
  }

  public func answerFaceTimeCall(callUUID: String) async throws {
    try await transport.request(
      action: "answer-call", data: .object(["callUUID": .string(callUUID)]),
      process: HelperHost.faceTime
    )
  }

  public func leaveFaceTimeCall(callUUID: String) async throws {
    try await transport.request(
      action: "leave-call", data: .object(["callUUID": .string(callUUID)]),
      process: HelperHost.faceTime
    )
  }

  public func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    try await transport.request(
      action: "admit-pending-member",
      data: .object([
        // Field spellings are the shipping helper's: `conversationUUID` / `handleUUID`.
        "conversationUUID": .string(conversationUUID),
        "handleUUID": .string(handle),
      ]), process: HelperHost.faceTime)
  }

  public func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] {
    let result = try await transport.request(
      action: "facetime-members",
      data: .object(["conversationUUID": .string(conversationUUID)]),
      process: HelperHost.faceTime
    )
    return (result?["members"]?.arrayValue ?? []).compactMap(Self.member(from:))
  }

  public func silenceFaceTimeCall(callUUID: String) async throws -> (
    muted: Bool, sendingVideo: Bool
  ) {
    let result = try await transport.request(
      action: "silence-facetime-call",
      data: .object(["callUUID": .string(callUUID)]),
      process: HelperHost.faceTime
    )
    return (
      muted: result?["muted"]?.boolValue ?? false,
      sendingVideo: result?["sendingVideo"]?.boolValue ?? true
    )
  }

  public func faceTimeActiveCalls() async throws -> [FaceTimeCall] {
    let result = try await transport.request(
      action: "facetime-active-calls", data: .object([:]), process: HelperHost.faceTime
    )
    return (result?["calls"]?.arrayValue ?? []).compactMap(Self.call(from:))
  }

  public func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    let result = try await transport.request(
      action: "facetime-call-status",
      data: .object(["callUUID": .string(callUUID)]),
      process: HelperHost.faceTime
    )
    return FaceTimeCallStatus(raw: result?["callStatus"]?.intValue ?? 0)
  }

  public func faceTimeWindows() async throws -> [String] {
    let result = try await transport.request(
      action: "facetime-windows", data: .object([:]), process: HelperHost.faceTime
    )
    return result?["windows"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  public func dismissFaceTimeAlert() async throws -> Int {
    let result = try await transport.request(
      action: "facetime-dismiss-alert", data: .object([:]), process: HelperHost.faceTime
    )
    return result?["dismissed"]?.intValue ?? 0
  }

  public func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] {
    let result = try await transport.request(
      action: "facetime-debug",
      data: .object(["conversationUUID": .string(conversationUUID)]),
      process: HelperHost.faceTime
    )
    guard case .object(let fields)? = result else { return [:] }
    return fields.compactMapValues(\.stringValue)
  }

  public func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] {
    let data: WireJSON =
      urls.map { list in
        WireJSON.object(["urls": .array(list.map(WireJSON.string))])
      } ?? .object([:])
    let result = try await transport.request(
      action: "invalidate-facetime-links", data: data, process: HelperHost.faceTime
    )
    return result?["invalidated"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }

  // MARK: FaceTime decoding

  private static func requireLink(from result: WireJSON?) throws -> FaceTimeLink {
    // `url` at the top level or under `link` — the helper's older shape puts it at the
    // top, the typed shape nests it.
    guard let link = (result?["link"]).flatMap(link(from:)) ?? link(from: result) else {
      throw PrivateAPIError.rejectedByMessages(reason: "the helper returned no FaceTime link")
    }
    return link
  }

  private static func link(from value: WireJSON?) -> FaceTimeLink? {
    guard let url = value?["url"]?.stringValue, !url.isEmpty else { return nil }
    return FaceTimeLink(
      url: url,
      groupUUID: value?["groupUUID"]?.stringValue ?? value?["group_uuid"]?.stringValue,
      name: value?["name"]?.stringValue,
      expiresAt: value?["expiresAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    )
  }

  private static func call(from value: WireJSON?) -> FaceTimeCall? {
    guard let uuid = value?["callUUID"]?.stringValue ?? value?["call_uuid"]?.stringValue,
      !uuid.isEmpty
    else { return nil }
    return FaceTimeCall(
      callUUID: uuid,
      status: FaceTimeCallStatus(
        raw: value?["callStatus"]?.intValue ?? value?["call_status"]?.intValue ?? 0
      ),
      handle: handle(from: value),
      groupUUID: value?["groupUUID"]?.stringValue,
      isVideo: value?["isVideo"]?.boolValue ?? true,
      callerIDBlocked: value?["callerIDBlocked"]?.boolValue ?? false
    )
  }

  private static func handle(from value: WireJSON?) -> FaceTimeHandle? {
    guard
      let address = value?["handle"]?.stringValue
        ?? value?["address"]?.stringValue, !address.isEmpty
    else { return nil }
    return FaceTimeHandle(value: address, displayName: value?["displayName"]?.stringValue)
  }

  private static func member(from value: WireJSON) -> FaceTimeMember? {
    guard let address = value["handle"]?.stringValue, !address.isEmpty else { return nil }
    return FaceTimeMember(
      handle: FaceTimeHandle(value: address, displayName: value["displayName"]?.stringValue),
      nickname: value["nickname"]?.stringValue,
      isPending: value["isPending"]?.boolValue ?? false,
      isWaitingToBeLetIn: value["isWaitingToBeLetIn"]?.boolValue ?? false,
      joinedFromLetMeIn: value["joinedFromLetMeIn"]?.boolValue ?? false,
      isActive: value["isActive"]?.boolValue,
      isLightweight: value["isLightweight"]?.boolValue ?? false
    )
  }

  // MARK: - Shared shapes

  private func chatAction(_ action: String, _ chat: ChatIdentifier) async throws {
    try await transport.request(
      action: action, data: .object(["chatGuid": .string(chat.rawValue)])
    )
  }

  private func participantAction(_ action: String, address: String, chat: ChatIdentifier)
    async throws
  {
    try await transport.request(
      action: action,
      data: .object([
        "chatGuid": .string(chat.rawValue),
        "address": .string(address),
      ]))
  }

  private func availability(_ action: String, address: String) async throws -> Bool {
    let result = try await transport.request(
      action: action, data: .object(["address": .string(address)])
    )
    return result?["available"]?.boolValue ?? result?.boolValue ?? false
  }

  /// The helper confirms a send with `identifier`, the new message's GUID.
  ///
  /// The authoritative record still arrives through the chat.db change detector; this is
  /// what lets the two be correlated rather than producing a duplicate.
  private func sentMessage(from result: WireJSON?, chat: ChatIdentifier) throws -> SentMessage {
    guard
      let identifier = result?["identifier"]?.stringValue
        ?? result?["guid"]?.stringValue
        ?? result?.stringValue
    else {
      throw PrivateAPIError.rejectedByMessages(reason: "the helper returned no message identifier")
    }
    return SentMessage(guid: MessageGUID(identifier), chat: chat, sentAt: Date())
  }
}

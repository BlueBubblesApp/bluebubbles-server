//  HelperDispatch
//  Wire action -> IMCoreBridge method.
//
//  The mirror image of PrivateAPIClient on the server: that one turns typed calls into
//  actions, this one turns actions back into typed calls. Keeping both sides mechanical means
//  the only place a field name is spelled is here and there, and the contract module keeps
//  them from drifting in shape.
//
//  Every action the shipping Objective-C helper answers is listed, including the ones not yet
//  ported. An unported action reports `notImplemented` with its own name — distinct from an
//  UNKNOWN action, which is a protocol mismatch and says so. The server treats those
//  differently, and conflating them would make a version skew look like a missing feature.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Foundation
import HelperShared

enum HelperDispatch {

  /// Runs one request and returns its payload, if any.
  /// `@MainActor`, because everything it calls talks to IMCore and IMCore traps off the
  /// main thread. Stating it here means the hop happens ONCE per request, at the boundary,
  /// rather than being re-derived inside every call — and `await` suspends the caller's
  /// task rather than blocking its thread.
  @MainActor
  static func perform(
    _ request: HelperProtocol.Request,
    on bridge: IMCoreBridge = .shared
  ) async throws -> [String: Any]? {
    let data = request.data ?? [:]

    func string(_ key: String) throws -> String {
      guard let value = data[key]?.stringValue else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "\(request.action) requires '\(key)'"
        )
      }
      return value
    }
    func optionalString(_ key: String) -> String? { data[key]?.stringValue }
    func chat(_ key: String = "chatGuid") throws -> ChatIdentifier {
      ChatIdentifier(try string(key))
    }
    func message(_ key: String = "messageGuid") throws -> MessageGUID {
      MessageGUID(try string(key))
    }
    func integer(_ key: String, default fallback: Int = 0) -> Int {
      data[key]?.intValue ?? fallback
    }
    func flag(_ key: String) -> Bool { data[key]?.boolValue ?? false }
    /// `textFormatting`: `[{start, length, styles: [String], effect: String?}]`. An entry
    /// missing its range, or naming a style or effect this helper does not know, is
    /// dropped here; the server validated the shape before sending, so a mismatch means
    /// a version skew, and a message sent without one run's style is better than one not
    /// sent at all.
    func formatting(_ value: WireJSON?) -> [FormattedRange] {
      (value?.arrayValue ?? []).compactMap { entry -> FormattedRange? in
        guard let start = entry["start"]?.intValue, let length = entry["length"]?.intValue
        else { return nil }
        let styles = (entry["styles"]?.arrayValue ?? [])
          .compactMap(\.stringValue).compactMap(TextStyle.init(rawValue:))
        let effect = entry["effect"]?.stringValue.flatMap(TextEffect.init(rawValue:))
        guard !styles.isEmpty || effect != nil else { return nil }
        return FormattedRange(start: start, length: length, styles: styles, effect: effect)
      }
    }

    guard let action = MessagesHelperAction(rawValue: request.action) else {
      // A protocol mismatch, not a missing feature: this helper has never heard of the
      // action. Reported distinctly so a version skew does not look like a bug.
      throw PrivateAPIError.rejectedByMessages(
        reason: "unknown action '\(request.action)'"
      )
    }

    switch action {

    // MARK: Messages

    case .sendMessage:
      let sent = try await bridge.sendMessage(
        SendMessageRequest(
          chat: try chat(),
          text: try string("message"),
          subject: optionalString("subject"),
          effectId: optionalString("effectId"),
          replyTo: optionalString("selectedMessageGuid").map(MessageGUID.init(_:)),
          replyPartIndex: data["partIndex"]?.intValue,
          scanForLinks: flag("ddScan"),
          formatting: formatting(data["textFormatting"]),
          // Epoch MILLISECONDS, the unit every date on this wire uses.
          scheduledFor: data["scheduledFor"]?.doubleValue.map {
            Date(timeIntervalSince1970: $0 / 1000)
          }
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .sendMultipart:
      let parts = (data["parts"]?.arrayValue ?? []).map { part -> MessagePart in
        guard case .object(let fields) = part else { return MessagePart() }
        return MessagePart(
          text: fields["text"]?.stringValue,
          attachmentPath: fields["attachment"]?.stringValue,
          mention: fields["mention"]?.stringValue,
          formatting: formatting(fields["textFormatting"])
        )
      }
      let sent = try await bridge.sendMultipart(
        SendMultipartRequest(
          chat: try chat(),
          parts: parts,
          subject: optionalString("subject"),
          effectId: optionalString("effectId"),
          replyTo: optionalString("selectedMessageGuid").map(MessageGUID.init(_:)),
          replyPartIndex: data["partIndex"]?.intValue
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .sendAttachment:
      let sent = try await bridge.sendAttachment(
        SendAttachmentRequest(
          chat: try chat(),
          filePath: try string("filePath"),
          isAudioMessage: flag("isAudioMessage")
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .sendSticker:
      func number(_ key: String) -> Double? { data[key]?.doubleValue }
      var placement = StickerPlacement.centered
      if let x = number("xScalar") { placement.xScalar = x }
      if let y = number("yScalar") { placement.yScalar = y }
      if let scale = number("scale") { placement.scale = scale }
      if let rotation = number("rotation") { placement.rotation = rotation }
      if let width = number("parentPreviewWidth") { placement.parentPreviewWidth = width }
      let sent = try await bridge.sendSticker(
        SendStickerRequest(
          chat: try chat(),
          filePath: try string("filePath"),
          target: try message("selectedMessageGuid"),
          partIndex: integer("partIndex"),
          placement: placement
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .createPoll:
      let sent = try await bridge.createPoll(
        PollCreateRequest(
          chat: try chat(),
          title: optionalString("title") ?? "",
          options: (data["options"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .updatePoll:
      let options = (data["options"]?.arrayValue ?? []).compactMap { entry -> PollOptionSpec? in
        guard let id = entry["id"]?.stringValue, let text = entry["text"]?.stringValue else {
          return nil
        }
        return PollOptionSpec(
          id: id, text: text, creatorHandle: entry["creatorHandle"]?.stringValue,
          canBeEdited: entry["canBeEdited"]?.boolValue ?? false)
      }
      let sent = try await bridge.updatePoll(
        PollUpdateRequest(
          chat: try chat(), rootGUID: try message("rootGuid"), sessionID: try string("sessionId"),
          title: optionalString("title") ?? "", creatorHandle: optionalString("creatorHandle"),
          options: options))
      return ["identifier": sent.guid.rawValue]

    case .votePoll:
      let sent = try await bridge.votePoll(
        PollVoteRequest(
          chat: try chat(),
          stateGUID: try message("stateGuid"),
          sessionID: try string("sessionId"),
          optionIDs: (data["optionIds"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
      )
      return ["identifier": sent.guid.rawValue]

    case .cancelScheduledMessage:
      try await bridge.cancelScheduledMessage(try message("messageGuid"), in: try chat())
      return nil

    case .sendReaction:
      guard let reaction = ReactionType(rawValue: try string("reactionType")) else {
        throw PrivateAPIError.rejectedByMessages(reason: "unknown reaction type")
      }
      let reacted = try await bridge.react(
        ReactionRequest(
          chat: try chat(),
          target: try message("selectedMessageGuid"),
          reaction: reaction,
          partIndex: integer("partIndex"),
          // The Objective-C helper's own key for it.
          emoji: optionalString("reactionEmoji")
        )
      )
      return ["identifier": reacted.guid.rawValue]

    case .editMessage:
      try await bridge.editMessage(
        try message(),
        in: try chat(),
        partIndex: integer("partIndex"),
        newText: try string("editedMessage"),
        backwardCompatibilityText: try string("backwardsCompatibilityMessage")
      )
      return nil

    case .unsendMessage:
      try await bridge.unsendMessage(
        try message(), in: try chat(), partIndex: integer("partIndex")
      )
      return nil

    case .deleteMessage:
      try await bridge.deleteMessage(try message(), in: try chat())
      return nil

    case .notifyAnyways:
      try await bridge.notifyAnyways(try message(), in: try chat())
      return nil

    case .searchMessages:
      let results = try await bridge.searchMessages(
        MessageSearchRequest(query: try string("query"), limit: data["limit"]?.intValue)
      )
      return ["results": results.map(\.rawValue)]

    case .balloonBundleMediaPath:
      return ["path": try await bridge.balloonBundleMediaPath(for: try message())]

    // MARK: Chats

    case .createChat:
      let addresses = (data["addresses"]?.arrayValue ?? []).compactMap(\.stringValue)
      let created = try await bridge.createChat(
        addresses: addresses,
        service: optionalString("service") ?? "iMessage",
        message: optionalString("message")
      )
      return ["identifier": created.rawValue]

    case .deleteChat:
      try await bridge.deleteChat(try chat())
      return nil

    case .leaveChat:
      try await bridge.leaveChat(try chat())
      return nil

    case .setDisplayName:
      try await bridge.setDisplayName(chat: try chat(), to: try string("newName"))
      return nil

    case .updateGroupPhoto:
      try await bridge.updateGroupPhoto(chat: try chat(), imagePath: try string("filePath"))
      return nil

    case .addParticipant:
      try await bridge.addParticipant(try string("address"), to: try chat())
      return nil

    case .removeParticipant:
      try await bridge.removeParticipant(try string("address"), from: try chat())
      return nil

    case .updateChatPinned:
      try await bridge.setPinned(chat: try chat(), pinned: flag("pinned"))
      return nil

    // An ARRAY, because pins render in this order and a client syncing them has to keep
    // it. Wrapped in an object rather than returned bare so the reply can grow a field
    // later without becoming a different type.
    case .getPinnedChats:
      return ["chats": try await bridge.pinnedChats().map(\.rawValue)]

    // MARK: Mute
    //
    // Milliseconds on the wire, matching every other timestamp on this protocol. An
    // ABSENT `mutedUntil` means indefinitely — which is not the same as sending a null,
    // and is why the key is read with `map` rather than defaulted.

    case .getChatMute:
      return encode(try await bridge.muteState(chat: try chat()))

    case .setChatMute:
      let until = data["mutedUntil"]?.intValue
        .map { Date(timeIntervalSince1970: Double($0) / 1000) }
      return encode(
        try await bridge.setMute(
          ChatMuteRequest(
            chat: try chat(),
            until: until,
            // Defaults to TRUE, so a client that does not think about it gets the
            // behaviour Messages' own UI has.
            syncToPairedDevice: data["syncToPairedDevice"]?.boolValue ?? true
          )
        ))

    case .unmuteChat:
      return encode(
        try await bridge.unmute(
          chat: try chat(),
          syncToPairedDevice: data["syncToPairedDevice"]?.boolValue ?? true
        ))

    // MARK: History and filtering

    case .clearChatHistory:
      return ["deleted": try await bridge.clearChatHistory(try chat())]

    case .getChatFilter:
      return encode(try await bridge.chatFilterState(chat: try chat()))

    case .markSenderKnown:
      return encode(
        try await bridge.markSenderKnown(
          chat: try chat(), saveInContacts: flag("saveInContacts")
        ))

    case .markChatSpam:
      return encode(
        try await bridge.markChatAsSpam(
          ChatSpamRequest(
            chat: try chat(),
            reportToCarrier: flag("reportToCarrier"),
            dryRun: flag("dryRun")
          )
        ))

    case .reportChatJunk:
      return encode(
        try await bridge.reportChatAsJunk(
          ChatSpamRequest(
            chat: try chat(),
            reportToCarrier: flag("reportToCarrier"),
            dryRun: flag("dryRun")
          )
        ))

    case .setChatFilter:
      guard let category = data["category"]?.intValue else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "set-chat-filter requires 'category'"
        )
      }
      return encode(try await bridge.setChatFilter(chat: try chat(), category: category))

    // MARK: Chat background

    case .refetchChatBackground:
      try await bridge.refetchChatBackground(chat: try chat())
      return nil

    // MARK: Presence

    case .startTyping:
      try await bridge.startTyping(chat: try chat())
      return nil

    case .stopTyping:
      try await bridge.stopTyping(chat: try chat())
      return nil

    case .checkTypingStatus:
      return ["typing": try await bridge.checkTypingStatus(chat: try chat())]

    case .markChatRead:
      try await bridge.markRead(chat: try chat())
      return nil

    case .markChatUnread:
      try await bridge.markUnread(chat: try chat())
      return nil

    // MARK: Handles

    case .checkIMessageAvailability:
      return [
        "available": try await bridge.checkIMessageAvailability(
          address: try string("address")
        )
      ]

    case .checkFaceTimeAvailability:
      return [
        "available": try await bridge.checkFaceTimeAvailability(
          address: try string("address")
        )
      ]

    case .checkFocusStatus:
      return ["status": try await bridge.checkFocusStatus(address: try string("address"))]

    // MARK: Account

    case .getAccountInfo:
      let info = try await bridge.accountInfo()
      return [
        "appleId": info.appleId as Any,
        "activeAlias": info.activeAlias as Any,
        "aliases": info.aliases,
        "vettedAliases": info.vettedAliases,
      ].compactMapValues { $0 is NSNull ? nil : $0 }

    case .getNicknameInfo:
      // OPTIONAL, deliberately. An absent address means the local user's own contact card,
      // which is the default form of `GET /api/v1/icloud/contact` and the one the
      // reference server's fixture records. Requiring the key would turn that into a 400.
      let info = try await bridge.nicknameInfo(for: optionalString("address"))
      return [
        "handle": info.handle as Any,
        "name": info.name as Any,
        "hasSharedNickname": info.hasSharedNickname,
        "avatar_path": info.avatarPath as Any,
      ].compactMapValues { $0 is NSNull ? nil : $0 }

    case .shouldOfferNicknameSharing:
      return ["shouldOffer": try await bridge.shouldOfferNicknameSharing(chat: try chat())]

    case .shareNickname:
      try await bridge.shareNickname(chat: try chat())
      return nil

    case .modifyActiveAlias:
      try await bridge.modifyActiveAlias(try string("alias"))
      return nil

    // MARK: Attachments and FindMy

    case .downloadPurgedAttachment:
      return [
        "path": try await bridge.downloadPurgedAttachment(
          guid: try string("attachmentGuid")
        )
      ]

    // MARK: FindMy
    //
    // Each reply is the CONTRACT's shape, encoded here rather than IMCore's. That is the
    // narrowing described in BBPrivateAPIContract/FindMy.swift: a DSID or a hashed DSID
    // would travel just as easily and identifies an Apple account, so it never leaves
    // this process.

    case .findMyStatus:
      return encode(try await bridge.findMyStatus())

    case .findMyFriends:
      return ["friends": try await bridge.findMyFriends().map(encode)]

    case .refreshFindMyFriends:
      return ["friends": try await bridge.refreshFindMyFriends().map(encode)]

    case .refreshFindMyLocation:
      return [
        "friend": encode(
          try await bridge.refreshFindMyLocation(handle: try string("address"))
        )
      ]

    case .requestFindMyLocationShare:
      try await bridge.requestFindMyLocationShare(handle: try string("address"))
      return nil

    case .startSharingFindMyLocation:
      let requestedDuration = try string("duration")
      guard let duration = FindMyShareDuration(rawValue: requestedDuration) else {
        throw PrivateAPIError.rejectedByMessages(
          reason: "unknown share duration '\(requestedDuration)'; expected one of "
            + FindMyShareDuration.allCases.map(\.rawValue).joined(separator: ", ")
        )
      }
      try await bridge.startSharingFindMyLocation(
        FindMyShareRequest(
          chat: try chat(), address: optionalString("address"), duration: duration
        )
      )
      return nil

    case .stopSharingFindMyLocation:
      try await bridge.stopSharingFindMyLocation(
        chat: try chat(), address: optionalString("address")
      )
      return nil

    }
  }

  // MARK: - FindMy encoding
  //
  // Hand-written rather than `JSONEncoder`, because the reply is a `[String: Any]` the
  // socket client serialises itself — there is no Encodable path through it. Keys are the
  // wire's, and `PrivateAPIClient` reads exactly these.

  /// A dictionary without its nil values.
  ///
  /// An absent key and a null are different answers here: no coordinates yet is not the
  /// same as a coordinate of null, and a client that renders a pin has to tell them apart.
  private static func compacting(_ fields: [String: Any?]) -> [String: Any] {
    fields.compactMapValues { $0 }
  }

  /// `mutedUntil` is OMITTED for an indefinite mute rather than sent as the year 4001.
  /// A client showing "muted until <date>" would otherwise render a sentinel as a date.
  private static func encode(_ state: ChatMuteState) -> [String: Any] {
    compacting([
      "isMuted": state.isMuted,
      "isIndefinite": state.isIndefinite,
      "mutedUntil": state.mutedUntil.map {
        Int(($0.timeIntervalSince1970 * 1000).rounded())
      },
    ])
  }

  private static func encode(_ state: ChatFilterState) -> [String: Any] {
    [
      "isFiltered": state.isFiltered,
      "filterCategory": state.filterCategory,
      "isKnownSender": state.isKnownSender,
      "isInUnknownSendersFilter": state.isInUnknownSendersFilter,
      "wasDetectedAsSMSSpam": state.wasDetectedAsSMSSpam,
      "canReportJunk": state.canReportJunk,
    ]
  }

  private static func encode(_ result: ChatSpamResult) -> [String: Any] {
    [
      "messageCount": result.messageCount,
      "reportedToCarrier": result.reportedToCarrier,
      "dryRun": result.wasDryRun,
      "filter": encode(result.filter),
    ]
  }

  private static func encode(_ status: FindMyStatus) -> [String: Any] {
    compacting([
      "available": status.isAvailable,
      "provisioned": status.isProvisioned,
      "restricted": status.isRestricted,
      "sharingDisabled": status.isSharingDisabled,
      "backend": status.backend.rawValue,
      "activeDevice": status.activeDevice.map { device in
        compacting(["name": device.name, "isThisDevice": device.isThisDevice])
      },
    ])
  }

  private static func encode(_ friend: FindMyFriend) -> [String: Any] {
    compacting([
      "handle": friend.handle,
      "isSharingWithMe": friend.isSharingWithMe,
      "isFollowingMyLocation": friend.isFollowingMyLocation,
      "location": friend.location.map(encode),
    ])
  }

  private static func encode(_ location: FindMyLocation) -> [String: Any] {
    compacting([
      // Emitted only when there IS a fix. IMCore reports an unlocated friend at the
      // origin rather than as nil, and a client that trusts that drops a pin in the
      // Gulf of Guinea — so the check is here, once, rather than in every client.
      "latitude": location.hasCoordinates ? location.latitude : nil,
      "longitude": location.hasCoordinates ? location.longitude : nil,
      "horizontalAccuracy": location.horizontalAccuracy,
      "altitude": location.altitude,
      "shortAddress": location.shortAddress,
      "longAddress": location.longAddress,
      "label": location.label,
      // Milliseconds since the epoch, matching every other timestamp on this wire.
      "lastUpdated": location.lastUpdated.map {
        Int(($0.timeIntervalSince1970 * 1000).rounded())
      },
      "isLocatingInProgress": location.isLocatingInProgress,
      "status": location.status.rawValue,
    ])
  }

  /// Error text for the wire.
  ///
  /// The server's `failureReason` treats an empty string as SUCCESS, so this must never
  /// return one — an unhelpful message beats a failure that silently reads as a success.
  static func describe(_ error: any Error) -> String {
    switch error {
    case PrivateAPIError.notImplemented(let method):
      "not implemented in this helper: \(method)"
    case PrivateAPIError.unavailableOnThisOS(let method, let requires):
      "\(method) is unavailable on this macOS version (requires \(requires))"
    case PrivateAPIError.rejectedByMessages(let reason):
      reason.isEmpty ? "rejected by Messages" : reason
    case PrivateAPIError.notConnected:
      "the helper is not connected to Messages"
    case PrivateAPIError.timedOut(let method):
      "\(method) timed out"
    default:
      String(describing: error)
    }
  }
}

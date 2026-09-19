//  HelperDispatch
//  Wire action -> IMCoreBridge method.
//
//  The mirror image of PrivateAPIClient on the server: that one turns typed calls into
//  actions, this one turns actions back into typed calls. Keeping both sides mechanical means
//  the only place a field name is spelled is here and there, and the contract module keeps
//  them from drifting in shape.
//
//  The switch below is exhaustive and one line per action. Each line hands the request to a
//  role's file (`HelperDispatch+Sending`, `+Chats`, `+FindMy` and so on) mirroring the roles
//  `PrivateAPI` is split into, so the contract, the bridge and the dispatch all divide the
//  same way.
//
//  Every action the shipping Objective-C helper answers is listed, including the ones not yet
//  ported. An unported action reports `notImplemented` with its own name, distinct from an
//  UNKNOWN action, which is a protocol mismatch and says so. The server treats those
//  differently, and conflating them would make a version skew look like a missing feature.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Foundation
import HelperShared

enum HelperDispatch {

  /// One request's payload, read by typed key.
  ///
  /// Every accessor names the field it wants and says which one is missing when it is not
  /// there, so a refusal reads "send-message requires 'chatGuid'" rather than surfacing as
  /// a nil somewhere later. The optional readers default, because for those fields absence
  /// is a meaning of its own; see `WireKey`.
  struct RequestData {
    let action: String
    private let fields: [String: WireJSON]

    init(_ request: HelperProtocol.Request) {
      action = request.action
      fields = request.data ?? [:]
    }

    subscript(key: WireKey) -> WireJSON? { fields[key] }

    func string(_ key: WireKey) throws -> String {
      guard let value = fields[key]?.stringValue else {
        throw PrivateAPIError.rejectedByMessages(reason: "\(action) requires '\(key)'")
      }
      return value
    }

    func optionalString(_ key: WireKey) -> String? { fields[key]?.stringValue }

    func chat(_ key: WireKey = .chatGuid) throws -> ChatIdentifier {
      ChatIdentifier(try string(key))
    }

    func message(_ key: WireKey = .messageGuid) throws -> MessageGUID {
      MessageGUID(try string(key))
    }

    func integer(_ key: WireKey, default fallback: Int = 0) -> Int {
      fields[key]?.intValue ?? fallback
    }

    func flag(_ key: WireKey) -> Bool { fields[key]?.boolValue ?? false }

    func double(_ key: WireKey) -> Double? { fields[key]?.doubleValue }

    /// `textFormatting`: `[{start, length, styles: [String], effect: String?}]`. An entry
    /// missing its range, or naming a style or effect this helper does not know, is
    /// dropped here; the server validated the shape before sending, so a mismatch means
    /// a version skew, and a message sent without one run's style is better than one not
    /// sent at all.
    func formatting(_ value: WireJSON?) -> [FormattedRange] {
      (value?.arrayValue ?? []).compactMap { entry -> FormattedRange? in
        guard let start = entry[.start]?.intValue, let length = entry[.length]?.intValue
        else { return nil }
        let styles = (entry[.styles]?.arrayValue ?? [])
          .compactMap(\.stringValue).compactMap(TextStyle.init(rawValue:))
        let effect = entry[.effect]?.stringValue.flatMap(TextEffect.init(rawValue:))
        guard !styles.isEmpty || effect != nil else { return nil }
        return FormattedRange(start: start, length: length, styles: styles, effect: effect)
      }
    }
  }

  /// Runs one request and returns its payload, if any.
  /// `@MainActor`, because everything it calls talks to IMCore and IMCore traps off the
  /// main thread. Stating it here means the hop happens ONCE per request, at the boundary,
  /// rather than being re-derived inside every call, and `await` suspends the caller's
  /// task rather than blocking its thread.
  @MainActor
  static func perform(
    _ request: HelperProtocol.Request,
    on bridge: IMCoreBridge = .shared
  ) async throws -> WireObject? {
    guard let action = MessagesHelperAction(rawValue: request.action) else {
      // A protocol mismatch, not a missing feature: this helper has never heard of the
      // action. Reported distinctly so a version skew does not look like a bug.
      throw PrivateAPIError.rejectedByMessages(
        reason: "unknown action '\(request.action)'"
      )
    }
    let data = RequestData(request)

    switch action {
    // MARK: Sending
    case .sendMessage: return try await sendMessage(data, on: bridge)
    case .sendMultipart: return try await sendMultipart(data, on: bridge)
    case .sendAppMessage: return try await sendAppMessage(data, on: bridge)
    case .sendAttachment: return try await sendAttachment(data, on: bridge)
    case .sendReaction: return try await sendReaction(data, on: bridge)

    // MARK: Stickers
    case .sendSticker: return try await sendSticker(data, on: bridge)
    case .saveSticker: return try await saveSticker(data, on: bridge)

    // MARK: Polls
    case .createPoll: return try await createPoll(data, on: bridge)
    case .updatePoll: return try await updatePoll(data, on: bridge)
    case .votePoll: return try await votePoll(data, on: bridge)

    // MARK: Scheduling
    case .editScheduledMessage: return try await editScheduledMessage(data, on: bridge)
    case .rescheduleMessage: return try await rescheduleMessage(data, on: bridge)
    case .sendScheduledNow: return try await sendScheduledNow(data, on: bridge)
    case .cancelScheduledMessage: return try await cancelScheduledMessage(data, on: bridge)

    // MARK: Messages
    case .editMessage: return try await editMessage(data, on: bridge)
    case .unsendMessage: return try await unsendMessage(data, on: bridge)
    case .deleteMessage: return try await deleteMessage(data, on: bridge)
    case .notifyAnyways: return try await notifyAnyways(data, on: bridge)
    case .searchMessages: return try await searchMessages(data, on: bridge)
    case .balloonBundleMediaPath: return try await balloonBundleMediaPath(data, on: bridge)

    // MARK: Chats
    case .createChat: return try await createChat(data, on: bridge)
    case .deleteChat: return try await deleteChat(data, on: bridge)
    case .leaveChat: return try await leaveChat(data, on: bridge)
    case .setDisplayName: return try await setDisplayName(data, on: bridge)
    case .updateGroupPhoto: return try await updateGroupPhoto(data, on: bridge)
    case .addParticipant: return try await addParticipant(data, on: bridge)
    case .removeParticipant: return try await removeParticipant(data, on: bridge)
    case .updateChatPinned: return try await updateChatPinned(data, on: bridge)
    case .getPinnedChats: return try await getPinnedChats(data, on: bridge)
    case .refetchChatBackground: return try await refetchChatBackground(data, on: bridge)

    // MARK: Muting
    case .getChatMute: return try await getChatMute(data, on: bridge)
    case .setChatMute: return try await setChatMute(data, on: bridge)
    case .unmuteChat: return try await unmuteChat(data, on: bridge)

    // MARK: Filtering
    case .clearChatHistory: return try await clearChatHistory(data, on: bridge)
    case .getChatFilter: return try await getChatFilter(data, on: bridge)
    case .markSenderKnown: return try await markSenderKnown(data, on: bridge)
    case .markChatSpam: return try await markChatSpam(data, on: bridge)
    case .reportChatJunk: return try await reportChatJunk(data, on: bridge)
    case .setChatFilter: return try await setChatFilter(data, on: bridge)

    // MARK: Presence
    case .startTyping: return try await startTyping(data, on: bridge)
    case .stopTyping: return try await stopTyping(data, on: bridge)
    case .checkTypingStatus: return try await checkTypingStatus(data, on: bridge)
    case .markChatRead: return try await markChatRead(data, on: bridge)
    case .markChatUnread: return try await markChatUnread(data, on: bridge)

    // MARK: Identity
    case .checkIMessageAvailability: return try await checkIMessageAvailability(data, on: bridge)
    case .checkFaceTimeAvailability: return try await checkFaceTimeAvailability(data, on: bridge)
    case .checkFocusStatus: return try await checkFocusStatus(data, on: bridge)
    case .getAccountInfo: return try await getAccountInfo(data, on: bridge)
    case .getNicknameInfo: return try await getNicknameInfo(data, on: bridge)
    case .shouldOfferNicknameSharing: return try await shouldOfferNicknameSharing(data, on: bridge)
    case .shareNickname: return try await shareNickname(data, on: bridge)
    case .modifyActiveAlias: return try await modifyActiveAlias(data, on: bridge)

    // MARK: Attachments
    case .downloadPurgedAttachment: return try await downloadPurgedAttachment(data, on: bridge)

    // MARK: FindMy
    case .findMyStatus: return try await findMyStatus(data, on: bridge)
    case .findMyFriends: return try await findMyFriends(data, on: bridge)
    case .refreshFindMyFriends: return try await refreshFindMyFriends(data, on: bridge)
    case .refreshFindMyLocation: return try await refreshFindMyLocation(data, on: bridge)
    case .requestFindMyLocationShare: return try await requestFindMyLocationShare(data, on: bridge)
    case .startSharingFindMyLocation: return try await startSharingFindMyLocation(data, on: bridge)
    case .stopSharingFindMyLocation: return try await stopSharingFindMyLocation(data, on: bridge)

    }
  }

  /// Error text for the wire. See `PrivateAPIError.wireDescription(of:app:)` for the rule
  /// it has to keep; never an empty string.
  static func describe(_ error: any Error) -> String {
    PrivateAPIError.wireDescription(of: error, app: "Messages")
  }
}

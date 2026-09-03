//  FailingPrivateAPI
//  A helper that refuses everything, so the interfaces layer can be driven without one.
//
//  `PrivateAPI` has sixty-eight members and no default implementations, which is why nothing
//  in this package had a fake for it and why every Private-API path went untested. It is
//  cheaper than it looks: every member is `async throws`, so every body here is `throw error`
//  and NO return value has to be constructed — not one `ChatMuteState`, not one
//  `FaceTimeCall`. That is the whole trick, and it is what makes exhaustive coverage of
//  `ChatInterface`'s twenty-three operations a loop rather than twenty-three fixtures.
//
//  Deliberately not selective: an operation that forgets to route through `throughMessages`
//  fails the test that walks all of them, which is the failure mode a hand-picked stub would
//  miss.

import BBPrivateAPIContract
import Foundation

struct FailingPrivateAPI: PrivateAPI {

  /// What every call throws. `PrivateAPIError` is what the real client raises, so this is the
  /// error the translation actually has to cope with.
  let error: any Error

  /// The three mutating operations, allowed to SUCCEED and to have a side effect.
  ///
  /// `edit`, `unsend` and `notify` wait for a column on an existing row to move, so testing
  /// that wait needs a helper that both returns and changes something. Three closures on this
  /// double rather than a second, succeeding conformance to a sixty-eight-member protocol:
  /// the alternative is another file of `throw error` lines that has to be kept in step with
  /// this one.
  var onEdit: (@Sendable () async throws -> Void)?
  var onUnsend: (@Sendable () async throws -> Void)?
  var onNotify: (@Sendable () async throws -> Void)?

  init(error: any Error = PrivateAPIError.rejectedByMessages(reason: "Messages said no")) {
    self.error = error
  }

  /// True, so a caller that gates on connectedness proceeds and reaches the failure. A fake
  /// that reported itself disconnected would test the gate instead of the translation.
  var isConnected: Bool { get async { true } }

  var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }

  func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage { throw error }
  func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage { throw error }
  func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage { throw error }
  func react(_ request: ReactionRequest) async throws -> SentMessage { throw error }
  func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw error
  }
  func rescheduleMessage(_ guid: MessageGUID, in chat: ChatIdentifier, to date: Date) async throws {
    throw error
  }
  func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws {
    throw error
  }
  func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw error
  }
  func createPoll(_ request: PollCreateRequest) async throws -> SentMessage { throw error }
  func votePoll(_ request: PollVoteRequest) async throws -> SentMessage { throw error }
  func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage { throw error }
  func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage { throw error }
  func editMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String,
    backwardCompatibilityText: String
  ) async throws {
    guard let onEdit else { throw error }
    try await onEdit()
  }
  func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int) async throws {
    guard let onUnsend else { throw error }
    try await onUnsend()
  }
  func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws { throw error }
  func notifyAnyways(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    guard let onNotify else { throw error }
    try await onNotify()
  }
  func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] { throw error }
  func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String { throw error }
  func createChat(addresses: [String], service: String, message: String?) async throws
    -> ChatIdentifier
  {
    throw error
  }
  func deleteChat(_ chat: ChatIdentifier) async throws { throw error }
  func leaveChat(_ chat: ChatIdentifier) async throws { throw error }
  func setDisplayName(chat: ChatIdentifier, to name: String) async throws { throw error }
  func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws { throw error }
  func addParticipant(_ address: String, to chat: ChatIdentifier) async throws { throw error }
  func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws { throw error }
  func setPinned(chat: ChatIdentifier, pinned: Bool) async throws { throw error }
  func muteState(chat: ChatIdentifier) async throws -> ChatMuteState { throw error }
  func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState { throw error }
  func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    throw error
  }
  func refetchChatBackground(chat: ChatIdentifier) async throws { throw error }
  func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool { throw error }
  func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState { throw error }
  func markSenderKnown(chat: ChatIdentifier, saveInContacts: Bool) async throws -> ChatFilterState {
    throw error
  }
  func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult { throw error }
  func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult { throw error }
  func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState {
    throw error
  }
  func pinnedChats() async throws -> [ChatIdentifier] { throw error }
  func startTyping(chat: ChatIdentifier) async throws { throw error }
  func stopTyping(chat: ChatIdentifier) async throws { throw error }
  func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool { throw error }
  func markRead(chat: ChatIdentifier) async throws { throw error }
  func markUnread(chat: ChatIdentifier) async throws { throw error }
  func checkIMessageAvailability(address: String) async throws -> Bool { throw error }
  func checkFaceTimeAvailability(address: String) async throws -> Bool { throw error }
  func checkFocusStatus(address: String) async throws -> String { throw error }
  func accountInfo() async throws -> AccountInfo { throw error }
  func nicknameInfo(for address: String?) async throws -> NicknameInfo { throw error }
  func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool { throw error }
  func shareNickname(chat: ChatIdentifier) async throws { throw error }
  func modifyActiveAlias(_ alias: String) async throws { throw error }
  func downloadPurgedAttachment(guid: String) async throws -> String { throw error }
  func findMyStatus() async throws -> FindMyStatus { throw error }
  func findMyFriends() async throws -> [FindMyFriend] { throw error }
  func refreshFindMyFriends() async throws -> [FindMyFriend] { throw error }
  func refreshFindMyLocation(handle: String) async throws -> FindMyFriend { throw error }
  func requestFindMyLocationShare(handle: String) async throws { throw error }
  func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws { throw error }
  func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws {
    throw error
  }
  func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink { throw error }
  func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall { throw error }
  func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink { throw error }
  func answerFaceTimeCall(callUUID: String) async throws { throw error }
  func leaveFaceTimeCall(callUUID: String) async throws { throw error }
  func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    throw error
  }
  func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] { throw error }
  func silenceFaceTimeCall(callUUID: String) async throws -> (muted: Bool, sendingVideo: Bool) {
    throw error
  }
  func faceTimeActiveCalls() async throws -> [FaceTimeCall] { throw error }
  func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus { throw error }
  func faceTimeWindows() async throws -> [String] { throw error }
  func dismissFaceTimeAlert() async throws -> Int { throw error }
  func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] { throw error }
  func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] { throw error }
}

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

public struct FailingPrivateAPI: PrivateAPI {

  /// What every call throws. `PrivateAPIError` is what the real client raises, so this is the
  /// error the translation actually has to cope with.
  public let error: any Error

  /// The three mutating operations, allowed to SUCCEED and to have a side effect.
  ///
  /// `edit`, `unsend` and `notify` wait for a column on an existing row to move, so testing
  /// that wait needs a helper that both returns and changes something. Three closures on this
  /// double rather than a second, succeeding conformance to a sixty-eight-member protocol:
  /// the alternative is another file of `throw error` lines that has to be kept in step with
  /// this one.
  public var onEdit: (@Sendable () async throws -> Void)?
  public var onUnsend: (@Sendable () async throws -> Void)?
  public var onNotify: (@Sendable () async throws -> Void)?

  public init(error: any Error = PrivateAPIError.rejectedByMessages(reason: "Messages said no")) {
    self.error = error
  }

  /// True, so a caller that gates on connectedness proceeds and reaches the failure. A fake
  /// that reported itself disconnected would test the gate instead of the translation.
  public var isConnected: Bool { get async { true } }

  public var events: AsyncStream<PrivateAPIEvent> { AsyncStream { $0.finish() } }

  public func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage { throw error }
  public func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage {
    throw error
  }
  public func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage {
    throw error
  }
  public func sendAppMessage(_ request: SendAppMessageRequest) async throws -> SentMessage {
    throw error
  }
  public func react(_ request: ReactionRequest) async throws -> SentMessage { throw error }
  public func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw error
  }
  public func rescheduleMessage(_ guid: MessageGUID, in chat: ChatIdentifier, to date: Date)
    async throws
  {
    throw error
  }
  public func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws {
    throw error
  }
  public func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw error
  }
  public func createPoll(_ request: PollCreateRequest) async throws -> SentMessage { throw error }
  public func votePoll(_ request: PollVoteRequest) async throws -> SentMessage { throw error }
  public func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage { throw error }
  public func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage { throw error }
  public func saveSticker(_ request: SaveStickerRequest) async throws -> SavedSticker {
    throw error
  }
  public func editMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String,
    backwardCompatibilityText: String
  ) async throws {
    guard let onEdit else { throw error }
    try await onEdit()
  }
  public func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int)
    async throws
  {
    guard let onUnsend else { throw error }
    try await onUnsend()
  }
  public func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    throw error
  }
  public func notifyAnyways(_ guid: MessageGUID, in chat: ChatIdentifier) async throws {
    guard let onNotify else { throw error }
    try await onNotify()
  }
  public func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID] {
    throw error
  }
  public func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String { throw error }
  public func createChat(addresses: [String], service: String, message: String?) async throws
    -> ChatIdentifier
  {
    throw error
  }
  public func deleteChat(_ chat: ChatIdentifier) async throws { throw error }
  public func leaveChat(_ chat: ChatIdentifier) async throws { throw error }
  public func setDisplayName(chat: ChatIdentifier, to name: String) async throws { throw error }
  public func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws { throw error }
  public func addParticipant(_ address: String, to chat: ChatIdentifier) async throws {
    throw error
  }
  public func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws {
    throw error
  }
  public func setPinned(chat: ChatIdentifier, pinned: Bool) async throws { throw error }
  public func muteState(chat: ChatIdentifier) async throws -> ChatMuteState { throw error }
  public func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState { throw error }
  public func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState {
    throw error
  }
  public func refetchChatBackground(chat: ChatIdentifier) async throws { throw error }
  public func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool { throw error }
  public func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState { throw error }
  public func markSenderKnown(chat: ChatIdentifier, saveInContacts: Bool) async throws
    -> ChatFilterState
  {
    throw error
  }
  public func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    throw error
  }
  public func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    throw error
  }
  public func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState {
    throw error
  }
  public func pinnedChats() async throws -> [ChatIdentifier] { throw error }
  public func startTyping(chat: ChatIdentifier) async throws { throw error }
  public func stopTyping(chat: ChatIdentifier) async throws { throw error }
  public func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool { throw error }
  public func markRead(chat: ChatIdentifier) async throws { throw error }
  public func markUnread(chat: ChatIdentifier) async throws { throw error }
  public func checkIMessageAvailability(address: String) async throws -> Bool { throw error }
  public func checkFaceTimeAvailability(address: String) async throws -> Bool { throw error }
  public func checkFocusStatus(address: String) async throws -> String { throw error }
  public func accountInfo() async throws -> AccountInfo { throw error }
  public func nicknameInfo(for address: String?) async throws -> NicknameInfo { throw error }
  public func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool { throw error }
  public func shareNickname(chat: ChatIdentifier) async throws { throw error }
  public func modifyActiveAlias(_ alias: String) async throws { throw error }
  public func downloadPurgedAttachment(guid: String) async throws -> String { throw error }
  public func findMyStatus() async throws -> FindMyStatus { throw error }
  public func findMyFriends() async throws -> [FindMyFriend] { throw error }
  public func refreshFindMyFriends() async throws -> [FindMyFriend] { throw error }
  public func refreshFindMyLocation(handle: String) async throws -> FindMyFriend { throw error }
  public func requestFindMyLocationShare(handle: String) async throws { throw error }
  public func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws { throw error }
  public func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws {
    throw error
  }
  public func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink {
    throw error
  }
  public func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall {
    throw error
  }
  public func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink {
    throw error
  }
  public func answerFaceTimeCall(callUUID: String) async throws { throw error }
  public func leaveFaceTimeCall(callUUID: String) async throws { throw error }
  public func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws {
    throw error
  }
  public func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember] {
    throw error
  }
  public func silenceFaceTimeCall(callUUID: String) async throws -> (
    muted: Bool, sendingVideo: Bool
  ) {
    throw error
  }
  public func faceTimeActiveCalls() async throws -> [FaceTimeCall] { throw error }
  public func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus {
    throw error
  }
  public func faceTimeWindows() async throws -> [String] { throw error }
  public func dismissFaceTimeAlert() async throws -> Int { throw error }
  public func faceTimeDebugState(conversationUUID: String) async throws -> [String: String] {
    throw error
  }
  public func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String] { throw error }
}

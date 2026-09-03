//  HelperAction
//  The command vocabulary the server and the injected helpers share.
//
//  Both ends of this socket spelled every command as a string literal, independently: 63
//  actions written twice, plus the payload keys inside them. Nothing connected the two
//  spellings, so a typo on either side compiled, shipped, and surfaced as a runtime rejection
//  from Messages — and adding a command meant remembering to edit a file in a different
//  target with no compiler to remind you. The vocabulary happened to be in sync when this was
//  introduced; nothing had been keeping it that way.
//
//  These enums are that connection. The client sends a case, each helper switches over its
//  own enum exhaustively, and a new command therefore does not compile until both ends handle
//  it. `HelperVocabularyTests` asserts the two halves stay disjoint and fully dispatched.
//
//  TWO ENUMS, NOT ONE, because there are two helpers in two processes with two sockets, and
//  their vocabularies do not overlap. One enum would force each dispatch to write `default:
//  unsupported` over the other's cases, which is precisely the hole this closes. The split
//  also lets the transport route a FaceTime action to the FaceTime helper from the type
//  alone, instead of 15 call sites each remembering to pass `process:`.
//
//  The raw values ARE the wire format. A shipped helper matches on them, so renaming a case
//  is free and changing a raw value is a protocol break.

import Foundation

/// A command the Messages helper understands.
public enum MessagesHelperAction: String, Sendable, CaseIterable, CustomStringConvertible {
  case addParticipant = "add-participant"
  case balloonBundleMediaPath = "balloon-bundle-media-path"
  case checkFaceTimeAvailability = "check-facetime-availability"
  case cancelScheduledMessage = "cancel-scheduled-message"
  case checkFocusStatus = "check-focus-status"
  case checkIMessageAvailability = "check-imessage-availability"
  case checkTypingStatus = "check-typing-status"
  case clearChatHistory = "clear-chat-history"
  case createChat = "create-chat"
  case createPoll = "create-poll"
  case deleteChat = "delete-chat"
  case deleteMessage = "delete-message"
  case downloadPurgedAttachment = "download-purged-attachment"
  case editMessage = "edit-message"
  case findMyFriends = "findmy-friends"
  case findMyStatus = "findmy-status"
  case getAccountInfo = "get-account-info"
  case getChatFilter = "get-chat-filter"
  case getChatMute = "get-chat-mute"
  case getNicknameInfo = "get-nickname-info"
  case getPinnedChats = "get-pinned-chats"
  case leaveChat = "leave-chat"
  case markChatRead = "mark-chat-read"
  case markChatSpam = "mark-chat-spam"
  case markChatUnread = "mark-chat-unread"
  case markSenderKnown = "mark-sender-known"
  case modifyActiveAlias = "modify-active-alias"
  case notifyAnyways = "notify-anyways"
  case refetchChatBackground = "refetch-chat-background"
  case refreshFindMyFriends = "refresh-findmy-friends"
  case refreshFindMyLocation = "refresh-findmy-location"
  case removeParticipant = "remove-participant"
  case rescheduleMessage = "reschedule-message"
  case reportChatJunk = "report-chat-junk"
  case requestFindMyLocationShare = "request-findmy-location-share"
  case searchMessages = "search-messages"
  case sendAttachment = "send-attachment"
  case sendMessage = "send-message"
  case sendMultipart = "send-multipart"
  case sendReaction = "send-reaction"
  case sendScheduledNow = "send-scheduled-now"
  case sendSticker = "send-sticker"
  case setChatFilter = "set-chat-filter"
  case setChatMute = "set-chat-mute"
  case setDisplayName = "set-display-name"
  case shareNickname = "share-nickname"
  case shouldOfferNicknameSharing = "should-offer-nickname-sharing"
  case startSharingFindMyLocation = "start-sharing-findmy-location"
  case startTyping = "start-typing"
  case stopSharingFindMyLocation = "stop-sharing-findmy-location"
  case stopTyping = "stop-typing"
  case unmuteChat = "unmute-chat"
  case unsendMessage = "unsend-message"
  case updateChatPinned = "update-chat-pinned"
  case updateGroupPhoto = "update-group-photo"
  case updatePoll = "update-poll"
  case votePoll = "vote-poll"

  public var description: String { rawValue }
}

/// A command the FaceTime helper understands.
public enum FaceTimeHelperAction: String, Sendable, CaseIterable, CustomStringConvertible {
  case admitPendingMember = "admit-pending-member"
  case answerCall = "answer-call"
  case dialFaceTime = "dial-facetime"
  case faceTimeActiveCalls = "facetime-active-calls"
  case faceTimeCallStatus = "facetime-call-status"
  case faceTimeDebug = "facetime-debug"
  case faceTimeDismissAlert = "facetime-dismiss-alert"
  case faceTimeMembers = "facetime-members"
  case faceTimeWindows = "facetime-windows"
  case generateLink = "generate-link"
  case invalidateFaceTimeLinks = "invalidate-facetime-links"
  case leaveCall = "leave-call"
  case silenceFaceTimeCall = "silence-facetime-call"

  public var description: String { rawValue }
}

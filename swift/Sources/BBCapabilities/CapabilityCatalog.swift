//  CapabilityCatalog
//  Every Private API capability, and the queries the UI and the gates ask of them.
//
//  ONE ENTRY PER THING A USER WOULD NOTICE, not one per selector. "Send a sticker" is a
//  capability; the two initializers behind it are not, because a user cannot be told
//  `accessibilityName:` arrived in 15 and do anything with that. Where a selector merely
//  moved and the helper ladders onto the older spelling, there is NO entry at all — the
//  feature works everywhere, which is the whole point of the ladder, and listing it as
//  version-dependent would advertise an upgrade that buys nothing.
//
//  So this file lists what macOS itself does not have. It is short on purpose, and it should
//  get shorter as Apple's floor moves rather than longer as this port grows.

import BBPrivateAPIContract
import Foundation

extension PrivateAPICapability {

  // MARK: - Declarations

  // MARK: - What the Private API adds on every supported release
  //
  // These are the reason to set it up at all. Without the helper the server can do what
  // AppleScript can do — send text, send an attachment, start a one-to-one chat — and
  // nothing else; everything below is unavailable no matter which macOS is running. See
  // `.claude/docs/imessage.md` for the backend-by-backend table this is drawn from.
  //
  // Their `minimumMacOS` is 14 because that is this package's floor, and the drift test
  // confirms the evidence is present on every dumped release rather than taking it on
  // trust.

  public static let richSending = Self(
    id: "rich-sending",
    title: "Improved message sending",
    summary:
      "Send with a subject line, and more reliably than the scripting interface manages.",
    minimumMacOS: 14,
    evidence: .selectorExists("subject", onClass: "IMMessage"),
    category: .messages,
    messagesActions: [.sendMessage, .sendMultipart, .sendAttachment, .sendAppMessage])

  public static let messageEffects = Self(
    id: "message-effects",
    title: "Bubble and screen effects",
    summary: "Send with slam, loud, gentle, invisible ink, confetti, fireworks and the rest.",
    minimumMacOS: 14,
    evidence: .selectorExists("expressiveSendStyleID", onClass: "IMMessage"),
    category: .messages)

  public static let replies = Self(
    id: "replies",
    title: "Threaded replies",
    summary: "Reply to one specific message, so the conversation keeps the thread.",
    minimumMacOS: 14,
    evidence: .selectorExists("setThreadIdentifier:", onClass: "IMMessage"),
    category: .messages)

  public static let mentions = Self(
    id: "mentions",
    title: "Mentions",
    summary: "Mention someone by name in a group so they are notified even on Do Not Disturb.",
    minimumMacOS: 14,
    // SENDING a mention is an attribute written onto the message body, which a header dump
    // cannot see. But whether a conversation supports one at all is IMCore's own question
    // and it answers it out loud, so that is what this checks — a release without mentions
    // would not carry the method that asks.
    evidence: .selectorExists("_supportsMentions", onClass: "IMChat"),
    category: .messages)

  public static let editMessage = Self(
    id: "edit-message",
    title: "Edit a sent message",
    summary: "Change the wording of a message you already sent, as Messages does.",
    minimumMacOS: 14,
    evidence: .anySelectorExists(
      [
        "editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:",
        "editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:",
        "editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:",
      ], onClass: "IMChat"),
    category: .messages,
    messagesActions: [.editMessage])

  public static let unsendMessage = Self(
    id: "unsend-message",
    title: "Unsend a message",
    summary: "Take back a message so it disappears for everyone in the conversation.",
    minimumMacOS: 14,
    evidence: .selectorExists("retractMessagePart:", onClass: "IMChat"),
    category: .messages,
    messagesActions: [.unsendMessage])

  public static let typingIndicators = Self(
    id: "typing-indicators",
    title: "Typing indicators",
    summary: "See when someone is typing to you, and show them when you are.",
    minimumMacOS: 14,
    evidence: .selectorExists("setLocalUserIsTyping:", onClass: "IMChat"),
    category: .messages,
    messagesActions: [.startTyping, .stopTyping, .checkTypingStatus])

  public static let readState = Self(
    id: "read-state",
    title: "Mark as read or unread",
    summary: "Clear a conversation's badge, or put it back, from a client.",
    minimumMacOS: 14,
    evidence: .selectorExists("markAllMessagesAsRead", onClass: "IMChat"),
    category: .messages,
    messagesActions: [.markChatRead, .markChatUnread, .notifyAnyways])

  public static let tapbacks = Self(
    id: "tapbacks",
    title: "Reactions",
    summary: "Love, like, dislike, laugh, emphasise and question, on any message.",
    minimumMacOS: 14,
    evidence: .classExists("IMTapbackSender"),
    category: .reactions,
    messagesActions: [.sendReaction])

  public static let stickers = Self(
    id: "stickers",
    title: "Stickers",
    summary: "Send a sticker, and place it on a message the way Messages does.",
    minimumMacOS: 14,
    evidence: .anySelectorExists(
      [
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:",
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:moodCategory:stickerName:",
      ], onClass: "IMSticker"),
    category: .reactions,
    messagesActions: [.sendSticker, .saveSticker])

  public static let groupManagement = Self(
    id: "group-management",
    title: "Managing groups",
    summary: "Rename a group, add or remove people, change its photo, and leave it.",
    minimumMacOS: 14,
    evidence: .selectorExists("sendGroupPhotoUpdate:", onClass: "IMChat"),
    category: .organising,
    messagesActions: [.createChat, .addParticipant, .removeParticipant, .setDisplayName, .updateGroupPhoto, .leaveChat, .deleteChat, .deleteMessage, .clearChatHistory])

  public static let pinning = Self(
    id: "pinning",
    title: "Pinning conversations",
    summary: "Pin a conversation to the top, in the same order as your other devices.",
    minimumMacOS: 14,
    evidence: .selectorExists(
      "setPinnedChats:withUpdateReason:", onClass: "IMPinnedConversationsController"),
    category: .organising,
    messagesActions: [.getPinnedChats, .updateChatPinned])

  public static let muting = Self(
    id: "muting",
    title: "Muting conversations",
    summary: "Silence a conversation, permanently or until a time you choose.",
    minimumMacOS: 14,
    evidence: .selectorExists("setMuteUntilDate:", onClass: "IMChat"),
    category: .organising,
    messagesActions: [.getChatMute, .setChatMute, .unmuteChat])

  public static let junkReporting = Self(
    id: "junk-reporting",
    title: "Spam and junk",
    summary: "Report a conversation as junk, mark it as spam, and move it out of Unknown Senders.",
    minimumMacOS: 14,
    evidence: .anySelectorExists(["reportJunk", "reportJunkToCarrier"], onClass: "IMChat"),
    category: .organising,
    messagesActions: [.getChatFilter, .setChatFilter, .markChatSpam, .reportChatJunk])

  public static let faceTime = Self(
    id: "facetime",
    title: "FaceTime from a client",
    summary: "Answer or end a call, and create a link someone can join from anywhere.",
    minimumMacOS: 14,
    evidence: .selectorExists("answerOrJoinCall:", onClass: "TUCallCenter"),
    category: .faceTime,
    faceTimeActions: [.admitPendingMember, .answerCall, .dialFaceTime, .faceTimeActiveCalls, .faceTimeCallStatus, .faceTimeDismissAlert, .faceTimeMembers, .generateLink, .invalidateFaceTimeLinks, .leaveCall, .silenceFaceTimeCall])

  public static let findMy = Self(
    id: "find-my",
    title: "Find My",
    summary: "See where your friends and devices are, and share your own location.",
    minimumMacOS: 14,
    evidence: .classExists("FMFSession"),
    category: .findMy,
    messagesActions: [.findMyFriends, .findMyStatus, .refreshFindMyFriends, .refreshFindMyLocation, .requestFindMyLocationShare, .startSharingFindMyLocation, .stopSharingFindMyLocation])

  // MARK: - What a newer macOS adds

  public static let emojiReactions = Self(
    id: "emoji-reactions",
    title: "Emoji reactions",
    summary: "React with any emoji, not just the six built-in tapbacks.",
    minimumMacOS: 15,
    evidence: .classExists("IMEmojiTapback"),
    category: .reactions)

  public static let stickerReactions = Self(
    id: "sticker-reactions",
    title: "Sticker reactions",
    summary: "Send a sticker as a reaction to a message, the way a tapback attaches to it.",
    minimumMacOS: 15,
    evidence: .classExists("IMStickerTapback"),
    category: .reactions)

  public static let sendLater = Self(
    id: "send-later",
    title: "Scheduled messages",
    summary: "Write a message now and have iMessage deliver it at a chosen time.",
    minimumMacOS: 15,
    evidence: .classExists("CKSendLaterPluginInfo"),
    category: .messages,
    messagesActions: [.cancelScheduledMessage, .editScheduledMessage, .rescheduleMessage, .sendScheduledNow])

  public static let textFormatting = Self(
    id: "text-formatting",
    title: "Text formatting",
    summary: "Bold, italics, underline and strikethrough inside a message.",
    minimumMacOS: 15,
    // SENDING formatting is attribute names on the attributed body, which a header dump
    // cannot see, and this Mac writes them on any release. What arrived in macOS 15 is
    // Messages being able to APPLY a style, and its own key command for doing so is the
    // marker: `CKChatController` is present on all three releases and only carries this
    // selector from 15. Not a borrowed neighbour — it is the text-styling command itself.
    evidence: .selectorExists("keyCommandApplyTextStyle:", onClass: "CKChatController"),
    category: .messages)

  public static let polls = Self(
    id: "polls",
    title: "Polls",
    summary: "Create a poll in a group and collect votes from everyone in it.",
    minimumMacOS: 26,
    evidence: .classExists("IMPollHelper"),
    category: .messages,
    messagesActions: [.createPoll, .updatePoll, .votePoll])

  public static let chatBackgrounds = Self(
    id: "chat-backgrounds",
    title: "Conversation backgrounds",
    summary: "Set a background image for a conversation, shared with everyone in it.",
    minimumMacOS: 26,
    evidence: .selectorExists(
      "refetchLocalTranscriptBackgroundAssetIfNecessary", onClass: "IMChat"),
    category: .organising,
    messagesActions: [.refetchChatBackground])

  public static let screenUnknownSenders = Self(
    id: "screen-unknown-senders",
    title: "Screen unknown senders",
    summary: "See whether a sender is known, and accept one into your contacts.",
    minimumMacOS: 26,
    evidence: .selectorExists("markAsKnownAndSaveInContacts:completion:", onClass: "IMChat"),
    category: .organising,
    messagesActions: [.markSenderKnown])

  // NOT LISTED: muting, sending stickers, reporting junk, starting a FaceTime call and
  // everything else the helper ladders. Those work on every supported release through an
  // older spelling, so they are not something an upgrade buys.
  //
  // `IMMutedChatList` was a candidate — it arrives in 15 and carries a `syncToPairedDevice:`
  // argument the macOS 14 path has no way to pass. It is left out because the honest
  // version of that row would be "muting may not reach your other devices", and MAY is not
  // something to tell a user: the 14 path goes through `-[IMChat setMuteUntilDate:]`, which
  // IMCore may well sync on its own, and nobody has measured whether it does. A row here
  // has to be a fact. See `../../TODO.md`.

  // MARK: - The catalog

  /// Every capability, in declaration order.
  ///
  /// Hand-listed rather than discovered by reflection: Swift has no way to enumerate the
  /// static members of a type, and a mirror over an instance would not see them. The drift
  /// test asserts this list is complete against the gates that consume it, so a declaration
  /// left out of it is caught rather than silently unlisted.
  public static let all: [PrivateAPICapability] = [
    // Every supported release.
    richSending, messageEffects, replies, mentions, editMessage, unsendMessage, typingIndicators, readState,
    tapbacks, stickers, groupManagement, pinning, muting, junkReporting, faceTime, findMy,
    // Gated on a newer macOS.
    emojiReactions, stickerReactions, sendLater, textFormatting, polls,
    chatBackgrounds, screenUnknownSenders,
  ]
}

// MARK: - Queries

extension PrivateAPICapability {

  /// Whether this Mac has it.
  public func isAvailable(on macOSMajor: Int = PrivateAPICapability.currentMacOSMajor) -> Bool {
    macOSMajor >= minimumMacOS
  }

  /// The running macOS major version, read once.
  ///
  /// A stored property rather than a computed one so every caller in a render pass agrees,
  /// and so a test can reason about a single value rather than a call that could in
  /// principle change underneath it.
  public static let currentMacOSMajor = ProcessInfo.processInfo.operatingSystemVersion
    .majorVersion
}

extension Array where Element == PrivateAPICapability {

  /// What works on this macOS.
  public func available(on macOSMajor: Int) -> [PrivateAPICapability] {
    filter { $0.isAvailable(on: macOSMajor) }
  }

  /// What does not, soonest-available first.
  ///
  /// Sorted by the release that would bring it, because the question behind this list is
  /// "what is the next upgrade worth" and that answer is grouped by version.
  public func unavailable(on macOSMajor: Int) -> [PrivateAPICapability] {
    filter { !$0.isAvailable(on: macOSMajor) }
      .sorted {
        $0.minimumMacOS != $1.minimumMacOS
          ? $0.minimumMacOS < $1.minimumMacOS : $0.category < $1.category
      }
  }

  /// What is missing, grouped by the macOS that would bring it, **newest release first**.
  ///
  /// One heading per release, so somebody on macOS 14 sees what each step buys rather than a
  /// flat list they have to sort in their head.
  ///
  /// Newest first because the UI puts an upward arrow on each group, and a column of upward
  /// arrows that ascends as you read DOWN is a column pointing the wrong way. Reading top to
  /// bottom now walks back towards where the reader is.
  ///
  /// **The groups are incremental, not cumulative.** Each lists what that release adds over
  /// the one below it, so upgrading to the top one gets everything in the list, not just its
  /// own group. Splitting it the other way would repeat every capability under every release
  /// that has it, which is a longer list that reads as more.
  public func upgradePaths(from macOSMajor: Int) -> [(macOS: Int, capabilities: [PrivateAPICapability])] {
    let missing = unavailable(on: macOSMajor)
    let versions = Set(missing.map(\.minimumMacOS)).sorted(by: >)
    return versions.map { version in
      (macOS: version, capabilities: missing.filter { $0.minimumMacOS == version })
    }
  }
}

// MARK: - Naming a release

extension PrivateAPICapability {

  /// `macOS Sequoia (15)`. One place that knows Apple's names, including the 15 → 26 jump.
  ///
  /// Used by the UI and by the version gates' refusal sentences. Those sentences are NOT
  /// generated from the catalog: they reach API clients, several are frozen v1 wording, and
  /// "Send Later" is what a client calls the feature the catalog titles "Scheduled
  /// messages". The gates take the NUMBER from here — which is the thing that was duplicated
  /// and could drift — and keep their own prose.
  public static func releaseName(_ major: Int) -> String {
    switch major {
    case 14: "macOS Sonoma (14)"
    case 15: "macOS Sequoia (15)"
    case 26: "macOS Tahoe (26)"
    // Deliberately not a guess at the marketing name. There is no macOS 16 through 25 —
    // Apple went 15 to 26 — so anything else here is a release this build predates, and
    // inventing a name for it would be worse than naming the number.
    default: "macOS \(major)"
    }
  }
}

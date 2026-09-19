//  BBPrivateAPIContract
//  The typed surface shared by the server and the code injected into Messages.app.
//
//  Modelled on the shipping Objective-C helper (BlueBubblesApp/bluebubbles-helper,
//  Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m). The action set below is the
//  full set that helper dispatches, not a subset, so the Swift port has a complete target
//  from the start.
//
//  WHY THERE ARE TWO PROCESSES
//  The Private API drives IMCore, which talks to imagent and IMDPersistenceAgent. A
//  standalone process *can* reach them (Beeper's Barcelona does) but only with AMFI
//  disabled in addition to SIP, plus a machine-wide XPC policy downgrade, and its own docs
//  say it targets "weakened systems" rather than factory-default macOS. AMFI-off disables
//  code-signing enforcement for every process on the machine.
//
//  Injecting into Messages.app costs SIP alone, because the injected code inherits
//  Messages.app's entitlements. Injection is the cheaper ask, not the only option, which is
//  why BlueBubbles and openclaw/imsg landed on it independently.
//
//  WHAT IS IN THIS FILE AND WHAT IS NOT
//  This file is the CONTRACT: the roles, the composed `PrivateAPI` they make up, and the
//  error every one of them throws. The payload types they pass are beside it, one file per
//  topic, the same way `FaceTime`, `FindMy`, `WireKey` and `HelperAction` already were:
//  `Identifiers`, `Messages`, `TextFormatting`, `Polls`, `Account`, `ChatState` and
//  `Events`. Nothing moved between targets, so a consumer's imports are unchanged.
//
//  Both sides import this module, so the contract cannot drift.
//  See `.claude/docs/private-api.md`.

import Foundation

// MARK: - The contract
//
// Every method is typed: no `[String: Any]` payloads anywhere.
//
// Helper/BlueBubblesHelper implements this against IMCore. A method the helper has not
// implemented answers `notImplemented`, so partial ports are shippable.
//
// SPLIT INTO ROLES, and the reason is testing rather than tidiness. One protocol of
// seventy-odd members with no default implementations makes a conformance an all-or-nothing
// obligation, so the only cheap double is one that throws from every member, and nothing
// can then drive a Private API operation to a result.
//
// A role is small enough to fake. `PollControl` is three methods; a stub that returns a
// `SentMessage` is six lines, and `PollInterface` can be tested against it. The composed
// `PrivateAPI` below still refines every role, so `PrivateAPIClient`, `IMCoreBridge` and
// every existential that holds one are unchanged; a consumer narrows to the roles it uses
// when there is a reason to, and an `any PrivateAPI` still satisfies them all.
//
// The roles are drawn from what CONSUMERS call, not from what reads tidily. `deleteMessage`
// sits in `MessageMutation` even though `ChatInterface` is what calls it, because the
// alternative is a role nobody can fake without also faking chat administration.

/// Whether the helper is reachable, and what it is telling us.
///
/// Its own role because it is the one thing nearly every consumer needs alongside whatever
/// else it does, and the one thing a double must always answer. Deliberately NOT inherited
/// by the roles below: a stub for `PollControl` should not have to invent a connection
/// state, and a consumer that needs both says so by composing them.
public protocol PrivateAPIConnection: Sendable {
  var isConnected: Bool { get async }
  var events: AsyncStream<PrivateAPIEvent> { get }
}

// MARK: - Messages

/// Putting something new into a conversation.
public protocol MessageSending: Sendable {
  func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage
  func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage
  func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage
  /// Sends an iMessage-app balloon built by the caller, and answers with its message.
  func sendAppMessage(_ request: SendAppMessageRequest) async throws -> SentMessage
  /// Returns the reaction's OWN message, not the message it reacts to.
  ///
  /// A tapback is an ordinary message with an association, so Messages assigns it a GUID,
  /// and the v1 route answers with the serialised row behind that GUID, which is why the
  /// identifier has to come back across the wire. This returned nothing until then.
  func react(_ request: ReactionRequest) async throws -> SentMessage
  /// Places a sticker on a message part and returns the sticker's OWN message, exactly as
  /// `react` does: a sticker is an association with a file behind it.
  func sendSticker(_ request: SendStickerRequest) async throws -> SentMessage
}

/// Changing or withdrawing a message that has already been delivered.
///
/// Separate from `MessageSending` because the failure modes are different in a way callers
/// care about: a send that fails has produced nothing, while an edit that fails may have
/// changed what the recipient sees. `ChatInterface` composes this for `deleteMessage` alone.
public protocol MessageMutation: Sendable {
  func editMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String,
    backwardCompatibilityText: String) async throws
  func unsendMessage(_ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int) async throws
  func deleteMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws
  /// Rings a silenced message through. Needs the CHAT, like every other write.
  ///
  /// It took only the message GUID and could never work: `chat(owning:)` recovers the
  /// conversation from the item, and an `IMMessageItem` fetched by GUID reports
  /// `chatIdentifier = nil`, the same fact `requireConversation` is written around two
  /// functions below. Every call answered "could not find the conversation this message
  /// belongs to". The reference has always sent `{chatGuid, messageGuid}`.
  func notifyAnyways(_ guid: MessageGUID, in chat: ChatIdentifier) async throws
}

/// Reading things about a message that only IMCore knows.
///
/// Both members reach into Messages for something chat.db does not hold, which is what
/// separates them from the repository's own reads.
public protocol MessageQuerying: Sendable {
  func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID]
  /// Path to the rendered preview for a Digital Touch or handwritten message.
  func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String
}

/// Messages queued with `SendMessageRequest.scheduledFor`, before they are sent.
///
/// Its own role rather than part of `MessageMutation`: nothing has been delivered, so none
/// of these produce an edit history and the recipient never sees an earlier state.
public protocol ScheduledMessaging: Sendable {
  /// Cancels a message scheduled with `SendMessageRequest.scheduledFor`, before it is sent.
  func cancelScheduledMessage(_ guid: MessageGUID, in chat: ChatIdentifier) async throws
  /// Moves a scheduled message to a new delivery time.
  func rescheduleMessage(_ guid: MessageGUID, in chat: ChatIdentifier, to date: Date) async throws
  /// Rewrites one part of a scheduled message, before it is sent. Not an edit in the
  /// iMessage sense: nothing has been delivered, so there is no edit history and the
  /// recipient never sees the earlier text.
  func editScheduledMessage(
    _ guid: MessageGUID, in chat: ChatIdentifier, partIndex: Int, newText: String
  ) async throws
  /// Delivers a scheduled message now, leaving the schedule behind.
  func sendScheduledMessageNow(_ guid: MessageGUID, in chat: ChatIdentifier) async throws
}

/// Polls. macOS 26 and later.
public protocol PollControl: Sendable {
  /// Sends a new poll and answers with its message. macOS 26 and later.
  func createPoll(_ request: PollCreateRequest) async throws -> SentMessage
  /// Casts (or replaces) the local user's vote, and answers with the vote's own message.
  func votePoll(_ request: PollVoteRequest) async throws -> SentMessage
  /// Re-sends a poll in a new state (a choice added) and answers with the update's message.
  func updatePoll(_ request: PollUpdateRequest) async throws -> SentMessage
}

/// This Mac's sticker store.
public protocol StickerLibrary: Sendable {
  /// Adds a sticker to this Mac's sticker store so it appears in the picker.
  ///
  /// Not a send: nothing reaches a conversation. It exists so a client can put a sticker
  /// on the Mac once and then send it by identifier, rather than uploading the same bytes
  /// on every send.
  func saveSticker(_ request: SaveStickerRequest) async throws -> SavedSticker
}

// MARK: - Chats

/// Creating conversations and changing who and what is in them.
public protocol ChatAdministration: Sendable {
  func createChat(addresses: [String], service: String, message: String?) async throws
    -> ChatIdentifier
  func deleteChat(_ chat: ChatIdentifier) async throws
  func leaveChat(_ chat: ChatIdentifier) async throws
  func setDisplayName(chat: ChatIdentifier, to name: String) async throws
  func updateGroupPhoto(chat: ChatIdentifier, imagePath: String) async throws
  func addParticipant(_ address: String, to chat: ChatIdentifier) async throws
  func removeParticipant(_ address: String, from chat: ChatIdentifier) async throws
  func setPinned(chat: ChatIdentifier, pinned: Bool) async throws

  /// The pinned conversations, in display ORDER: pins render in this sequence, so a client
  /// syncing them between devices has to keep it.
  func pinnedChats() async throws -> [ChatIdentifier]

  /// Deletes every message in a conversation, leaving the conversation itself.
  ///
  /// NOT `deleteChat`, which removes the conversation through `CKConversationList`. Returns
  /// whether IMCore reported having deleted anything: a scalar return, which `BBInvoke`
  /// boxes rather than dropping.
  func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool

  /// Asks imagent to download a conversation's background asset from iCloud.
  ///
  /// A background is synced as an MMCS asset: the chat's properties name it
  /// (`trabaid`, `trabar`, `trabak`) long before the bytes are on this Mac, so a
  /// conversation can legitimately have a wallpaper the server cannot serve. This is the
  /// call that fetches it.
  ///
  /// **Fire and forget.** IMCore's own path
  /// (`-refetchLocalTranscriptBackgroundAssetIfNecessary` → the daemon's
  /// `refetchChatBackgroundIfNeededForChatIdentifier:style:account:`) returns void and takes
  /// no completion, so there is nothing to await inside Messages. Completion is observed by
  /// the file appearing in `TranscriptBackgroundCache`, which is the server's job, not the
  /// helper's.
  func refetchChatBackground(chat: ChatIdentifier) async throws
}

/// Notification suppression for one conversation.
public protocol ChatMuting: Sendable {
  /// Whether a conversation is muted, read from `IMMutedChatList`: the store Messages
  /// actually consults, not the legacy `ignoreAlertsFlag` chat property.
  func muteState(chat: ChatIdentifier) async throws -> ChatMuteState

  /// Mutes, until a date or indefinitely, and reports the resulting state so a client never
  /// has to read back to find out what it did.
  func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState

  func unmute(chat: ChatIdentifier, syncToPairedDevice: Bool) async throws -> ChatMuteState
}

/// Where a conversation sits in Messages' filtering, and the actions that move it.
public protocol ChatFiltering: Sendable {
  /// Where a conversation sits in Messages' filtering.
  func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState

  /// Accepts an unknown sender: `-markAsKnownAndSaveInContacts:completion:`, which is
  /// `updateIsFiltered:` + accepting the chat + marking it reviewed in one call.
  ///
  /// `saveInContacts` writes to the user's address book and defaults to false at every
  /// layer above this one.
  func markSenderKnown(chat: ChatIdentifier, saveInContacts: Bool) async throws -> ChatFilterState

  /// Marks a conversation as spam, optionally reporting it to the carrier.
  func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult

  /// Reports the conversation's messages as junk (the "Report Junk" action).
  func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult

  /// Moves a conversation between filters, and back out of Junk. The value is IMCore's
  /// `isFiltered` category; `0` is the unfiltered inbox.
  func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState
}

/// Typing indicators and read state: the ephemeral half of a conversation.
public protocol ChatPresence: Sendable {
  func startTyping(chat: ChatIdentifier) async throws
  func stopTyping(chat: ChatIdentifier) async throws
  func checkTypingStatus(chat: ChatIdentifier) async throws -> Bool
  func markRead(chat: ChatIdentifier) async throws
  func markUnread(chat: ChatIdentifier) async throws
}

// MARK: - Handles, account and attachments

/// What a given address can be reached on.
public protocol HandleAvailability: Sendable {
  func checkIMessageAvailability(address: String) async throws -> Bool
  func checkFaceTimeAvailability(address: String) async throws -> Bool
  func checkFocusStatus(address: String) async throws -> String
}

/// The signed-in account, and the identity it presents.
public protocol AccountAccess: Sendable {
  func accountInfo() async throws -> AccountInfo
  /// The shared contact card for `address`, or the local user's own when it is nil.
  func nicknameInfo(for address: String?) async throws -> NicknameInfo
  func shouldOfferNicknameSharing(chat: ChatIdentifier) async throws -> Bool
  func shareNickname(chat: ChatIdentifier) async throws
  func modifyActiveAlias(_ alias: String) async throws
}

/// Bytes Messages has a record of but has not kept.
public protocol AttachmentAccess: Sendable {
  func downloadPurgedAttachment(guid: String) async throws -> String
}

// MARK: - FindMy
//
// Reached through `IMFMFSession`, which is an IMCore class and therefore already in
// Messages.app's address space. The Objective-C helper's own version fork
// (`FindMyLocateSession` above macOS 13, `FMFSession` below) is NOT reproduced: IMCore
// makes that choice itself now, off an internal feature flag, and the wrapper API below
// returns the same types either way. See docs/headers/README.md.

public protocol FindMyAccess: Sendable {
  /// Whether FindMy is usable at all. Cheap, and the call a client should make before
  /// offering any FindMy UI; every other method here fails on a Mac that is not set up.
  func findMyStatus() async throws -> FindMyStatus

  /// Everyone in the relationship graph, with whatever position IMCore already holds.
  /// Reads caches only; nothing is fetched from Apple.
  func findMyFriends() async throws -> [FindMyFriend]

  /// Asks Apple for a fresh fix on every friend, then reports what came back.
  ///
  /// This is the one call that reaches Apple's service, so it is rate limited above.
  func refreshFindMyFriends() async throws -> [FindMyFriend]

  /// Asks for a fresh fix on ONE person.
  ///
  /// Much cheaper than the full refresh, and the right call when a client is showing a
  /// single conversation. Reaches Apple, so it is gated the same way.
  func refreshFindMyLocation(handle: String) async throws -> FindMyFriend

  /// Asks someone to share their location with us. Sends a FindMy friendship invite; the
  /// other party accepts or declines on their own device.
  func requestFindMyLocationShare(handle: String) async throws

  /// Starts sharing THIS MAC's location with a chat's participants.
  ///
  /// Note what is being shared: the position of the machine running this server, because
  /// that is the device IMCore is speaking for. It is not the position of whichever client
  /// asked. That is why the route in front of this ships disabled.
  func startSharingFindMyLocation(_ request: FindMyShareRequest) async throws

  /// Stops sharing with a chat, or with one participant of it.
  func stopSharingFindMyLocation(chat: ChatIdentifier, address: String?) async throws
}

// MARK: - FaceTime
//
// Reached through TelephonyUtilities (`TUCallCenter`, `TUConversationManagerXPCClient`),
// which is why these run in a helper injected into FaceTime.app rather than Messages.app,
// FaceTime.app is the process registered with the call daemons. See
// docs/headers/FACETIME.md, whose central finding is that the reliability problem is the
// XPC client lifecycle, not the selectors: the helper holds ONE long-lived, registered,
// state-synced conversation-manager client, not a throwaway per call.

public protocol FaceTimeControl: Sendable {
  /// Mints a link for a NEW conversation (Flow A). `invitedAddresses` pre-invites people
  /// onto the link; whether that rings them or is a passive invite is FaceTime's call.
  func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink

  /// Places an outgoing call so the target's device rings (Flow B), then reports the call.
  /// A link is minted separately with `generateFaceTimeLinkForCall`.
  func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall

  /// Mints a link for an EXISTING call (Flow B/C): the Mac is in the call and wants a link
  /// the client can join by.
  func generateFaceTimeLinkForCall(callUUID: String) async throws -> FaceTimeLink

  /// Answers an incoming call (Flow C). The call must be ringing.
  func answerFaceTimeCall(callUUID: String) async throws

  /// Leaves/drops a call the Mac is in. Safe to call once the client has joined.
  func leaveFaceTimeCall(callUUID: String) async throws

  /// Admits a participant knocking at a conversation's waiting room.
  func admitFaceTimeParticipant(conversationUUID: String, handle: String) async throws

  /// The conversation's members, so the server can tell "the client joined" (drop cue for
  /// Flows B and C) from "still only the caller." Reads only.
  func faceTimeMembers(conversationUUID: String) async throws -> [FaceTimeMember]

  /// Mutes the Mac's mic and stops its camera on a call it is only holding open, and
  /// reports the resulting state. Idempotent and safe to re-assert: mute does not stick
  /// while a call is still ringing, so the hand-off watcher calls this repeatedly.
  func silenceFaceTimeCall(callUUID: String) async throws -> (muted: Bool, sendingVideo: Bool)

  /// Every call the Mac is in, including ones this server never started.
  func faceTimeActiveCalls() async throws -> [FaceTimeCall]

  /// Where a call is now; `.disconnected` when it no longer exists.
  func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus

  /// What FaceTime.app is showing on screen, for diagnosing a wedged dial.
  func faceTimeWindows() async throws -> [String]

  /// Dismisses a blocking alert in FaceTime.app by CANCELLING it. Returns how many.
  func dismissFaceTimeAlert() async throws -> Int

  /// Raw TelephonyUtilities state for a conversation: a diagnostic, not a product API.
  func faceTimeDebugState(conversationUUID: String) async throws -> [String: String]

  /// Invalidates active FaceTime links. `urls` nil invalidates ALL created links; otherwise
  /// only the matching ones. Returns the URLs actually invalidated.
  func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String]
}

// MARK: - The whole helper

/// Everything an injected helper can do.
///
/// Composition only; it declares no members of its own, and that is what keeps the roles
/// above the single source of truth. `PrivateAPIClient` and `IMCoreBridge` conform to this
/// and are unchanged by the split; a consumer that holds `any PrivateAPI` can be handed to
/// anything expecting a role, because an existential upcasts to a protocol it refines.
public protocol PrivateAPI:
  PrivateAPIConnection,
  MessageSending, MessageMutation, MessageQuerying, ScheduledMessaging,
  PollControl, StickerLibrary,
  ChatAdministration, ChatMuting, ChatFiltering, ChatPresence,
  HandleAvailability, AccountAccess, AttachmentAccess,
  FindMyAccess, FaceTimeControl
{}

public enum PrivateAPIError: Error, Sendable, Equatable, LocalizedError {
  /// Ported incrementally: the default for every helper method until filled in.
  case notImplemented(method: String)
  case notConnected
  case timedOut(method: String)
  case rejectedByMessages(reason: String)
  /// The connecting peer failed code-signature validation.
  /// See `.claude/docs/private-api.md` § "Peer verification: audit token, never pid".
  case untrustedPeer(pid: pid_t)
  /// The IMCore selector this method depends on is absent on the running macOS version.
  /// Distinct from `notImplemented`: this one will never work here, whereas that one is
  /// merely not ported yet.
  case unavailableOnThisOS(method: String, requires: String)
  /// The server could not stand up its end of the transport at all: the socket path is
  /// unusable, or Messages' container is not writable. Distinct from `notConnected`, which
  /// means the transport is fine and no helper has arrived.
  case transportUnavailable(String)

  /// A sentence, not a case name.
  ///
  /// Without this the default rendering is `rejectedByMessages(reason: "…")`, the case
  /// name and escaped quotes reach the client verbatim, which reads as a crash rather than
  /// as the clear explanation it actually contains.
  public var errorDescription: String? {
    switch self {
    case .notImplemented(let method):
      "\(method) is not implemented in the Swift helper yet."
    case .notConnected:
      "The Private API helper is not connected."
    case .timedOut(let method):
      "\(method) timed out waiting for Messages."
    case .rejectedByMessages(let reason):
      reason
    case .untrustedPeer(let pid):
      "A process (pid \(pid)) failed code-signature validation on the helper socket."
    case .unavailableOnThisOS(let method, let requires):
      "\(method) is not available on this version of macOS: \(requires)"
    case .transportUnavailable(let reason):
      "The Private API could not start: \(reason)"
    }
  }
}

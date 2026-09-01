//  BBPrivateAPIContract
//  The typed surface shared by the server and the code injected into Messages.app.
//
//  Modelled on the shipping Objective-C helper (BlueBubblesApp/bluebubbles-helper,
//  Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m). The action set below is the
//  full set that helper dispatches — not a subset — so the Swift port has a complete target
//  from the start.
//
//  WHY THERE ARE TWO PROCESSES
//  The Private API drives IMCore, which talks to imagent and IMDPersistenceAgent. A
//  standalone process *can* reach them — Beeper's Barcelona does — but only with AMFI
//  disabled in addition to SIP, plus a machine-wide XPC policy downgrade, and its own docs
//  say it targets "weakened systems" rather than factory-default macOS. AMFI-off disables
//  code-signing enforcement for every process on the machine.
//
//  Injecting into Messages.app costs SIP alone, because the injected code inherits
//  Messages.app's entitlements. Injection is the cheaper ask, not the only option — which is
//  why BlueBubbles and openclaw/imsg landed on it independently.
//
//  Both sides import this module, so the contract cannot drift.
//  See `.claude/docs/private-api.md`.

import Foundation

// MARK: - Identifiers

public struct ChatGUID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  /// Group chats use the `;+;` infix; direct messages use `;-;`.
  public var isGroup: Bool { rawValue.contains(";+;") }
}

public struct MessageGUID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }
}

// MARK: - Message payloads

public struct SendMessageRequest: Codable, Sendable {
  public let chat: ChatGUID
  public let text: String
  public let subject: String?
  public let effectId: String?
  public let replyTo: MessageGUID?
  public let replyPartIndex: Int?
  /// Data-detector scan. Availability is macOS-gated; the caller decides, not the helper.
  public let scanForLinks: Bool
  /// Mention ranges, keyed by the handle being mentioned.
  public let mentions: [String: [Int]]?

  public init(
    chat: ChatGUID,
    text: String,
    subject: String? = nil,
    effectId: String? = nil,
    replyTo: MessageGUID? = nil,
    replyPartIndex: Int? = nil,
    scanForLinks: Bool = false,
    mentions: [String: [Int]]? = nil
  ) {
    self.chat = chat
    self.text = text
    self.subject = subject
    self.effectId = effectId
    self.replyTo = replyTo
    self.replyPartIndex = replyPartIndex
    self.scanForLinks = scanForLinks
    self.mentions = mentions
  }
}

/// One segment of a multipart message — text and attachments interleaved in order.
public struct MessagePart: Codable, Sendable {
  public let text: String?
  public let attachmentPath: String?
  public let mention: String?

  public init(text: String? = nil, attachmentPath: String? = nil, mention: String? = nil) {
    self.text = text
    self.attachmentPath = attachmentPath
    self.mention = mention
  }
}

public struct SendMultipartRequest: Codable, Sendable {
  public let chat: ChatGUID
  public let parts: [MessagePart]
  public let subject: String?
  public let effectId: String?
  public let replyTo: MessageGUID?
  public let replyPartIndex: Int?

  public init(
    chat: ChatGUID,
    parts: [MessagePart],
    subject: String? = nil,
    effectId: String? = nil,
    replyTo: MessageGUID? = nil,
    replyPartIndex: Int? = nil
  ) {
    self.chat = chat
    self.parts = parts
    self.subject = subject
    self.effectId = effectId
    self.replyTo = replyTo
    self.replyPartIndex = replyPartIndex
  }
}

public enum ReactionType: String, Codable, Sendable, CaseIterable {
  case love, like, dislike, laugh, emphasize, question
  case removeLove = "-love"
  case removeLike = "-like"
  case removeDislike = "-dislike"
  case removeLaugh = "-laugh"
  case removeEmphasize = "-emphasize"
  case removeQuestion = "-question"

  /// The `associatedMessageType` IMCore expects.
  ///
  /// 2000-series adds a tapback, 3000-series removes the corresponding one — the offset is
  /// exactly 1000, which is why removal is expressed as a separate value rather than a
  /// flag. Transcribed from `parseReactionType:` (BlueBubblesHelper.m:865); these numbers
  /// are IMCore's, not ours, and a wrong one produces a different tapback than the user
  /// asked for rather than an error.
  public var associatedMessageType: Int64 {
    switch self {
    case .love: 2000
    case .like: 2001
    case .dislike: 2002
    case .laugh: 2003
    case .emphasize: 2004
    case .question: 2005
    case .removeLove: 3000
    case .removeLike: 3001
    case .removeDislike: 3002
    case .removeLaugh: 3003
    case .removeEmphasize: 3004
    case .removeQuestion: 3005
    }
  }

  /// Whether this removes a tapback rather than adding one.
  public var isRemoval: Bool { associatedMessageType >= 3000 }
}

public struct ReactionRequest: Codable, Sendable {
  public let chat: ChatGUID
  public let target: MessageGUID
  public let reaction: ReactionType
  public let partIndex: Int

  public init(chat: ChatGUID, target: MessageGUID, reaction: ReactionType, partIndex: Int = 0) {
    self.chat = chat
    self.target = target
    self.reaction = reaction
    self.partIndex = partIndex
  }
}

public struct SendAttachmentRequest: Codable, Sendable {
  public let chat: ChatGUID
  public let filePath: String
  public let isAudioMessage: Bool

  public init(chat: ChatGUID, filePath: String, isAudioMessage: Bool = false) {
    self.chat = chat
    self.filePath = filePath
    self.isAudioMessage = isAudioMessage
  }
}

/// Confirmation that Messages accepted a send. The authoritative record still arrives via the
/// chat.db change detector; this is what correlates the two.
public struct SentMessage: Codable, Sendable {
  public let guid: MessageGUID
  public let chat: ChatGUID
  public let sentAt: Date

  public init(guid: MessageGUID, chat: ChatGUID, sentAt: Date) {
    self.guid = guid
    self.chat = chat
    self.sentAt = sentAt
  }
}

public struct MessageSearchRequest: Codable, Sendable {
  public let query: String
  public let limit: Int?

  public init(query: String, limit: Int? = nil) {
    self.query = query
    self.limit = limit
  }
}

// MARK: - Account payloads

public struct AccountInfo: Codable, Sendable {
  public let appleId: String?
  public let activeAlias: String?
  public let aliases: [String]
  public let vettedAliases: [String]

  public init(appleId: String?, activeAlias: String?, aliases: [String], vettedAliases: [String]) {
    self.appleId = appleId
    self.activeAlias = activeAlias
    self.aliases = aliases
    self.vettedAliases = vettedAliases
  }
}

/// A shared contact card — the name and photo someone chose to share, which is distinct
/// from anything in Contacts.
///
/// `handle` is nil for the LOCAL user's own card, which is what `icloud.contactCard`
/// returns when no address is given. That case is not a degenerate one: it is the request
/// the reference server's fixture records.
public struct NicknameInfo: Codable, Sendable {
  public let handle: String?
  public let name: String?
  public let hasSharedNickname: Bool
  /// Where Messages keeps the shared photo, or nil when there is none.
  ///
  /// A PATH rather than the bytes, matching the reference implementation: the file lives on
  /// the same Mac, the server already requires Full Disk Access, and an avatar is large
  /// enough that routing it through the helper socket would be paid on every call. The
  /// server reads it and base64-encodes it — see `SystemHandlers`.
  public let avatarPath: String?

  public init(
    handle: String?, name: String?, hasSharedNickname: Bool, avatarPath: String? = nil
  ) {
    self.handle = handle
    self.name = name
    self.hasSharedNickname = hasSharedNickname
    self.avatarPath = avatarPath
  }
}

// MARK: - Chat state

/// Whether a conversation is muted, and until when.
///
/// **Indefinite is not `nil`, and that distinction is measured rather than assumed.**
/// `IMMutedChatList` stores `[untilDate timeIntervalSince1970]` and decides muted-ness by
/// comparing that instant against now, so muting with no date stores `0.0` — 1970 — which
/// reads back as NOT muted. Messages' own "Hide Alerts" writes `Date.distantFuture`.
/// `docs/PRIVATE_API_SURFACE.md` §2 inferred the opposite; `docs/CHAT_CONTROLS_PLAN.md` §0
/// has the disassembly.
///
/// `mutedUntil` is therefore reported as nil when the mute is indefinite: a client should
/// render "muted" rather than "muted until the year 4001", and `isIndefinite` says which.
public struct ChatMuteState: Codable, Sendable, Equatable {
  public let isMuted: Bool
  public let mutedUntil: Date?
  public let isIndefinite: Bool

  public init(isMuted: Bool, mutedUntil: Date?, isIndefinite: Bool) {
    self.isMuted = isMuted
    self.mutedUntil = mutedUntil
    self.isIndefinite = isIndefinite
  }

  /// Anything at or past this is a sentinel rather than a date somebody chose.
  ///
  /// The year 3000 rather than an equality test against `Date.distantFuture`: the value
  /// makes a round trip through epoch seconds in a `Double` and back, and an unmute date a
  /// thousand years out means the same thing as one two thousand years out either way.
  public static let indefiniteThreshold = Date(timeIntervalSince1970: 32_503_680_000)

  /// The state implied by an unmute date, with the sentinel already interpreted.
  public static func from(unmuteDate: Date?) -> ChatMuteState {
    guard let unmuteDate else {
      return ChatMuteState(isMuted: false, mutedUntil: nil, isIndefinite: false)
    }
    if unmuteDate >= indefiniteThreshold {
      return ChatMuteState(isMuted: true, mutedUntil: nil, isIndefinite: true)
    }
    // A date in the past is an EXPIRED mute, which is simply not muted — IMCore leaves
    // the entry in place and lets the comparison decide, so the entry existing is not
    // the same as the chat being muted.
    return ChatMuteState(
      isMuted: unmuteDate > Date(), mutedUntil: unmuteDate, isIndefinite: false
    )
  }
}

/// Where a conversation sits in Messages' filtering, and whether its sender is known.
///
/// One read behind four write paths (spam, junk, mark-known, recover), because they all funnel
/// through `-updateIsFiltered:` and a client needs to see the result of whichever it called.
public struct ChatFilterState: Codable, Sendable, Equatable {
  /// IMCore's `-isFiltered`. A `long long`, not a bool: it is the filter CATEGORY, and
  /// `chat.db`'s `is_filtered` column carries the same value.
  public let isFiltered: Int
  public let filterCategory: Int
  public let isKnownSender: Bool
  public let isInUnknownSendersFilter: Bool
  public let wasDetectedAsSMSSpam: Bool
  /// Whether Messages would offer the "Report Junk" action for this conversation. Reported
  /// so a client can hide an action that would fail rather than offering it everywhere.
  public let canReportJunk: Bool

  public init(
    isFiltered: Int,
    filterCategory: Int,
    isKnownSender: Bool,
    isInUnknownSendersFilter: Bool,
    wasDetectedAsSMSSpam: Bool,
    canReportJunk: Bool
  ) {
    self.isFiltered = isFiltered
    self.filterCategory = filterCategory
    self.isKnownSender = isKnownSender
    self.isInUnknownSendersFilter = isInUnknownSendersFilter
    self.wasDetectedAsSMSSpam = wasDetectedAsSMSSpam
    self.canReportJunk = canReportJunk
  }
}

/// Reporting a conversation as spam.
///
/// `reportToCarrier` defaults to FALSE everywhere it appears, and that is deliberate rather
/// than conservative-by-habit: reporting to a carrier sends an SMS to a shortcode from the
/// user's own number and cannot be withdrawn. A client that omits the field must not trigger
/// it by accident.
public struct ChatSpamRequest: Codable, Sendable {
  public let chat: ChatGUID
  public let reportToCarrier: Bool
  /// Reports what WOULD happen — how many messages are eligible — and changes nothing.
  ///
  /// Exists so this path is testable against a real conversation without reclassifying it
  /// on every device on the account.
  public let dryRun: Bool

  public init(chat: ChatGUID, reportToCarrier: Bool = false, dryRun: Bool = false) {
    self.chat = chat
    self.reportToCarrier = reportToCarrier
    self.dryRun = dryRun
  }
}

/// What a spam or junk report did.
public struct ChatSpamResult: Codable, Sendable, Equatable {
  /// How many messages were reported — or, for a dry run, how many would be.
  public let messageCount: Int
  public let reportedToCarrier: Bool
  public let wasDryRun: Bool
  public let filter: ChatFilterState

  public init(
    messageCount: Int, reportedToCarrier: Bool, wasDryRun: Bool, filter: ChatFilterState
  ) {
    self.messageCount = messageCount
    self.reportedToCarrier = reportedToCarrier
    self.wasDryRun = wasDryRun
    self.filter = filter
  }
}

public struct ChatMuteRequest: Codable, Sendable {
  public let chat: ChatGUID
  /// When the mute lifts. `nil` means indefinitely, and is written as `Date.distantFuture`
  /// rather than as a nil date — see `ChatMuteState`.
  public let until: Date?
  /// Whether the change propagates to the paired iPhone. Exposed rather than hardcoded:
  /// muting here and not there is a legitimate thing to want, and so is the opposite.
  public let syncToPairedDevice: Bool

  public init(chat: ChatGUID, until: Date? = nil, syncToPairedDevice: Bool = true) {
    self.chat = chat
    self.until = until
    self.syncToPairedDevice = syncToPairedDevice
  }
}

// MARK: - Events
//
// Inbound events are NOT polled. The helper obtains them by swizzling methods inside
// Messages.app — see the hook table in BlueBubblesHelper. That mechanism is the most
// version-fragile part of the port: on macOS 26 the IMChat typing path stopped delivering
// and a ChatKit UI hook had to replace it.

public enum PrivateAPIEvent: Sendable {
  /// Sent by the helper immediately on connect, carrying its bundle identifier.
  /// Sent by the helper immediately on connect.
  ///
  /// `eventRung` names the observation ladder rung it managed to attach to
  /// (`"daemon-listener"`, or `"none"`), and is nil from a helper that predates the field.
  case helperRegistered(process: String, protocolVersion: Int?, eventRung: String?)
  case typingChanged(chat: ChatGUID, isTyping: Bool)
  case iMessageAliasesRemoved(aliases: [String])
  case findMyLocationUpdated(payload: [String: String])
  /// A call changed state. Carries the parsed call, so a client sees `incoming` /
  /// `answered` / `disconnected` as a typed status rather than a magic number. The raw
  /// payload is still forwarded for fields the contract does not model.
  case faceTimeCallChanged(call: FaceTimeCall, payload: [String: String])
  /// A conversation's membership changed — someone joined, or is knocking. This is the
  /// signal Flows B and C wait on before the Mac drops: dropping on a timer instead is what
  /// hangs up on the caller.
  case faceTimeMembershipChanged(conversationUUID: String, members: [FaceTimeMember])
}

// MARK: - The contract
//
// Every method is typed — no [String: Any] payloads anywhere, which is the main ergonomic
// win over the current JSON-dictionary protocol.
//
// Helper/BlueBubblesHelper implements this against IMCore. Each method ships stubbed with
// its Objective-C counterpart named, so porting is filling in bodies one at a time against a
// contract the server already compiles against. Methods flip on independently and partial
// ports are shippable.

public protocol PrivateAPI: Sendable {
  var isConnected: Bool { get async }
  var events: AsyncStream<PrivateAPIEvent> { get }

  // Messages
  func sendMessage(_ request: SendMessageRequest) async throws -> SentMessage
  func sendMultipart(_ request: SendMultipartRequest) async throws -> SentMessage
  func sendAttachment(_ request: SendAttachmentRequest) async throws -> SentMessage
  func react(_ request: ReactionRequest) async throws
  func editMessage(
    _ guid: MessageGUID, in chat: ChatGUID, partIndex: Int, newText: String,
    backwardCompatibilityText: String) async throws
  func unsendMessage(_ guid: MessageGUID, in chat: ChatGUID, partIndex: Int) async throws
  func deleteMessage(_ guid: MessageGUID, in chat: ChatGUID) async throws
  func notifyAnyways(_ guid: MessageGUID) async throws
  func searchMessages(_ request: MessageSearchRequest) async throws -> [MessageGUID]
  /// Path to the rendered preview for a Digital Touch or handwritten message.
  func balloonBundleMediaPath(for guid: MessageGUID) async throws -> String

  // Chats
  func createChat(addresses: [String], service: String, message: String?) async throws -> ChatGUID
  func deleteChat(_ chat: ChatGUID) async throws
  func leaveChat(_ chat: ChatGUID) async throws
  func setDisplayName(chat: ChatGUID, to name: String) async throws
  func updateGroupPhoto(chat: ChatGUID, imagePath: String) async throws
  func addParticipant(_ address: String, to chat: ChatGUID) async throws
  func removeParticipant(_ address: String, from chat: ChatGUID) async throws
  func setPinned(chat: ChatGUID, pinned: Bool) async throws

  /// Whether a conversation is muted, read from `IMMutedChatList` — the store Messages
  /// actually consults, not the legacy `ignoreAlertsFlag` chat property.
  func muteState(chat: ChatGUID) async throws -> ChatMuteState

  /// Mutes, until a date or indefinitely, and reports the resulting state so a client never
  /// has to read back to find out what it did.
  func setMute(_ request: ChatMuteRequest) async throws -> ChatMuteState

  func unmute(chat: ChatGUID, syncToPairedDevice: Bool) async throws -> ChatMuteState

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
  func refetchChatBackground(chat: ChatGUID) async throws

  /// Deletes every message in a conversation, leaving the conversation itself.
  ///
  /// NOT `deleteChat`, which removes the conversation through `CKConversationList`. Returns
  /// whether IMCore reported having deleted anything — a BOOL that used to be dropped on
  /// the floor before `BBInvoke` learned to box scalar returns.
  func clearChatHistory(_ chat: ChatGUID) async throws -> Bool

  /// Where a conversation sits in Messages' filtering.
  func chatFilterState(chat: ChatGUID) async throws -> ChatFilterState

  /// Accepts an unknown sender: `-markAsKnownAndSaveInContacts:completion:`, which is
  /// `updateIsFiltered:` + accepting the chat + marking it reviewed in one call.
  ///
  /// `saveInContacts` writes to the user's address book and defaults to false at every
  /// layer above this one.
  func markSenderKnown(chat: ChatGUID, saveInContacts: Bool) async throws -> ChatFilterState

  /// Marks a conversation as spam, optionally reporting it to the carrier.
  func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult

  /// Reports the conversation's messages as junk — the "Report Junk" action.
  func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult

  /// Moves a conversation between filters, and back out of Junk. The value is IMCore's
  /// `isFiltered` category; `0` is the unfiltered inbox.
  func setChatFilter(chat: ChatGUID, category: Int) async throws -> ChatFilterState

  /// The pinned conversations, in display ORDER — pins render in this sequence, so a client
  /// syncing them between devices has to keep it.
  func pinnedChats() async throws -> [ChatGUID]

  // Presence
  func startTyping(chat: ChatGUID) async throws
  func stopTyping(chat: ChatGUID) async throws
  func checkTypingStatus(chat: ChatGUID) async throws -> Bool
  func markRead(chat: ChatGUID) async throws
  func markUnread(chat: ChatGUID) async throws

  // Handles and availability
  func checkIMessageAvailability(address: String) async throws -> Bool
  func checkFaceTimeAvailability(address: String) async throws -> Bool
  func checkFocusStatus(address: String) async throws -> String

  // Account and aliases
  func accountInfo() async throws -> AccountInfo
  /// The shared contact card for `address`, or the local user's own when it is nil.
  func nicknameInfo(for address: String?) async throws -> NicknameInfo
  func shouldOfferNicknameSharing(chat: ChatGUID) async throws -> Bool
  func shareNickname(chat: ChatGUID) async throws
  func modifyActiveAlias(_ alias: String) async throws

  // Attachments
  func downloadPurgedAttachment(guid: String) async throws -> String

  // FindMy
  //
  // Reached through `IMFMFSession`, which is an IMCore class and therefore already in
  // Messages.app's address space. The Objective-C helper's own version fork —
  // `FindMyLocateSession` above macOS 13, `FMFSession` below — is NOT reproduced: IMCore
  // makes that choice itself now, off an internal feature flag, and the wrapper API below
  // returns the same types either way. See docs/headers/README.md.

  /// Whether FindMy is usable at all. Cheap, and the call a client should make before
  /// offering any FindMy UI — every other method here fails on a Mac that is not set up.
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
  func stopSharingFindMyLocation(chat: ChatGUID, address: String?) async throws

  // FaceTime
  //
  // Reached through TelephonyUtilities (`TUCallCenter`, `TUConversationManagerXPCClient`),
  // which is why these run in a helper injected into FaceTime.app rather than Messages.app
  // — FaceTime.app is the process registered with the call daemons. See
  // docs/headers/FACETIME.md, whose central finding is that the reliability problem is the
  // XPC client lifecycle, not the selectors: the helper holds ONE long-lived, registered,
  // state-synced conversation-manager client, not a throwaway per call.

  /// Mints a link for a NEW conversation (Flow A). `invitedAddresses` pre-invites people
  /// onto the link — whether that rings them or is a passive invite is FaceTime's call.
  func generateFaceTimeLink(invitedAddresses: [String]) async throws -> FaceTimeLink

  /// Places an outgoing call so the target's device rings (Flow B), then reports the call.
  /// A link is minted separately with `generateFaceTimeLinkForCall`.
  func dialFaceTime(_ request: FaceTimeStartRequest) async throws -> FaceTimeCall

  /// Mints a link for an EXISTING call (Flow B/C) — the Mac is in the call and wants a link
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

  /// Every call the Mac is currently in, including ones this server never started.
  func faceTimeActiveCalls() async throws -> [FaceTimeCall]

  /// Where a call is now; `.disconnected` when it no longer exists.
  func faceTimeCallStatus(callUUID: String) async throws -> FaceTimeCallStatus

  /// What FaceTime.app is showing on screen, for diagnosing a wedged dial.
  func faceTimeWindows() async throws -> [String]

  /// Dismisses a blocking alert in FaceTime.app by CANCELLING it. Returns how many.
  func dismissFaceTimeAlert() async throws -> Int

  /// Raw TelephonyUtilities state for a conversation — a diagnostic, not a product API.
  func faceTimeDebugState(conversationUUID: String) async throws -> [String: String]

  /// Invalidates active FaceTime links. `urls` nil invalidates ALL created links; otherwise
  /// only the matching ones. Returns the URLs actually invalidated.
  func invalidateFaceTimeLinks(urls: [String]?) async throws -> [String]
}

public enum PrivateAPIError: Error, Sendable, Equatable, LocalizedError {
  /// Ported incrementally — the default for every helper method until filled in.
  case notImplemented(method: String)
  case notConnected
  case timedOut(method: String)
  case rejectedByMessages(reason: String)
  /// The connecting peer failed code-signature validation. See § 15 on transport.
  case untrustedPeer(pid: pid_t)
  /// The IMCore selector this method depends on is absent on the running macOS version.
  /// Distinct from `notImplemented`: this one will never work here, whereas that one is
  /// merely not ported yet.
  case unavailableOnThisOS(method: String, requires: String)
  /// The server could not stand up its end of the transport at all — the socket path is
  /// unusable, or Messages' container is not writable. Distinct from `notConnected`, which
  /// means the transport is fine and no helper has arrived.
  case transportUnavailable(String)

  /// A sentence, not a case name.
  ///
  /// Without this the default rendering is `rejectedByMessages(reason: "…")` — the case
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

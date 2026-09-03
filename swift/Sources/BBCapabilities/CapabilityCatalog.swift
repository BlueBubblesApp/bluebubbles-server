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

import Foundation

extension PrivateAPICapability {

  // MARK: - Declarations

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
    category: .messages)

  public static let textFormatting = Self(
    id: "text-formatting",
    title: "Text formatting",
    summary: "Bold, italics, underline and strikethrough inside a message.",
    minimumMacOS: 15,
    evidence: .notVisibleInHeaders(
      reason: "Carried as attribute names on the attributed body, which this Mac writes on "
        + "any release — macOS 15 is where the RECEIVING Messages started rendering them, "
        + "so there is no class or selector here to look for."),
    category: .messages)

  public static let polls = Self(
    id: "polls",
    title: "Polls",
    summary: "Create a poll in a group and collect votes from everyone in it.",
    minimumMacOS: 26,
    evidence: .classExists("IMPollHelper"),
    category: .messages)

  public static let chatBackgrounds = Self(
    id: "chat-backgrounds",
    title: "Conversation backgrounds",
    summary: "Set a background image for a conversation, shared with everyone in it.",
    minimumMacOS: 26,
    evidence: .selectorExists(
      "refetchLocalTranscriptBackgroundAssetIfNecessary", onClass: "IMChat"),
    category: .organising)

  public static let screenUnknownSenders = Self(
    id: "screen-unknown-senders",
    title: "Screen unknown senders",
    summary: "See whether a sender is known, and accept one into your contacts.",
    minimumMacOS: 26,
    evidence: .selectorExists("markAsKnownAndSaveInContacts:completion:", onClass: "IMChat"),
    category: .organising)

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

  /// What is missing, grouped by the macOS that would bring it, oldest upgrade first.
  ///
  /// This is the shape the "what would I gain" part of the UI wants: one heading per
  /// release, so somebody on macOS 14 sees that 15 buys them four things and 26 buys three
  /// more, rather than a flat list they have to sort in their head.
  public func upgradePaths(from macOSMajor: Int) -> [(macOS: Int, capabilities: [PrivateAPICapability])] {
    let missing = unavailable(on: macOSMajor)
    let versions = Set(missing.map(\.minimumMacOS)).sorted()
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

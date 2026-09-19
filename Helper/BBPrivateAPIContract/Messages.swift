//  BBPrivateAPIContract: Message payloads
//  What the server asks the helper to send, and what it gets back.
//
//  Sends, reactions, attachments and stickers are one file because they are one operation
//  from the caller's side: each is a request the helper turns into an IMCore send, and each
//  answers with the same `SentMessage`. The formatting types they carry are in
//  `TextFormatting.swift`, and the app-message payload polls are built on is in
//  `Polls.swift`.

import Foundation

public struct SendMessageRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let text: String
  public let subject: String?
  public let effectId: String?
  public let replyTo: MessageGUID?
  public let replyPartIndex: Int?
  public let scanForLinks: Bool
  public let mentions: [String: [Int]]?
  /// Inline styles and effects, by UTF-16 range over `text`. Empty for plain text.
  public let formatting: [FormattedRange]
  /// When Messages should deliver this ("Send Later"). Nil sends now.
  public let scheduledFor: Date?

  public init(
    chat: ChatIdentifier,
    text: String,
    subject: String? = nil,
    effectId: String? = nil,
    replyTo: MessageGUID? = nil,
    replyPartIndex: Int? = nil,
    scanForLinks: Bool = false,
    mentions: [String: [Int]]? = nil,
    formatting: [FormattedRange] = [],
    scheduledFor: Date? = nil
  ) {
    self.chat = chat
    self.text = text
    self.subject = subject
    self.effectId = effectId
    self.replyTo = replyTo
    self.replyPartIndex = replyPartIndex
    self.scanForLinks = scanForLinks
    self.mentions = mentions
    self.formatting = formatting
    self.scheduledFor = scheduledFor
  }
}

/// How Messages files a scheduled message. Read from
/// `-[CKComposition(IMSuperFormat) messageWithGUID:…]` on macOS 26.5.2: when the composition
/// carries a `CKSendLaterPluginInfo` with a `selectedDate`, it passes the date as the
/// message's `time:` and these two values; without one it passes `[NSDate date]` and 0/0.
public enum ScheduledSend {
  /// `scheduleType`. 2 is "the user asked for Send Later".
  public static let type: UInt = 2
  /// `scheduleState`. 1 is "scheduled, not yet delivered".
  public static let state: UInt = 1
}

/// One segment of a multipart message: text and attachments interleaved in order.
public struct MessagePart: Codable, Sendable {
  public let text: String?
  public let attachmentPath: String?
  public let mention: String?
  /// Inline styles and effects, by UTF-16 range over this part's `text`.
  public let formatting: [FormattedRange]

  public init(
    text: String? = nil, attachmentPath: String? = nil, mention: String? = nil,
    formatting: [FormattedRange] = []
  ) {
    self.text = text
    self.attachmentPath = attachmentPath
    self.mention = mention
    self.formatting = formatting
  }
}

public struct SendMultipartRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let parts: [MessagePart]
  public let subject: String?
  public let effectId: String?
  public let replyTo: MessageGUID?
  public let replyPartIndex: Int?

  public init(
    chat: ChatIdentifier,
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

// MARK: - Reactions

public enum ReactionType: String, Codable, Sendable, CaseIterable {
  case love, like, dislike, laugh, emphasize, question
  /// Any emoji, with the emoji itself in `ReactionRequest.emoji`. iOS 18 / macOS 15.
  case emoji
  case removeLove = "-love"
  case removeLike = "-like"
  case removeDislike = "-dislike"
  case removeLaugh = "-laugh"
  case removeEmphasize = "-emphasize"
  case removeQuestion = "-question"
  case removeEmoji = "-emoji"

  /// The `associatedMessageType` IMCore expects.
  ///
  /// 2000-series adds a tapback, 3000-series removes the corresponding one; the offset is
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
    // Read from `-[IMEmojiTapback initWithEmoji:isRemoved:]` on macOS 26.5.2 (2006 / 3006),
    // and from every emoji reaction row in chat.db on this Mac.
    case .emoji: 2006
    case .removeEmoji: 3006
    }
  }

  /// Whether this removes a tapback rather than adding one.
  public var isRemoval: Bool { associatedMessageType >= 3000 }

  /// Whether this is an emoji tapback, which needs an emoji to go with it.
  public var isEmoji: Bool { self == .emoji || self == .removeEmoji }
}

public struct ReactionRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let target: MessageGUID
  public let reaction: ReactionType
  public let partIndex: Int
  /// The emoji, for `.emoji` and `.removeEmoji`. Ignored for the six named tapbacks.
  public let emoji: String?

  public init(
    chat: ChatIdentifier, target: MessageGUID, reaction: ReactionType, partIndex: Int = 0,
    emoji: String? = nil
  ) {
    self.chat = chat
    self.target = target
    self.reaction = reaction
    self.partIndex = partIndex
    self.emoji = emoji
  }
}

// MARK: - Attachments and stickers

public struct SendAttachmentRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let filePath: String
  public let isAudioMessage: Bool

  public init(chat: ChatIdentifier, filePath: String, isAudioMessage: Bool = false) {
    self.chat = chat
    self.filePath = filePath
    self.isAudioMessage = isAudioMessage
  }
}

/// Where a sticker sits on the message part it is placed over.
///
/// This is `stickerUserInfo` as `+[IMSticker userInfoDictionaryWithLayoutIntent:…]` builds
/// it and as chat.db stores it on the attachment row (`spw`, `sxs`, `sys`, `ssa`, `sro`):
/// a point in the parent balloon's own coordinate space, expressed as fractions of the
/// parent's preview width so every device lays the sticker out the same way whatever its
/// screen. Read back from real rows: a sticker dropped on the lower-right corner of a
/// four-character message carried `sxs 0.59, sys 1.46, ssa 0.20, sro 0.16, spw 58.7`.
///
/// `parentPreviewWidth` is the width in points the sender rendered the parent at, and the
/// scale is relative to it, so a client that does not know how wide the balloon is on
/// screen should send the width it laid the message out at and let the other devices
/// rescale. Rotation is in radians.
public struct StickerPlacement: Codable, Sendable, Equatable {
  public var xScalar: Double
  public var yScalar: Double
  public var scale: Double
  public var rotation: Double
  public var parentPreviewWidth: Double

  public init(
    xScalar: Double, yScalar: Double, scale: Double, rotation: Double = 0,
    parentPreviewWidth: Double
  ) {
    self.xScalar = xScalar
    self.yScalar = yScalar
    self.scale = scale
    self.rotation = rotation
    self.parentPreviewWidth = parentPreviewWidth
  }

  /// Over the middle of the part, about a third as wide as it, upright. What a client
  /// gets when it says "put a sticker on this message" and nothing about where.
  public static let centered = StickerPlacement(
    xScalar: 0.5, yScalar: 0.5, scale: 0.35, rotation: 0, parentPreviewWidth: 200
  )
}

/// A sticker placed on a message part.
///
/// A sticker is an ASSOCIATED message (`associatedMessageType` 1000) whose payload is a file
/// transfer flagged `isSticker`, so it needs both what an attachment needs (a file Messages
/// can read) and what a tapback needs (the message and part it attaches to).
public struct SendStickerRequest: Codable, Sendable {
  public let chat: ChatIdentifier
  public let filePath: String
  public let target: MessageGUID
  public let partIndex: Int
  public let placement: StickerPlacement
  /// Send it as a TAPBACK rather than a placed sticker: `IMStickerTapback`, association
  /// types 2007 / 3007, which snaps to the tapback position and replaces the sender's
  /// previous one instead of stacking. `placement` is ignored; Messages positions it.
  public let asTapback: Bool
  /// Removes the sticker tapback this account previously sent. Only with `asTapback`.
  public let isRemoval: Bool

  public init(
    chat: ChatIdentifier, filePath: String, target: MessageGUID, partIndex: Int = 0,
    placement: StickerPlacement = .centered, asTapback: Bool = false, isRemoval: Bool = false
  ) {
    self.chat = chat
    self.filePath = filePath
    self.target = target
    self.partIndex = partIndex
    self.placement = placement
    self.asTapback = asTapback
    self.isRemoval = isRemoval
  }
}

/// A sticker added to this Mac's sticker store, so it shows up in the picker.
///
/// The store is `stickers.stickerdb` in the `com.apple.stickersd.group` container, and the
/// only write into it Messages exposes is `-[_STKMessagesObjCStoreFacade
/// donateStickerToRecentsWithIdentifier:…]`: a DONATION to recents, which is what Messages
/// itself calls after a send. There is no "add to the saved library" call on that facade, so
/// this adds a recent and says so; see `docs/STICKER_LIBRARY.md`.
public struct SaveStickerRequest: Codable, Sendable {
  /// An image on disk. PNG, HEIC and the other UTIs Messages reads; the UTI is taken from
  /// the file rather than declared, because the store records one per representation.
  public let filePath: String
  /// The sticker's own name. Messages leaves this empty for a user-generated sticker.
  public let name: String?
  /// What VoiceOver reads, and what the picker searches. Messages fills this in from its
  /// own subject recognition ("loudly crying face"); a client that knows better should say.
  public let accessibilityName: String?

  public init(filePath: String, name: String? = nil, accessibilityName: String? = nil) {
    self.filePath = filePath
    self.name = name
    self.accessibilityName = accessibilityName
  }
}

/// What the store recorded, so a client can fetch the sticker straight back.
public struct SavedSticker: Codable, Sendable {
  /// The UUID the store filed it under, which is the id every read route takes.
  public let identifier: String
  public let externalURI: String
  public let byteCount: Int

  public init(identifier: String, externalURI: String, byteCount: Int) {
    self.identifier = identifier
    self.externalURI = externalURI
    self.byteCount = byteCount
  }
}

// MARK: - Results and queries

/// Confirmation that Messages accepted a send. The authoritative record still arrives via the
/// chat.db change detector; this is what correlates the two.
public struct SentMessage: Codable, Sendable {
  public let guid: MessageGUID
  public let chat: ChatIdentifier
  public let sentAt: Date

  public init(guid: MessageGUID, chat: ChatIdentifier, sentAt: Date) {
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

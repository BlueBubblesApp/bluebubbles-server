//  IMCoreTapbacks
//  Reactions, which IMCore models as messages that associate themselves with another.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ObjectiveC.runtime

// MARK: - Tapbacks

/// A tapback sent the way Messages sends one.
///
/// `-[IMChat(CKMessageAcknowledgment) sendTapback:forChatItem:languageIdentifier:]`,
/// disassembled on macOS 26.5.2 and again on 27.0.1, reduces to: an `IMTapback` (or
/// `IMEmojiTapback`), the part chat item's `guid`, `originalMessagePartRange` and
/// `threadIdentifierForTapback`, and a summary from ChatKit's
/// `+[IMChat configureMessageSummaryInfoForChatItem:]`, handed to the SIX-argument
/// `IMTapbackSender` initializer, whose `send` builds and sends the message. That is what is
/// done here, value for value; see `messagesArguments(for:chatItemType:chatType:)`.
///
/// **Not the three-argument `initWithTapback:chat:messagePartChatItem:`**, though it looks
/// like the same thing with less work. It derives the same four values except the summary,
/// which it takes from `-[IMMessagePartChatItem messageSummaryInfo]`, a getter Messages never
/// calls. On 27.0.1 that raises `NSInvalidArgumentException` ("-encodeObject:forKey: only
/// defined for abstract class") for EVERY tapback, named and emoji alike, before anything is
/// sent, while Messages sends them fine. It stays only as the fallback for a release where a
/// piece of Messages' recipe is missing.
///
/// This is the only way to send an EMOJI tapback: `IMEmojiTapback` carries the emoji and
/// the sender writes it into `associatedMessageEmoji`. It is also what Messages uses for
/// the six named ones, so they go through it too when it exists, which fixes what the
/// association-initializer path got wrong (a bare target GUID where Messages writes
/// `p:<part>/<guid>`, and a range of `(part, 1)` where Messages writes the part's own).
/// That path stays as the fallback for a macOS without `IMTapbackSender`.
enum IMTapbacks {

  /// Whether Messages' own sender is available here.
  ///
  /// The SENDER only. Whether the tapback OBJECT it needs can be built is a separate
  /// question with a different answer per release, and `canBuild(_:)` is that question:
  /// see the comment there for why the two were once conflated and what it cost.
  static var senderAvailable: Bool {
    guard let sender = IMCoreRuntime.lookUpClass("IMTapbackSender") else { return false }
    return IMCoreRuntime.instancesRespond(sender, to: "initWithTapback:chat:messagePartChatItem:")
  }

  /// Whether `tapback(_:emoji:)` can actually construct this reaction on this macOS.
  ///
  /// **This is not the same question as `senderAvailable`, and treating it as one breaks
  /// every reaction on Sonoma.** `IMTapbackSender` and its initializer are present on macOS
  /// 14.6.1, so a caller keyed on the sender takes the modern branch, and then
  /// `+[IMTapback tapbackWithAssociatedMessageType:]` is missing, because Apple NARROWED
  /// that constructor rather than adding it: 14.6.1 has only the
  /// `…:messageSummaryInfo:` and `…:representation:` forms. The association-initializer
  /// fallback, which sends all six named tapbacks correctly, is never reached.
  /// Measured; `docs/MACOS_COMPATIBILITY.md` §3b, "Named tapbacks".
  ///
  /// Asked per RECEIVED REACTION rather than once, because the two kinds need different
  /// things and a release may have one without the other.
  ///
  /// MEASURED across all three releases since: the one-argument constructor arrived in
  /// **macOS 15**, alongside `IMEmojiTapback`, so both kinds take the Messages path on 15
  /// and 26 and only 14 falls back. The per-kind question is therefore answered the same
  /// way on every release we support today, and it stays asked per kind, because that is
  /// what makes the next release's answer a measurement rather than an assumption.
  static func canBuild(_ reaction: ReactionType) -> Bool {
    if reaction.isEmoji {
      guard let emojiTapback = IMCoreRuntime.lookUpClass("IMEmojiTapback") else { return false }
      return IMCoreRuntime.instancesRespond(emojiTapback, to: "initWithEmoji:isRemoved:")
    }
    guard let tapback = IMCoreRuntime.lookUpClass("IMTapback") else { return false }
    return IMCoreRuntime.responds(tapback as AnyObject, to: "tapbackWithAssociatedMessageType:")
  }

  /// The tapback object: `IMEmojiTapback` for an emoji, `IMTapback` for a named one.
  static func tapback(_ reaction: ReactionType, emoji: String?) throws -> AnyObject {
    if reaction.isEmoji {
      guard let emoji, !emoji.isEmpty else {
        throw PrivateAPIErrorShim.rejected("an emoji reaction needs an emoji")
      }
      let type: AnyClass = try IMCoreRuntime.requireClass("IMEmojiTapback")
      return try IMCoreRuntime.create(
        type, "initWithEmoji:isRemoved:", [emoji, reaction.isRemoval])
    }
    let type: AnyClass = try IMCoreRuntime.requireClass("IMTapback")
    guard
      let tapback = try IMCoreRuntime.invoke(
        type as AnyObject, "tapbackWithAssociatedMessageType:",
        [reaction.associatedMessageType])
    else {
      throw PrivateAPIErrorShim.rejected("IMTapback would not build type \(reaction.rawValue)")
    }
    return tapback
  }

  /// A STICKER tapback: `IMStickerTapback`, which carries the sticker's transfer GUID
  /// rather than an emoji or a type. Types 2007 / 3007 (`initWithTransferGUID:isRemoved:`,
  /// disassembled). The transfer has to exist first (`IMStickers.mediaObject` creates and
  /// registers it) and the same sender sends it as every other tapback.
  static func stickerTapback(transferGUID: String, isRemoved: Bool) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMStickerTapback")
    return try IMCoreRuntime.create(
      type, "initWithTransferGUID:isRemoved:", [transferGUID, isRemoved])
  }

  static let senderInitializer =
    "initWithTapback:chat:messageGUID:messagePartRange:messageSummaryInfo:threadIdentifier:"
  static let partOnlySenderInitializer = "initWithTapback:chat:messagePartChatItem:"
  static let chatItemConstructor = "chatItemWithIMChatItem:balloonMaxWidth:"
  static let summaryBuilder = "configureMessageSummaryInfoForChatItem:"

  /// What Messages hands `IMTapbackSender`, read the way Messages reads it.
  struct SenderArguments {
    let guid: String
    let range: NSRange
    /// Nil when ChatKit builds none; passed as an explicit nil, as Messages would.
    let summary: AnyObject?
    let threadIdentifier: String?
  }

  /// The four values, from the part and from ChatKit, exactly as Messages gathers them.
  ///
  /// The summary is built from a CHATKIT chat item, because that is what
  /// `configureMessageSummaryInfoForChatItem:` takes: it branches on `CKTextMessagePartChatItem`,
  /// `CKAttachmentMessagePartChatItem` and `CKTranscriptPluginChatItem`, and for text
  /// summarises with plain strings (`[[item text] string]`), which is why it does not hit
  /// what `-[IMMessagePartChatItem messageSummaryInfo]` hits. The width only sizes the
  /// balloon a transcript would draw; nothing here draws one, and the summary reads none of
  /// it.
  ///
  /// The classes are parameters so a test can hand in stand-ins; in Messages they are
  /// `CKChatItem` and `IMChat`.
  static func messagesArguments(
    for part: AnyObject, chatItemType: AnyClass, chatType: AnyClass
  ) throws -> SenderArguments {
    guard let guid = try IMCoreRuntime.string(part, "guid"), !guid.isEmpty else {
      throw PrivateAPIErrorShim.rejected("that message part has no GUID to react to")
    }
    guard
      let range = try IMCoreRuntime.invoke(part, "originalMessagePartRange") as? NSValue
    else {
      throw PrivateAPIErrorShim.rejected("that message part reports no range")
    }
    guard
      let chatItem = try IMCoreRuntime.invoke(
        chatItemType as AnyObject, chatItemConstructor, [part, NSNumber(value: 320.0)])
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not describe that message part")
    }
    let summary = try IMCoreRuntime.invoke(chatType as AnyObject, summaryBuilder, [chatItem])
    return SenderArguments(
      guid: guid, range: range.rangeValue, summary: summary,
      threadIdentifier: try IMCoreRuntime.string(part, "threadIdentifierForTapback"))
  }

  /// Whether every piece of Messages' recipe is here: the sender's six-argument initializer,
  /// ChatKit's chat-item constructor and its summary builder. 15, 26 and 27 have all three
  /// (`docs/headers/`); 14.6.1 has no `chatItemWithIMChatItem:balloonMaxWidth:`, and its
  /// tapbacks take the association fallback in `react(_:)` anyway.
  static func messagesRecipe() -> (chatItemType: AnyClass, chatType: AnyClass)? {
    guard let sender = IMCoreRuntime.lookUpClass("IMTapbackSender"),
      IMCoreRuntime.instancesRespond(sender, to: senderInitializer),
      let chatItemType = IMCoreRuntime.lookUpClass("CKChatItem"),
      IMCoreRuntime.responds(chatItemType as AnyObject, to: chatItemConstructor),
      let chatType = IMCoreRuntime.lookUpClass("IMChat"),
      IMCoreRuntime.responds(chatType as AnyObject, to: summaryBuilder)
    else { return nil }
    return (chatItemType, chatType)
  }

  /// Sends, and returns the GUID of the tapback's own message, or nil if it cannot be named.
  static func send(
    _ tapback: AnyObject, chat: IMChat, part: AnyObject, target: MessageGUID
  ) throws -> String? {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMTapbackSender")
    let sender: AnyObject
    if let recipe = messagesRecipe() {
      let arguments = try messagesArguments(
        for: part, chatItemType: recipe.chatItemType, chatType: recipe.chatType)
      sender = try IMCoreRuntime.create(
        type, senderInitializer,
        [
          tapback, chat.object, arguments.guid as NSString, NSValue(range: arguments.range),
          arguments.summary ?? NSNull(),
          arguments.threadIdentifier.map { $0 as NSString } ?? NSNull(),
        ])
    } else {
      sender = try IMCoreRuntime.create(
        type, partOnlySenderInitializer, [tapback, chat.object, part])
    }
    return try send(through: sender, chat: chat, target: target)
  }

  /// The send itself, apart from building the sender, so a test can hand it a stand-in:
  /// the real `IMTapbackSender` sends a real message.
  ///
  /// What `-send` answers differs per release, and its `(id)` return does not say which:
  ///   - 27.0.1 answers `[message guid]`, a STRING (disassembled). Asking that for its own
  ///     `guid` fails, which reports a reaction that WAS sent as a failure.
  ///   - Any other object is read for its `guid`. `docs/PRIVATE_API_SURFACE.md` records
  ///     the message itself for 26.5.2, which a Mac on 27 cannot re-measure.
  ///   - 14 and 15 are void, so the message is found on the chat, and only if it is
  ///     confirmably this tapback. See `IMChat.sentTapback(since:on:)`.
  static func send(through sender: AnyObject, chat: IMChat, target: MessageGUID) throws -> String? {
    let before = try chat.lastSentMessageGUID()
    let answer =
      try IMCoreRuntime.invoke(sender, "send")
      ?? chat.sentTapback(since: before, on: target.rawValue)
    if let guid = answer as? String { return guid }
    // `try?`: the send has already happened, so a GUID that cannot be read is a GUID that
    // is missing, and `IMCoreBridge.sent` refuses a missing one.
    return answer.flatMap { (try? IMCoreRuntime.string($0, "guid")) ?? nil }
  }
}

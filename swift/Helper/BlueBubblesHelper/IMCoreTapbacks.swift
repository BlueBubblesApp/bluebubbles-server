//  IMCoreTapbacks
//  Reactions, which IMCore models as messages that associate themselves with another.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

// MARK: - Tapbacks

/// A tapback sent the way Messages sends one.
///
/// `-[IMChat(CKMessageAcknowledgment) sendTapback:forChatItem:languageIdentifier:]`,
/// disassembled on macOS 26.5.2, reduces to: an `IMTapback` (or `IMEmojiTapback`), the
/// part chat item's GUID, `originalMessagePartRange`, a summary from
/// `+[IMChat configureMessageSummaryInfoForChatItem:]` and `threadIdentifierForTapback`,
/// all handed to `IMTapbackSender`, whose `send` builds and sends the message.
/// `IMTapbackSender` also has `initWithTapback:chat:messagePartChatItem:`, which derives
/// those from the part itself; that is what is used here.
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
    return (sender as AnyObject).responds(to: NSSelectorFromString("alloc"))
      && class_getInstanceMethod(
        sender, NSSelectorFromString("initWithTapback:chat:messagePartChatItem:")) != nil
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
  /// Measured; `docs/SONOMA_COMPATIBILITY.md` §2.1.
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
      return class_getInstanceMethod(
        emojiTapback, NSSelectorFromString("initWithEmoji:isRemoved:")) != nil
    }
    guard let tapback = IMCoreRuntime.lookUpClass("IMTapback") else { return false }
    return (tapback as AnyObject).responds(
      to: NSSelectorFromString("tapbackWithAssociatedMessageType:"))
  }

  /// The tapback object: `IMEmojiTapback` for an emoji, `IMTapback` for a named one.
  static func tapback(_ reaction: ReactionType, emoji: String?) throws -> AnyObject {
    if reaction.isEmoji {
      guard let emoji, !emoji.isEmpty else {
        throw PrivateAPIErrorShim.rejected("an emoji reaction needs an emoji")
      }
      let type: AnyClass = try IMCoreRuntime.requireClass("IMEmojiTapback")
      guard
        let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
          .takeUnretainedValue(),
        let tapback = try IMCoreRuntime.invoke(
          allocated, "initWithEmoji:isRemoved:", [emoji, reaction.isRemoval])
      else {
        throw PrivateAPIErrorShim.rejected("IMEmojiTapback would not initialise for \(emoji)")
      }
      return tapback
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
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue(),
      let tapback = try IMCoreRuntime.invoke(
        allocated, "initWithTransferGUID:isRemoved:", [transferGUID, isRemoved])
    else {
      throw PrivateAPIErrorShim.rejected("IMStickerTapback would not initialise")
    }
    return tapback
  }

  /// Sends, and returns the message `send` answered with: the tapback's own `IMMessage`.
  static func send(_ tapback: AnyObject, chat: IMChat, part: AnyObject) throws -> AnyObject? {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMTapbackSender")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue(),
      let sender = try IMCoreRuntime.invoke(
        allocated, "initWithTapback:chat:messagePartChatItem:", [tapback, chat.object, part])
    else {
      throw PrivateAPIErrorShim.rejected("IMTapbackSender would not initialise")
    }
    return try IMCoreRuntime.invoke(sender, "send")
  }
}

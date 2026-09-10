//  IMCoreMuting
//  Per-chat mute state, which IMCore keeps outside the chat object.
//
//  See `IMCoreChats.swift` for why these wrappers exist and how selectors are sourced.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

enum IMMutedChats {

  /// The shared list, or nil on a macOS without the class.
  ///
  /// **Optional, not throwing.** Absent is a supported configuration with a working path
  /// behind it, not a failure, and the type is what says so: a `throws` signature here is
  /// what made every caller open with `try list()` and strand the fallback.
  static func list() -> AnyObject? {
    guard IMCoreRuntime.lookUpClass("IMMutedChatList") != nil else { return nil }
    return try? IMCoreRuntime.sharedInstance(
      ofClass: "IMMutedChatList", accessors: ["sharedList", "sharedInstance"]
    )
  }

  /// The identifiers this chat is muted under. IMCore derives them; they are not
  /// constructible from a chat GUID by string manipulation.
  ///
  /// List-only by nature: the identifiers exist to key the list, so there is nothing to
  /// ask for on a release without one.
  static func muteIdentifiers(for chat: IMChat, in list: AnyObject) throws -> AnyObject {
    guard
      let identifiers = try IMCoreRuntime.invoke(
        list, "muteIdentifiersForChat:", [chat.object]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "IMMutedChatList has no mute identifiers for that conversation"
      )
    }
    return identifiers
  }

  /// The unmute instant, or nil when the chat has no entry at all.
  ///
  /// A DATE rather than a bool, because the two questions a client asks ("is it muted"
  /// and "until when") are one lookup, and `-isMutedChat:` is derived from this anyway.
  ///
  /// Both stores answer in the same units, so the caller cannot tell which one replied:
  /// `-muteUntilDate` is the property the list's entry is written from.
  static func unmuteDate(for chat: IMChat) throws -> Date? {
    if let list = list() {
      return try IMCoreRuntime.invoke(list, "unmuteDateForChat:", [chat.object]) as? Date
    }
    return try IMCoreRuntime.send(chat.object, "muteUntilDate") as? Date
  }

  /// IMCore's own answer, used to cross-check the date rather than to replace it.
  ///
  /// The list's form takes an argument, so it cannot go through `IMCoreRuntime.bool`: that
  /// one uses a typed IMP and only handles zero-argument getters. `callReturningBool` exists
  /// because a dropped BOOL return is indistinguishable from a void method. The chat's `-isMuted` IS a zero-argument getter, so it takes the
  /// typed path.
  static func isMuted(_ chat: IMChat) throws -> Bool {
    if let list = list() {
      return try IMCoreRuntime.callReturningBool(list, "isMutedChat:", [chat.object])
    }
    return try IMCoreRuntime.bool(chat.object, "isMuted")
  }

  /// Mutes until `date`, or indefinitely when it is nil.
  ///
  /// **`nil` is turned into `Date.distantFuture` here rather than passed through.** IMCore
  /// stores `[untilDate timeIntervalSince1970]`, so a nil date stores 0.0 and the chat
  /// reads back as unmuted: a mute that reports success and does nothing.
  static func mute(_ chat: IMChat, until date: Date?, sync: Bool) throws {
    let untilDate = date ?? Date.distantFuture

    if let list = list() {
      // The three-argument form carries `syncToPairedDevice:`, which is the whole reason
      // to prefer the list over `IMChat -setMuteUntilDate:`.
      if IMCoreRuntime.responds(
        list, to: NSSelectorFromString("muteChat:untilDate:syncToPairedDevice:")
      ) {
        try IMCoreRuntime.invoke(
          list, "muteChat:untilDate:syncToPairedDevice:",
          [chat.object, untilDate as NSDate, sync]
        )
        return
      }
      if IMCoreRuntime.responds(list, to: NSSelectorFromString("muteChat:untilDate:")) {
        try IMCoreRuntime.invoke(
          list, "muteChat:untilDate:", [chat.object, untilDate as NSDate]
        )
        return
      }
    }

    // The property on the chat, which is all of macOS 14 and the tail of every ladder
    // above. It decides `syncToPairedDevice` for us, so `sync` is not refused here: the
    // request is honoured, just not steered.
    try IMCoreRuntime.invoke(chat.object, "setMuteUntilDate:", [untilDate as NSDate])
  }

  /// Removes the entry outright.
  ///
  /// Not "mute until a date in the past". Both read as unmuted, but only this one takes the
  /// conversation out of the list Messages syncs: where there is a list. Where there is
  /// not, a nil `muteUntilDate` is the only spelling of "not muted" there is, and it is the
  /// same one Messages writes.
  static func unmute(_ chat: IMChat, sync: Bool) throws {
    if let list = list(),
      IMCoreRuntime.responds(
        list, to: NSSelectorFromString("unmuteChatWithMuteIdentifiers:syncToPairedDevice:"))
    {
      try IMCoreRuntime.invoke(
        list, "unmuteChatWithMuteIdentifiers:syncToPairedDevice:",
        [try muteIdentifiers(for: chat, in: list), sync]
      )
      return
    }
    try IMCoreRuntime.invoke(chat.object, "setMuteUntilDate:", [NSNull()])
  }
}

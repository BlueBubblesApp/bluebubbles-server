//  IMCoreObjects
//  Typed wrappers over the IMCore objects the port needs.
//
//  Each is a thin box around an `AnyObject` reached through `IMCoreRuntime`, so a selector
//  that moved in a macOS release fails on the one operation that needed it rather than
//  anywhere else. The alternative — the shipping helper's approach — is a hand-maintained
//  header dump per macOS version, where a moved selector is a link error and a link error is
//  a helper that never loads. dyld reports nothing when it declines an insert, so that
//  failure is invisible: Messages simply starts without the Private API.
//
//  Selector names below are transcribed from
//  `Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m`, with the line noted. They are
//  the authoritative record of what actually works, including the workarounds that file has
//  accumulated.
//
//  **None of these call sites can be tested here.** They need Messages.app running with the
//  helper injected, which needs SIP disabled. `IMCoreRuntimeTests` covers the dispatch
//  machinery underneath them, which is where a mistake takes down the user's Messages.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import CoreGraphics
import Foundation
import HelperShared
import ImageIO
import ObjectiveC.runtime

/// `IMChatRegistry` — the map from chat GUID to live chat object.
enum IMChatRegistry {

  /// Looks up an existing chat. Nil when Messages does not know the GUID.
  ///
  /// ObjC: `[[IMChatRegistry sharedInstance] existingChatWithGUID:]` (BlueBubblesHelper.m:159).
  ///
  /// Deliberately `existingChatWithGUID:` rather than a variant that creates one — a typo
  /// in a client's GUID should be an error, not a new empty conversation.
  static func chat(guid: String) throws -> IMChat? {
    let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
    guard let object = try IMCoreRuntime.send(registry, "existingChatWithGUID:", guid) else {
      return nil
    }
    return IMChat(object)
  }

  /// Raises `rejectedByMessages` rather than returning nil, for the many call sites where
  /// "no such chat" is the whole answer.
  static func requireChat(guid: String) throws -> IMChat {
    guard let chat = try chat(guid: guid) else {
      throw PrivateAPIErrorBridge.noSuchChat(guid)
    }
    return chat
  }
}

/// `CKConversation` — the ChatKit view of a chat.
///
/// Participant changes go through this rather than `IMChat`: ChatKit is what enforces the
/// recipient limit, and `canInsertMoreRecipients` is the only way to know before trying.
enum CKConversationList {

  static func conversation(guid: String) throws -> CKConversation? {
    // `sharedConversationList`, and resolved at call time rather than load time.
    // ChatKit is not loaded when the dylib is inserted, so a reference taken at load
    // would be nil forever — the comment at BlueBubblesHelper.m:177 records exactly this.
    let list = try IMCoreRuntime.sharedInstance(
      ofClass: "CKConversationList", accessors: ["sharedConversationList"]
    )
    guard
      let object = try IMCoreRuntime.send(
        list, "conversationForExistingChatWithGUID:", guid
      )
    else { return nil }
    return CKConversation(object)
  }
}

struct IMChat {
  let object: AnyObject
  init(_ object: AnyObject) { self.object = object }

  var guid: String? { try? IMCoreRuntime.string(object, "guid") ?? nil }

  /// ObjC: `[chat setLocalUserIsTyping:]` (BlueBubblesHelper.m:194).
  ///
  /// Takes a BOOL, so it goes through a typed IMP — `perform` would pass the boxed
  /// NSNumber's pointer as the byte, and a non-zero address always reads as `true`.
  func setLocalUserIsTyping(_ isTyping: Bool) throws {
    try IMCoreRuntime.callBool(object, "setLocalUserIsTyping:", isTyping)
  }

  /// Whether the other party is typing.
  ///
  /// ObjC: `chat.lastIncomingMessage.isTypingMessage` (BlueBubblesHelper.m:205). Note it
  /// is derived from the last incoming message rather than read directly — there is no
  /// "is the other person typing" property, only a message that *is* a typing indicator.
  func isRemoteTyping() throws -> Bool {
    guard let lastIncoming = try IMCoreRuntime.send(object, "lastIncomingMessage") else {
      return false
    }
    return try IMCoreRuntime.bool(lastIncoming, "isTypingMessage")
  }

  /// ObjC: `[chat markAllMessagesAsRead]` (BlueBubblesHelper.m:216).
  func markAllMessagesAsRead() throws {
    try IMCoreRuntime.invoke(object, "markAllMessagesAsRead")
  }

  /// ObjC: `[chat markLastMessageAsUnread]` (BlueBubblesHelper.m:218).
  func markLastMessageAsUnread() throws {
    try IMCoreRuntime.invoke(object, "markLastMessageAsUnread")
  }

  /// ObjC: `[chat _setDisplayName:]` (BlueBubblesHelper.m:239).
  ///
  /// The underscore is not a typo — the public `setDisplayName:` does not exist on IMChat,
  /// and this private one is what the shipping helper uses.
  /// ObjC: `[chat leave]`.
  ///
  /// `canLeaveChat` is consulted first because IMCore's `leave` on a one-to-one chat is a
  /// silent no-op — the caller would see success and the chat would still be there.
  /// ObjC: `[chat leave]`, falling back to `leaveiMessageGroup` (BlueBubblesHelper.m:576).
  ///
  /// Both are tried because the reference does: `leave` is not present on every macOS this
  /// runs on. `canLeaveChat` is consulted first only to turn the common no-op — leaving a
  /// one-to-one chat, which has nobody to leave — into an explanation rather than silence.
  func leave() throws {
    if let can = try? IMCoreRuntime.bool(object, "canLeaveChat"), can == false {
      throw PrivateAPIErrorShim.rejected(
        "this conversation cannot be left — one-to-one chats have nobody to leave"
      )
    }
    // ORDER MATTERS, and `leaveConversation` leads because `leave` is the one that stopped
    // working. macOS 26 carries both: `leave` still answers `responds(to:)` and still
    // returns without complaint, and the conversation is still there afterwards — the same
    // shape as `inviteParticipantsToiMessageChat:`, which was removed outright, except this
    // one fails quietly instead. `leaveConversation` is the name the current runtime
    // actually acts on.
    //
    // The older names stay as fallbacks: this file supports macOS versions where
    // `leaveConversation` does not exist, and `responds(to:)` picks whichever is present.
    // ORDER MATTERS, and `leaveConversation` leads — but see the caveat below before
    // trusting that it helps.
    //
    // WHAT IS ESTABLISHED: `leave` returns without complaint on macOS 26 and the
    // conversation is still there afterwards. No participant-change row appears in
    // `chat.db`, so nothing happened. That is the same shape as the participant selectors,
    // which were removed outright — except this one fails quietly instead of trapping.
    //
    // WHAT IS NOT: whether `leaveConversation` fixes it. It exists on the plain macOS
    // `IMChat`, which is the only variant a standalone probe can load; Messages runs the
    // CATALYST one, and this project has already been bitten once by assuming the two
    // match. Preferring it here changed nothing observable, which is consistent BOTH with
    // "it is absent in the Catalyst runtime so we fell back to `leave`" and with "it ran
    // and is also a no-op". Those cannot be told apart from outside the host: `os_log` from
    // an injected dylib in a sandboxed process does not reach `log show` on this macOS, as
    // HelperSocketClient notes, so the obvious instrumentation is unavailable.
    //
    // Deciding it needs the helper to report the selector it chose back over the SOCKET.
    // Until then this ordering is harmless — `responds(to:)` skips what is absent — and
    // must not be read as a fix.
    for selector in ["leaveConversation", "leave", "leaveiMessageGroup"]
    where IMCoreRuntime.responds(object, to: NSSelectorFromString(selector)) {
      try IMCoreRuntime.invoke(object, selector)
      return
    }
    throw PrivateAPIErrorShim.rejected("this macOS has no leave selector on IMChat")
  }

  /// Deletes the conversation's history.
  ///
  /// `deleteAllHistory` is the closest IMCore equivalent of what the shipping helper calls
  /// `delete-chat`. It removes the messages; the conversation row itself is the daemon's
  /// to reap. Naming that here rather than pretending the chat vanishes.
  ///
  /// Returns IMCore's own BOOL, which must not be discarded: without it a clear that
  /// deleted nothing is indistinguishable from one that emptied the conversation.
  @discardableResult
  func deleteAllHistory() throws -> Bool {
    try IMCoreRuntime.callReturningBool(object, "deleteAllHistory")
  }

  // MARK: Filtering
  //
  // Reads first. Every one of these is a cache IMCore keeps for the UI's sake, so they
  // answer without a round trip, and a missing one is reported as a default rather than as
  // a failure: a client asking where a chat sits in the filters should not lose the whole
  // answer because one flag moved.

  func filterState() throws -> ChatFilterState {
    ChatFilterState(
      isFiltered: (try? IMCoreRuntime.integer(object, "isFiltered")) ?? 0,
      filterCategory: (try? IMCoreRuntime.integer(object, "filterCategory")) ?? 0,
      isKnownSender: (try? IMCoreRuntime.bool(object, "cachedIsKnownSender")) ?? false,
      isInUnknownSendersFilter: (try? IMCoreRuntime.bool(object, "inUnknownSendersFilter"))
        ?? false,
      wasDetectedAsSMSSpam: (try? IMCoreRuntime.bool(object, "wasDetectedAsSMSSpam")) ?? false,
      canReportJunk: (try? IMCoreRuntime.send(object, "_messageToReportJunk")) != nil
    )
  }

  /// How many messages a spam report would cover.
  ///
  /// This is what makes a dry run possible: the count is readable without reporting
  /// anything, so the path can be exercised against a real conversation.
  func messagesToReportAsSpamCount() throws -> Int {
    let messages = (try? IMCoreRuntime.objects(object, "allMessagesToReportAsSpam")) ?? []
    return messages.count
  }

  /// ObjC: `-markAsSpam:` / `-markAsSpam:isJunkReportedToCarrier:`.
  ///
  /// **The argument is a COUNT, not a reason code**, and the return is a count too — read
  /// from the disassembly rather than from the header, which says only `unsigned long long`:
  /// the method runs a `MarkAsSpam` query, calls `-_setCountOfMessagesMarkedAsSpam:` and
  /// returns an `integerValue`. So it is handed the number of messages this conversation
  /// has to report, which is `-allMessagesToReportAsSpam`'s count.
  ///
  /// See `docs/CHAT_CONTROLS_PLAN.md` §5.2. If this turns out to be a category after all,
  /// the mistake is contained here: nothing above this line lets a client choose the number.
  func markAsSpam(count: Int, reportToCarrier: Bool) throws -> Int {
    let quantity = NSNumber(value: count)
    if IMCoreRuntime.responds(
      object, to: NSSelectorFromString("markAsSpam:isJunkReportedToCarrier:")
    ) {
      return try IMCoreRuntime.callReturningInteger(
        object, "markAsSpam:isJunkReportedToCarrier:", [quantity, reportToCarrier]
      )
    }
    return try IMCoreRuntime.callReturningInteger(object, "markAsSpam:", [quantity])
  }

  /// ObjC: `-reportJunk`, plus the carrier relay when asked for.
  ///
  /// TWO GENERATIONS, and macOS 26 renamed both halves at once:
  ///
  ///   26        -reportJunk                    -reportJunkToCarrierViaRelay:(BOOL)
  ///   14, 15    -reportJunkToCarrier           (the same call does both)
  ///
  /// On 14 and 15 there is only `-reportJunkToCarrier`, which reports and relays together —
  /// so `toCarrier` cannot be honoured as a choice there. It is honoured as a FLOOR: the
  /// report happens either way, and asking not to relay does not suppress it. Refusing the
  /// whole call to respect the flag would be worse; reporting junk is the point.
  ///
  /// **The return has to be reconstructed on the older path.** `-reportJunk` returns whether
  /// there was anything to report; `-reportJunkToCarrier` returns void. So the count that
  /// `-reportJunk` is answering about is read first, from `-allMessagesToReportAsSpam`, which
  /// is on all three releases and is what `messagesToReportAsSpamCount()` already uses.
  ///
  /// Measured on 14.6.1, 15.6.1 and 26.5.2 — `docs/MACOS_COMPATIBILITY.md` §2b.
  func reportJunk(toCarrier: Bool) throws -> Bool {
    if IMCoreRuntime.responds(object, to: NSSelectorFromString("reportJunk")) {
      let reported = try IMCoreRuntime.callReturningBool(object, "reportJunk")
      if toCarrier,
        IMCoreRuntime.responds(
          object, to: NSSelectorFromString("reportJunkToCarrierViaRelay:")
        )
      {
        try IMCoreRuntime.invoke(object, "reportJunkToCarrierViaRelay:", [true])
      }
      return reported
    }

    guard IMCoreRuntime.responds(object, to: NSSelectorFromString("reportJunkToCarrier"))
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "reportJunk", requires: "-reportJunk or -reportJunkToCarrier on IMChat")
    }
    // Read before reporting: afterwards the conversation has been dealt with and the list
    // is no longer the answer to "was there anything to report".
    let pending = try messagesToReportAsSpamCount()
    try IMCoreRuntime.invoke(object, "reportJunkToCarrier")
    return pending > 0
  }

  /// ObjC: `-updateIsFiltered:`, or recovery from Junk, which is not the same operation.
  ///
  /// `updateIsFiltered:` moves the chat between filters. Recovery has to undo the junk state
  /// as well, and macOS 26 folded both into one call:
  ///
  ///   26        -recoverFromJunkTo:(category)      undoes junk AND sets the filter
  ///   14, 15    -recoverFromJunk                   undoes junk only — the filter is ours
  ///
  /// So the older path is two calls, in that order. It used to be one: the `else` fell
  /// straight through to `updateIsFiltered:`, which moved the conversation out of the Junk
  /// FILTER while leaving it marked as junk — half the job, silently, on both releases that
  /// needed it. `docs/SEQUOIA_COMPATIBILITY.md` §3.
  func updateFilter(category: Int, recovering: Bool) throws {
    if recovering {
      if IMCoreRuntime.responds(object, to: NSSelectorFromString("recoverFromJunkTo:")) {
        try IMCoreRuntime.invoke(object, "recoverFromJunkTo:", [NSNumber(value: category)])
        return
      }
      if IMCoreRuntime.responds(object, to: NSSelectorFromString("recoverFromJunk")) {
        try IMCoreRuntime.invoke(object, "recoverFromJunk")
        // Falls through to the filter move below, which is the other half.
      }
    }
    try IMCoreRuntime.invoke(object, "updateIsFiltered:", [NSNumber(value: category)])
  }

  /// Asks the daemon to download this conversation's background asset.
  ///
  /// Void and completion-less all the way down — it reaches
  /// `refetchChatBackgroundIfNeededForChatIdentifier:style:account:` on the remote daemon,
  /// which downloads in the background. "Did it work" is answered by the file appearing in
  /// `~/Library/Messages/TranscriptBackgroundCache`, not by this call.
  func refetchTranscriptBackground() throws {
    try IMCoreRuntime.invoke(object, "refetchLocalTranscriptBackgroundAssetIfNecessary")
  }

  /// Whether this macOS supports editing a sent message. Ventura and later.
  func supportsEditing() -> Bool {
    (try? IMCoreRuntime.bool(object, "_supportsEditMessage")) == true
  }

  /// ObjC: `editMessageItem:atPartIndex:…backwardCompatabilityText:` (BlueBubblesHelper.m:322).
  ///
  /// THREE selector generations, newest first — the reference does the same, and for the
  /// same reason: Apple has changed this signature twice and a build that only knows the
  /// newest silently cannot edit on macOS 14 or 15.
  ///
  ///   macOS 26   …withNewPartText:newPartTranslation:backwardCompatabilityText:
  ///   macOS 14+  …withNewPartText:backwardCompatabilityText:
  ///   older      editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:
  ///
  /// Apple's own spelling of "Compatability" is not a typo on our part. A corrected
  /// spelling is simply a selector that does not exist.
  func editMessage(
    item: AnyObject,
    partIndex: Int,
    newText: NSAttributedString,
    backwardCompatibilityText: NSAttributedString
  ) throws {
    let candidates: [(String, [Any])] = [
      (
        "editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:",
        [item, partIndex, newText, NSNull(), backwardCompatibilityText]
      ),
      (
        "editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:",
        [item, partIndex, newText, backwardCompatibilityText]
      ),
      (
        "editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:",
        [item, partIndex, newText, backwardCompatibilityText]
      ),
    ]
    for (selector, arguments) in candidates
    where IMCoreRuntime.responds(object, to: NSSelectorFromString(selector)) {
      try IMCoreRuntime.invoke(object, selector, arguments)
      return
    }
    throw PrivateAPIErrorShim.rejected(
      "this macOS has no message-edit selector IMChat responds to"
    )
  }

  /// ObjC: `retractMessagePart:` — what a client calls "unsend".
  /// Cancels a scheduled message before it is delivered.
  ///
  /// Takes the message ITEM, not the GUID. MEASURED: the GUID form,
  /// `cancelScheduledMessageWithGUID:destinations:cancelType:` with nil destinations,
  /// returns without raising and leaves the row exactly as it was — still
  /// `schedule_state 2`, still due at its delivery time. The item form is what IMChat's own
  /// logging calls "(IMChat) Cancel scheduled message items", and it is the one the
  /// transcript's cancel action reaches.
  ///
  /// Cancel type 1 is the value IMCore's own path passes.
  func cancelScheduledMessage(item: AnyObject) throws {
    let selector = "cancelScheduledMessageItem:cancelType:"
    guard IMCoreRuntime.responds(object, to: NSSelectorFromString(selector)) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "cancelScheduledMessage", requires: selector
      )
    }
    try IMCoreRuntime.invoke(object, selector, [item, UInt(1)])
  }

  /// Moves a scheduled message, or releases it to send now.
  ///
  /// ObjC: `-[IMChat editScheduledMessageItem:scheduleType:deliveryTime:]`, with the plural
  /// as the fallback — the transcript's own "Send Now" goes through the plural because a
  /// scheduled SECTION can hold several messages due at the same time
  /// (`-[CKTranscriptCollectionViewController dateCellRequestedScheduledMessageModification:
  /// scheduleType:deliveryTime:]` fetches them with `messagesForScheduledMessageSectionWithTranscriptItem:`).
  /// Addressing one message, the singular is the direct form.
  ///
  /// Send now is `scheduleType 0` with a NIL delivery time — the values that cell passes,
  /// and the branch IMCore logs as "Modifying scheduled time to be immediate". Rescheduling
  /// keeps `ScheduledSend.type` and gives the new date.
  func editScheduledMessage(item: AnyObject, scheduleType: UInt, deliveryTime: Date?) throws {
    let time: Any = deliveryTime.map { $0 as NSDate } ?? NSNull()
    let singular = "editScheduledMessageItem:scheduleType:deliveryTime:"
    if IMCoreRuntime.responds(object, to: NSSelectorFromString(singular)) {
      try IMCoreRuntime.invoke(object, singular, [item, scheduleType, time])
      return
    }
    let plural = "editScheduledMessageItems:scheduleType:deliveryTime:"
    guard IMCoreRuntime.responds(object, to: NSSelectorFromString(plural)) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "editScheduledMessage", requires: singular
      )
    }
    try IMCoreRuntime.invoke(object, plural, [[item], scheduleType, time])
  }

  /// Rewrites one part of a scheduled message before it goes out.
  ///
  /// ObjC: `-[IMChat editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:]`,
  /// which takes the message ITEM, the part index as a `long long`, the replacement as an
  /// attributed string, and a translation this passes nil for. Distinct from editing a SENT
  /// message (`CKConversation editMessageItem:partIndex:withNewComposition:`): nothing has
  /// been delivered, so IMCore rewrites the pending item in place rather than sending an
  /// edit that recipients see as one.
  func editScheduledMessageText(
    item: AnyObject, partIndex: Int, text: NSAttributedString
  ) throws {
    let selector = "editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:"
    guard IMCoreRuntime.responds(object, to: NSSelectorFromString(selector)) else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "editScheduledMessage", requires: selector
      )
    }
    try IMCoreRuntime.invoke(object, selector, [item, partIndex, text, NSNull()])
  }

  func retractMessagePart(_ part: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "retractMessagePart:", [part])
  }

  /// Asks the daemon to fetch attachments it has purged from local storage.
  func downloadPurgedAttachments() throws {
    try IMCoreRuntime.invoke(object, "downloadPurgedAttachments")
  }

  /// ObjC: `sendGroupPhotoUpdate:`. Big Sur and later.
  func sendGroupPhotoUpdate(_ image: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "sendGroupPhotoUpdate:", [image])
  }

  var isPinned: Bool {
    (try? IMCoreRuntime.bool(object, "isPinned")) == true
  }

  func setDisplayName(_ name: String) throws {
    try IMCoreRuntime.invoke(object, "_setDisplayName:", [name])
  }
}

/// Mute state, from whichever of the two stores this macOS has.
///
/// MEASURED on macOS 26 (see `docs/CHAT_CONTROLS_PLAN.md` §0): `IMMutedChatList` is the
/// store, it is the `com.apple.MobileSMS.CKDNDList` defaults domain under `CKDNDListKey`,
/// keyed by MUTE IDENTIFIER rather than chat GUID — a hash for a 1:1 chat, the group id for
/// a group — and the value is an unmute instant in epoch seconds. Muted-ness is that instant
/// compared against now, which is why a timed mute needs nothing scheduled and why an
/// expired entry is not the same as a muted chat.
///
/// **`IMMutedChatList` does not exist on macOS 14** — not the selectors, the whole class
/// (`docs/SONOMA_COMPATIBILITY.md` §2.2). What Sonoma has, and what macOS 26 still has
/// alongside the list, is the older pair on `IMChat` itself: `-isMuted`, `-muteUntilDate`
/// and `-setMuteUntilDate:`.
///
/// So every operation here is written twice, and `list()` returning nil is the switch. That
/// is a change from an earlier shape where the chat-level calls were written as a "last
/// resort" AFTER a `try list()` that threw first — the fallback was unreachable on the only
/// release that needed it, which is the whole lesson of §2 of that document.
///
/// The list is still PREFERRED wherever it exists, and not out of habit: it carries
/// `syncToPairedDevice:`, and it is where Messages itself reads on 26.
///
/// The chat property `ignoreAlertsFlag` still appears in `chat.properties` on older
/// conversations. It is not consulted on either path: Messages does not consult it either.
enum IMMutedChats {

  /// The shared list, or nil on a macOS without the class.
  ///
  /// **Optional, not throwing.** Absent is a supported configuration with a working path
  /// behind it, not a failure, and the type is what says so — a `throws` signature here is
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
  /// A DATE rather than a bool, because the two questions a client asks — "is it muted"
  /// and "until when" — are one lookup, and `-isMutedChat:` is derived from this anyway.
  ///
  /// Both stores answer in the same units, so the caller cannot tell which one replied —
  /// `-muteUntilDate` is the property the list's entry is written from.
  static func unmuteDate(for chat: IMChat) throws -> Date? {
    if let list = list() {
      return try IMCoreRuntime.invoke(list, "unmuteDateForChat:", [chat.object]) as? Date
    }
    return try IMCoreRuntime.send(chat.object, "muteUntilDate") as? Date
  }

  /// IMCore's own answer, used to cross-check the date rather than to replace it.
  ///
  /// The list's form takes an argument, so it cannot go through `IMCoreRuntime.bool` — that
  /// one uses a typed IMP and only handles zero-argument getters. This was the first caller
  /// of `callReturningBool`, which exists because a dropped BOOL return is indistinguishable
  /// from a void method. The chat's `-isMuted` IS a zero-argument getter, so it takes the
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
  /// reads back as unmuted — a mute that reports success and does nothing.
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
    // above. It decides `syncToPairedDevice` for us, so `sync` is not refused here — the
    // request is honoured, just not steered.
    try IMCoreRuntime.invoke(chat.object, "setMuteUntilDate:", [untilDate as NSDate])
  }

  /// Removes the entry outright.
  ///
  /// Not "mute until a date in the past". Both read as unmuted, but only this one takes the
  /// conversation out of the list Messages syncs — where there is a list. Where there is
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

struct CKConversation {
  let object: AnyObject
  init(_ object: AnyObject) { self.object = object }

  /// Whether the group has room for another participant.
  ///
  /// Checked BEFORE adding, because IMCore's own add silently does nothing when the group
  /// is full — ObjC: BlueBubblesHelper.m:254.
  func canInsertMoreRecipients() throws -> Bool {
    try IMCoreRuntime.bool(object, "canInsertMoreRecipients")
  }

  /// ObjC: `[chat addRecipientHandles:]` / `removeRecipientHandles:`
  /// (BlueBubblesHelper.m:263-266). Both take an ARRAY, even for one handle.
  func addRecipient(_ handle: IMHandle) throws {
    try IMCoreRuntime.invoke(object, "addRecipientHandles:", [[handle.object]])
  }

  func removeRecipient(_ handle: IMHandle) throws {
    try IMCoreRuntime.invoke(object, "removeRecipientHandles:", [[handle.object]])
  }

  /// Builds the messages a composition turns into.
  ///
  /// PLURAL, and that is the point. `messageWithComposition:` returns one message, but a
  /// composition carrying both text and media does not necessarily become one message —
  /// Messages splits it, which is why ChatKit also exposes `messagesFromComposition:`.
  /// Building with the singular and sending that is how an attachment goes missing while
  /// the text arrives: measured, with the composition demonstrably holding the media and
  /// the sent message carrying `cache_has_attachments = 0`.
  ///
  /// Falls back to the singular where the plural is absent.
  func messages(from composition: AnyObject) throws -> [AnyObject] {
    if IMCoreRuntime.responds(object, to: NSSelectorFromString("messagesFromComposition:")),
      let produced = try? IMCoreRuntime.invoke(
        object, "messagesFromComposition:", [composition]
      ),
      let list = produced as? [AnyObject], !list.isEmpty
    {
      return list
    }
    guard
      let message = try IMCoreRuntime.invoke(
        object, "messageWithComposition:", [composition]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not build a message")
    }
    return [message]
  }

  /// Whether ChatKit will accept this composition at all.
  ///
  /// Asked before sending because the send itself reports nothing: a composition it
  /// refuses produces no message, no error and no attachment.
  func canSend(_ composition: AnyObject) -> Bool {
    guard
      IMCoreRuntime.responds(
        object, to: NSSelectorFromString("canSendComposition:error:")
      )
    else { return true }
    let result = try? IMCoreRuntime.invoke(
      object, "canSendComposition:error:", [composition, NSNull()]
    )
    return (result as? NSNumber)?.boolValue ?? true
  }

  /// ObjC: `[convo sendMessage:newComposition:YES]`.
  func send(_ message: AnyObject, newComposition: Bool = true) throws {
    try IMCoreRuntime.invoke(object, "sendMessage:newComposition:", [message, newComposition])
  }

  /// Read state lives on the CONVERSATION, not on IMChat (BlueBubblesHelper.m:384).
  func markAllMessagesAsRead() throws {
    try IMCoreRuntime.invoke(object, "markAllMessagesAsRead")
  }

  /// Ventura and later. The reference raises rather than silently doing nothing, and so
  /// does this — a caller that thinks it marked a chat unread and did not is worse off
  /// than one told the OS cannot.
  func markLastMessageAsUnread() throws {
    guard
      IMCoreRuntime.responds(
        object, to: NSSelectorFromString("markLastMessageAsUnread")
      )
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "markUnread", requires: "macOS Ventura or later"
      )
    }
    try IMCoreRuntime.invoke(object, "markLastMessageAsUnread")
  }

  /// ObjC: `editMessageItem:partIndex:withNewComposition:` (BlueBubblesHelper.m:1151).
  ///
  /// Takes a COMPOSITION, and only the new text — the separate
  /// backward-compatibility string the older IMChat selector wanted is gone. Two selector
  /// generations, newest first.
  func editMessage(item: AnyObject, partIndex: Int, composition: AnyObject) throws {
    for selector in [
      "editMessageItem:partIndex:withNewComposition:",
      "editMessage:partIndex:withNewComposition:",
    ] where IMCoreRuntime.responds(object, to: NSSelectorFromString(selector)) {
      try IMCoreRuntime.invoke(object, selector, [item, partIndex, composition])
      return
    }
    throw PrivateAPIErrorShim.rejected(
      "this macOS has no message-edit selector CKConversation responds to"
    )
  }

  /// ObjC: `[convo retractMessagePart:]` (BlueBubblesHelper.m:1166) — "unsend".
  func retractMessagePart(_ part: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "retractMessagePart:", [part])
  }
}

/// The controller that owns a conversation's transcript.
///
/// Deleting a message goes through here rather than through IMChat: `deleteChatItem:` is
/// per-item on the CONTROLLER, and IMChat's `deleteChatItems:` is a different operation on
/// different objects.
enum CKChatControllers {

  /// ObjC: `[[CKChatController alloc] initWithConversation:convo]`
  /// (BlueBubblesHelper.m, `getCKChatControllerFromConversation:`).
  ///
  /// The controller is CONSTRUCTED, not looked up. Neither `chatControllerForConversation:`
  /// nor a `chatController` accessor exists on macOS 26 — reaching for either fails every
  /// delete with "could not reach the chat controller". Messages makes a controller per
  /// conversation view, so there is no registry to ask.
  static func forConversation(_ conversation: CKConversation) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("CKChatController")
    guard let allocated = try IMCoreRuntime.invoke(type as AnyObject, "alloc", []),
      let controller = try IMCoreRuntime.invoke(
        allocated, "initWithConversation:", [conversation.object]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "could not create a chat controller for that conversation"
      )
    }
    return controller
  }
}

/// The IMCore attachment path: register a file transfer, then name it in the message.
///
/// This is what the helper shipped with for years before its ChatKit refactor, so the
/// approach is known to work — a previous attempt here failed and was abandoned without ever
/// being diagnosed, which is the mistake this instrumented version exists to correct.
///
/// The sequence is not guessable and every step fails quietly if skipped
/// (`prepareFileTransferForAttachment:filename:`, pre-refactor BlueBubblesHelper.m:967):
///
///   1. `guidForNewOutgoingTransferWithLocalURL:` mints a transfer GUID.
///   2. `_persistentPathForTransfer:…` asks the daemon WHERE the bytes must live, and the
///      file is copied there. The daemon will not keep a transfer pointing outside its own
///      store — the helper's own comment is "The file must be in correct location before
///      this".
///   3. `retargetTransfer:toPath:` points the transfer at the copy.
///   4. `registerTransferWithDaemon:` takes the GUID, not the transfer object.
///
/// Every step logs, because the last attempt at this produced a silent no-op and guessing at
/// which step it was cost three more attempts.
enum IMFileTransfers {

  struct Prepared {
    let guid: String
    let filename: String
  }

  static func center() throws -> AnyObject {
    try IMCoreRuntime.sharedInstance(
      ofClass: "IMFileTransferCenter",
      accessors: ["sharedInstance", "sharedCenter", "defaultCenter"]
    )
  }

  static func register(path: String, chatGUIDHint: String? = nil) throws -> Prepared {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let center = try center()
    let source = URL(fileURLWithPath: path)
    let filename = source.lastPathComponent

    guard
      let guid = try IMCoreRuntime.send(
        center, "guidForNewOutgoingTransferWithLocalURL:", source as NSURL
      ) as? String
    else {
      throw PrivateAPIErrorShim.rejected(
        "IMFileTransferCenter would not create a transfer for \(path)"
      )
    }
    BlueBubblesHelper.Logging.log("imcore-attach: 1/4 transfer guid=\(guid)")

    guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid) else {
      throw PrivateAPIErrorShim.rejected("transfer \(guid) could not be read back")
    }

    // Step 2-3. Reported rather than silently skipped: this is the step the previous
    // attempt lost, and "no attachment" gave no hint that it was the one.
    do {
      let controller = try IMCoreRuntime.sharedInstance(
        ofClass: "IMDPersistentAttachmentController"
      )
      // MEASURED on macOS 26: the reference's `storeAtExternalPath:YES` returns nil,
      // and `NO` returns a real path inside Messages' container. The variants are kept
      // in this order because which one answers has changed between releases, and a
      // nil path is indistinguishable from a missing selector without trying.
      //
      // Getting a path is still not enough — copying into it is denied by the sandbox.
      // See `IMCoreBridge.sendAttachment`.
      var returned: Any?
      for (label, args) in [
        ("nil-chat/hq/external", [transfer, filename, true, NSNull(), true] as [Any]),
        ("nil-chat/hq/internal", [transfer, filename, true, NSNull(), false] as [Any]),
        ("nil-chat/sd/external", [transfer, filename, false, NSNull(), true] as [Any]),
        ("chat/hq/external", [transfer, filename, true, chatGUIDHint ?? NSNull(), true] as [Any]),
      ] {
        let candidate = try? IMCoreRuntime.invoke(
          controller,
          "_persistentPathForTransfer:filename:highQuality:chatGUID:storeAtExternalPath:",
          args
        )
        BlueBubblesHelper.Logging.log(
          "imcore-attach: 2/4 variant \(label) -> \(String(describing: candidate))"
        )
        if let path = candidate as? String, !path.isEmpty {
          returned = path
          break
        }
      }
      guard let persistent = returned as? String, !persistent.isEmpty else {
        throw PrivateAPIErrorShim.rejected(
          "persistent path came back as \(String(describing: returned))"
        )
      }
      BlueBubblesHelper.Logging.log("imcore-attach: 2/4 persistent=\(persistent)")

      let destination = URL(fileURLWithPath: persistent)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: persistent) {
        try? FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)

      try IMCoreRuntime.invoke(center, "retargetTransfer:toPath:", [guid, persistent])
      _ = try? IMCoreRuntime.invoke(transfer, "setLocalURL:", [destination as NSURL])
      BlueBubblesHelper.Logging.log("imcore-attach: 3/4 copied and retargeted")
    } catch {
      // Loud, and NOT fatal: registering where the file stands is worth trying, and a
      // logged reason is what the last attempt lacked.
      BlueBubblesHelper.Logging.error(
        "imcore-attach: 2-3/4 FAILED — \(error). Registering in place."
      )
    }

    try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
    BlueBubblesHelper.Logging.log(
      "imcore-attach: 4/4 registered; localPath="
        + String(describing: try? IMCoreRuntime.string(transfer, "localPath"))
    )
    return Prepared(guid: guid, filename: filename)
  }

  /// The attributed run standing in for the attachment.
  ///
  /// A bare U+FFFC is not enough: the character reserves the position and these attributes
  /// are what bind the transfer to it.
  static func attachmentRun(_ prepared: Prepared, partIndex: Int) -> NSAttributedString {
    NSAttributedString(
      string: "\u{FFFC}",
      attributes: [
        .init("__kIMFileTransferGUIDAttributeName"): prepared.guid,
        .init("__kIMFilenameAttributeName"): prepared.filename,
        .init("__kIMMessagePartAttributeName"): partIndex,
        .init("__kIMBaseWritingDirectionAttributeName"): "-1",
      ]
    )
  }

  static func textRun(_ text: String, mention: String?, partIndex: Int) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
      .init("__kIMBaseWritingDirectionAttributeName"): "-1",
      .init("__kIMMessagePartAttributeName"): partIndex,
    ]
    if let mention, !mention.isEmpty {
      attributes[.init("__kIMMentionConfirmedMention")] = mention
    }
    return NSAttributedString(string: text, attributes: attributes)
  }
}

/// ChatKit compositions — how a message with attachments is actually assembled.
///
/// This replaces a raw-IMCore approach that did not work. Building an `IMMessage` directly
/// and naming file transfers by GUID sends the message and attaches nothing: verified
/// against chat.db, where the message arrived with `cache_has_attachments = 0` and no
/// attachment row at all.
///
/// ChatKit is what Messages itself uses, and `CKMediaObjectManager` does the whole job —
/// transcoding, the persistent copy into the daemon's store, and registering the transfer.
/// Reproducing those steps by hand is what failed; the shipping helper stopped trying and
/// moved to compositions, and so does this.
enum CKCompositions {

  /// An empty composition, optionally with a subject.
  ///
  /// Empty rather than seeded with the text, because parts are appended IN ORDER and a
  /// multipart message interleaves text and attachments.
  static func empty(subject: NSAttributedString?) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate a CKComposition")
    }
    guard
      let composition = try IMCoreRuntime.invoke(
        allocated, "initWithText:subject:",
        [NSAttributedString(string: ""), subject ?? NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("CKComposition would not initialise")
    }
    return composition
  }

  /// Puts the file where the transfer says it lives, then tells the daemon about it.
  ///
  /// MEASURED on macOS 26. `mediaObjectWithFileURL:filename:transcoderUserInfo:` allocates
  /// a transfer and computes a `localPath` under Messages' own container tmp, but it does
  /// **not** copy the bytes there — the transfer reports `existsAtLocalPath = 0`,
  /// `totalBytes = 0`, `isFileURLFinalized = 0`. Messages' own UI reaches that copy through
  /// its transcode/preview pipeline, which a headless caller never drives. A message sent
  /// in that state carries a valid transfer GUID with nothing behind it, so imagent writes
  /// no attachment row and reports no error — the exact silent no-op this path produced.
  ///
  /// This is the ChatKit counterpart of IMCore's `_persistentPathForTransfer:` copy. That
  /// one is unusable here because its destination is `~/Library/Messages/Attachments`,
  /// outside Messages' sandbox: copying there fails with `NSCocoaErrorDomain 513`. This
  /// destination is inside the container we are running in, so the write is permitted.
  static func stageBytes(for media: AnyObject, from source: String) throws {
    guard let guid = try? IMCoreRuntime.string(media, "transferGUID") else {
      throw PrivateAPIErrorShim.rejected("the media object has no transfer GUID")
    }
    let center = try IMFileTransfers.center()
    guard let transfer = try IMCoreRuntime.send(center, "transferForGUID:", guid),
      let destination = try? IMCoreRuntime.string(transfer, "localPath"),
      !destination.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("transfer \(guid) has no local path")
    }

    let manager = FileManager.default
    if !manager.fileExists(atPath: destination) {
      try manager.createDirectory(
        at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manager.copyItem(atPath: source, toPath: destination)
    }

    // Only now is there anything for the daemon to pick up.
    try IMCoreRuntime.invoke(center, "registerTransferWithDaemon:", [guid])
  }

  /// Appends a file. ChatKit handles the transfer registration itself.
  static func appendingMedia(_ composition: AnyObject, path: String) throws -> AnyObject {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithFileURL:filename:transcoderUserInfo:",
        [URL(fileURLWithPath: path) as NSURL, NSNull(), NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not accept \(path) as media")
    }
    try stageBytes(for: media, from: path)
    guard
      let appended = try IMCoreRuntime.invoke(
        composition, "compositionByAppendingMediaObject:", [media]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not append the attachment")
    }
    return appended
  }

  /// Appends text, carrying a confirmed mention when there is one and any inline styles
  /// or effects the part asked for (`TextFormattingAttributes`).
  static func appendingText(
    _ composition: AnyObject, text: String, mention: String?,
    formatting: [FormattedRange] = []
  ) throws -> AnyObject {
    let run = NSMutableAttributedString(string: text)
    if let mention, !mention.isEmpty {
      run.addAttributes(
        [.init("__kIMMentionConfirmedMention"): mention],
        range: NSRange(location: 0, length: run.length)
      )
    }
    TextFormattingAttributes.apply(formatting, to: run)
    guard
      let appended = try IMCoreRuntime.invoke(
        composition, "compositionByAppendingText:", [run]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not append text to the composition")
    }
    return appended
  }

  /// Attaches a Send Later date, which is what makes the message scheduled.
  ///
  /// MEASURED, after the obvious approach failed: building an `IMMessage` through the
  /// initializer that takes `scheduleType:scheduleState:` and sending it with
  /// `-[IMChat sendMessage:]` sends it IMMEDIATELY — the row lands with
  /// `schedule_type = 0`, `is_delivered = 1` and a delivery time of now. Whatever files a
  /// message as scheduled is not those two words on the message.
  ///
  /// This is Messages' own route instead. `-[CKComposition(IMSuperFormat)
  /// messageWithGUID:superFormatText:…]` (disassembled on 26.5.2) asks the composition for
  /// its `sendLaterPluginInfo`; when there is one it passes that info's `selectedDate` as
  /// the message's `time:` along with `scheduleType 2` / `scheduleState 1`, and when there
  /// is not it passes `[NSDate date]` and 0 / 0. So the date goes on the COMPOSITION, and
  /// `messagesFromComposition:` builds a scheduled message from it.
  static func setSendLater(_ composition: AnyObject, _ date: Date?) throws {
    guard let date else { return }
    let type: AnyClass = try IMCoreRuntime.requireClass("CKSendLaterPluginInfo")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue(),
      let info = try IMCoreRuntime.invoke(
        allocated, "initWithSelectedDate:", [date as NSDate])
    else {
      throw PrivateAPIErrorShim.rejected("could not build the Send Later info")
    }
    guard
      IMCoreRuntime.responds(composition, to: NSSelectorFromString("setSendLaterPluginInfo:"))
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "scheduled send", requires: "CKComposition.setSendLaterPluginInfo:"
      )
    }
    try IMCoreRuntime.invoke(composition, "setSendLaterPluginInfo:", [info])
  }

  /// An audio composition, which ChatKit builds differently.
  ///
  /// A voice note assembled as an ordinary attachment arrives as a playable file rather
  /// than as a waveform, so the dedicated constructor is not interchangeable.
  static func audio(path: String) throws -> AnyObject {
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithFileURL:filename:transcoderUserInfo:",
        [URL(fileURLWithPath: path) as NSURL, NSNull(), NSNull()]
      )
    else {
      throw PrivateAPIErrorShim.rejected("ChatKit would not accept \(path) as media")
    }
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        type as AnyObject, "audioCompositionWithMediaObject:", [media]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not build an audio composition")
    }
    return composition
  }

  /// Lets ChatKit finish preparing a media object before the message is sent.
  ///
  /// `CKMediaObjectManager` copies the file into Messages' container and links it on its
  /// own schedule, and the media reports `isFileURLFinalized:0 isFileDataReady:0` until it
  /// has. A message sent before that names a transfer with no bytes behind it, and the
  /// attachment is silently dropped — measured: the message arrives, `cache_has_attachments`
  /// stays 0, and no error is reported anywhere.
  ///
  /// **This is not sufficient on its own.** Measured with a 250ms settle in place, the
  /// message still arrives with `cache_has_attachments = 0` and no attachment row — even
  /// though the composition demonstrably carries the media and the built `IMMessage`
  /// carries its transfer GUID. So the loss is somewhere in `sendMessage:newComposition:`,
  /// not in how the composition is assembled. Kept because the unfinalized state is real
  /// and a send that races it cannot be correct either way; removing it would only hide
  /// one of the two problems.
  static func settle() async throws {
    try? await Task.sleep(for: .milliseconds(250))
  }

  /// A composition holding just this text. What an edit replaces a part with.
  static func withText(_ text: String) throws -> AnyObject {
    try appendingText(try empty(subject: nil), text: text, mention: nil)
  }

  static func setEffect(_ composition: AnyObject, _ effectID: String?) {
    guard let effectID, !effectID.isEmpty else { return }
    _ = try? IMCoreRuntime.invoke(composition, "setExpressiveSendStyleID:", [effectID])
  }
}

struct IMHandle {
  let object: AnyObject
  init(_ object: AnyObject) { self.object = object }
}

/// `IMAccountController` — the signed-in accounts.
enum IMAccountController {

  /// The active iMessage account's handle for an address.
  ///
  /// ObjC: `[[[IMAccountController sharedInstance] activeIMessageAccount] imHandleWithID:]`
  /// (BlueBubblesHelper.m:259). Nil means the address is not reachable on iMessage, which
  /// is a normal answer rather than a failure.
  /// Resolves an address to a handle ON THE REQUESTED SERVICE.
  ///
  /// The service is not cosmetic. iMessage and SMS are separate accounts with separate
  /// handle namespaces, and resolving an SMS address through the iMessage account returns
  /// either nothing or an iMessage handle for a number that is not on iMessage — so a chat
  /// created from it is an iMessage chat that will never deliver. The shipping helper
  /// branches on the service for exactly this reason (BlueBubblesHelper.m:411).
  static func handle(for address: String, service: String = "iMessage") throws -> IMHandle? {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
    let accessor =
      service.caseInsensitiveCompare("iMessage") == .orderedSame
      ? "activeIMessageAccount"
      : "activeSMSAccount"

    guard let account = try IMCoreRuntime.send(controller, accessor) else { return nil }
    guard let handle = try IMCoreRuntime.send(account, "imHandleWithID:", address) else {
      return nil
    }
    return IMHandle(handle)
  }

  /// This Mac's OWN handle on the active iMessage account — who a share is "from".
  ///
  /// `-[IMAccount loginIMHandle]`, read from the runtime on macOS 26.5.2. Distinct from
  /// `handle(for:)` above, which resolves somebody ELSE's address through an account.
  ///
  /// Optional rather than throwing: every caller so far treats "signed out, so there is no
  /// local handle" as a reason to pass nil rather than to fail, and IMCore's own
  /// nickname-sharing path declares the argument `id` and forwards it without messaging it.
  static func loginHandle(service: String = "iMessage") -> AnyObject? {
    guard
      let controller = try? IMCoreRuntime.sharedInstance(ofClass: "IMAccountController")
    else { return nil }
    let accessor =
      service.caseInsensitiveCompare("iMessage") == .orderedSame
      ? "activeIMessageAccount"
      : "activeSMSAccount"
    guard let account = try? IMCoreRuntime.send(controller, accessor) else { return nil }
    return (try? IMCoreRuntime.send(account, "loginIMHandle")) ?? nil
  }

  /// Whether the daemon is connected — the helper's own liveness answer.
  ///
  /// ObjC: `[IMDaemonController sharedController].connected`.
  static func isDaemonConnected() -> Bool {
    guard
      let controller = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMDaemonController", accessors: ["sharedController", "sharedInstance"]
      )
    else { return false }
    return (try? IMCoreRuntime.bool(controller, "isConnected"))
      ?? (try? IMCoreRuntime.bool(controller, "connected"))
      ?? false
  }
}

/// Errors raised from the wrappers, in the contract's vocabulary.
/// Loading a message back out of IMCore by GUID.
///
/// Editing and retracting both operate on a message ITEM, not on a GUID — so every one of
/// those paths has to resolve one first, and the resolution is asynchronous. The completion
/// block fires on an internal queue, which is why this bridges to `async` rather than
/// spinning the run loop: blocking the main thread here would freeze Messages' UI for the
/// duration, and IMCore may well need the main thread to deliver the result at all.
enum IMChatHistory {

  /// The loaded item, boxed.
  ///
  /// `AnyObject` is not `Sendable` and the completion block delivers one across an
  /// isolation boundary, so it travels in an `@unchecked Sendable` box. Sound here because
  /// every caller is `@MainActor` — the object is produced by IMCore, handed straight back,
  /// and touched on one actor throughout.
  private final class Box: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
  }

  /// Loads the `IMMessage` for a GUID.
  ///
  /// `loadMessageWithGUID:` — the reference's loader — rather than
  /// `loadMessageItemWithGUID:`. Callers that need the item take `._imMessageItem` off it,
  /// which is what every downstream selector actually wants.
  static func message(guid: String) async throws -> AnyObject {
    try await load(guid: guid, selector: "loadMessageWithGUID:completionBlock:")
  }

  /// The chat item for one part of a message.
  ///
  /// Positional within `_newChatItems`, matching the reference: `objectAtIndex:partIndex`.
  /// An earlier pass matched on each item's own `index` property, which is a different
  /// thing once a part has been retracted.
  ///
  /// A photo gallery is the exception — it is ONE item whose real parts hang off
  /// `aggregateAttachmentParts` — and the reference detects it by the index running past
  /// the array, which is exactly when a gallery is the only thing it can be.
  static func messagePartChatItem(guid: String, partIndex: Int) async throws -> AnyObject {
    let message = try await message(guid: guid)
    let item = (try? IMCoreRuntime.send(message, "_imMessageItem")) ?? message
    guard let items = try? IMCoreRuntime.send(item, "_newChatItems") else {
      throw PrivateAPIErrorShim.rejected("that message exposes no chat items")
    }
    guard let list = items as? [AnyObject] else { return items }

    if partIndex > list.count - 1 {
      guard
        let aggregateClass = IMCoreRuntime.lookUpClass(
          "IMAggregateAttachmentMessagePartChatItem"
        ), let first = list.first, first.isKind(of: aggregateClass)
      else {
        throw PrivateAPIErrorShim.rejected(
          "part index \(partIndex) is past the end of a \(list.count)-part message"
        )
      }
      let parts = (try? IMCoreRuntime.objects(first, "aggregateAttachmentParts")) ?? []
      guard partIndex < parts.count else {
        throw PrivateAPIErrorShim.rejected(
          "part index \(partIndex) is past the end of the gallery"
        )
      }
      return parts[partIndex]
    }
    return list[partIndex]
  }

  static func messageItem(guid: String) async throws -> AnyObject {
    try await load(guid: guid, selector: "loadMessageItemWithGUID:completionBlock:")
  }

  private static func load(guid: String, selector: String) async throws -> AnyObject {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IMChatHistoryController")

    // IMCore has been observed calling a completion block more than once for a single
    // query, and a failed invoke means no completion at all. `ResumeOnce` handles both.
    let once = ResumeOnce<Box>()
    let block: @convention(block) (AnyObject?) -> Void = { once.finish(Box($0)) }
    do {
      try IMCoreRuntime.invoke(
        controller, selector, [guid, unsafeBitCast(block, to: AnyObject.self)]
      )
    } catch {
      once.finish(Box(nil))
    }
    let loaded = await once.wait().value

    guard let loaded else {
      throw PrivateAPIErrorShim.rejected("Messages has no message with GUID \(guid)")
    }
    return loaded
  }

  /// The chat item a tapback, edit or retraction applies to.
  ///
  /// `_newChatItems` on the message ITEM, not `messageParts` on the message — they are
  /// different objects and `retractMessagePart:` wants the former. Transcribed from the
  /// shipping helper (BlueBubblesHelper.m:352), including two shapes that are not
  /// guessable:
  ///
  ///   - `_newChatItems` is sometimes an ARRAY and sometimes a single item. A message with
  ///     one part returns the item bare.
  ///   - A photo gallery is an `IMAggregateAttachmentMessagePartChatItem` whose real parts
  ///     hang off `aggregateAttachmentParts`. Matching against the aggregate's own index
  ///     finds nothing, so unsending one photo of several would silently do nothing.
  ///
  /// Parts are matched by their own `index`, not by position in the array. They are not the
  /// same thing once a part has been retracted, and using position retracts the wrong one.
  static func messagePart(of item: AnyObject, at index: Int) throws -> AnyObject {
    let container = (try? IMCoreRuntime.send(item, "_imMessageItem")) ?? item
    guard let items = try? IMCoreRuntime.send(container, "_newChatItems") else {
      throw PrivateAPIErrorShim.rejected("that message exposes no parts")
    }

    // The single-item shape.
    guard let list = items as? [AnyObject] else {
      return items
    }

    let aggregateClass: AnyClass? = IMCoreRuntime.lookUpClass(
      "IMAggregateAttachmentMessagePartChatItem"
    )
    for candidate in list {
      if let aggregateClass, candidate.isKind(of: aggregateClass) {
        let parts = (try? IMCoreRuntime.objects(candidate, "aggregateAttachmentParts")) ?? []
        for part in parts where (try? IMCoreRuntime.integer(part, "index")) == index {
          return part
        }
        continue
      }
      if (try? IMCoreRuntime.integer(candidate, "index")) == index {
        return candidate
      }
    }

    throw PrivateAPIErrorShim.rejected(
      "that message has no part at index \(index)"
    )
  }
}

/// Asynchronous IMCore queries that answer through a completion block.
///
/// Both of these force a FRESH lookup rather than reading a cached value, and that is the
/// point: an earlier pass of this port read `IMHandle.IDStatus` directly and got `false` for
/// a real iMessage address, because the cached status is 0 (UNKNOWN) until something asks
/// IDS. A client seeing that sends the message as SMS.
enum IMCoreQueries {

  private final class Box: @unchecked Sendable {
    let value: AnyObject?
    init(_ value: AnyObject?) { self.value = value }
  }

  /// IDS availability for one address on one service.
  ///
  /// iMessage and FaceTime are DIFFERENT IDS services and an address can be on one and not
  /// the other, so the service name is part of the question. Answering FaceTime from the
  /// iMessage result — which this port did — is simply a different question.
  static func idsStatus(address: String, service: String) async throws -> Bool {
    let controller = try IMCoreRuntime.sharedInstance(ofClass: "IDSIDQueryController")

    // `IDSCopyIDForPhoneNumber` / `…ForEmailAddress` build the destination. An address
    // with an `@` is an email; everything else is treated as a phone number, matching
    // the reference's `aliasType` branch.
    let isEmail = address.contains("@")
    let destination =
      address.hasPrefix("mailto:") || address.hasPrefix("tel:")
      ? address
      : (isEmail ? "mailto:\(address)" : "tel:\(address)")

    let once = ResumeOnce<Box>()
    let block: @convention(block) (AnyObject?) -> Void = { once.finish(Box($0)) }

    // The selector has moved. `forceRefreshIDStatusForDestinations:…` is what the
    // reference calls and is gone on macOS 26; `currentIDStatusForDestinations:…`
    // is what replaced it and still consults IDS when it has no fresh answer.
    // Newest-known first, and a macOS with neither reports unavailable rather than
    // silently answering "not reachable" for everyone.
    let candidates = [
      "currentIDStatusForDestinations:service:listenerID:queue:completionBlock:",
      "forceRefreshIDStatusForDestinations:service:listenerID:queue:completionBlock:",
    ]
    var dispatched = false
    for selector in candidates
    where IMCoreRuntime.responds(controller, to: NSSelectorFromString(selector)) {
      do {
        try IMCoreRuntime.invoke(
          controller, selector,
          [
            [destination], service,
            "BlueBubblesHelper-IDSListener",
            DispatchQueue.global(),
            unsafeBitCast(block, to: AnyObject.self),
          ]
        )
        dispatched = true
      } catch {
        once.finish(Box(nil))
        dispatched = true
      }
      break
    }
    if !dispatched {
      once.finish(Box(nil))
    }
    let response = await once.wait().value

    // 1 is available. Anything else — including 0, which means IDS still does not know —
    // is not.
    guard let dictionary = response as? [String: Any],
      let status = dictionary.values.first as? Int
    else { return false }
    return status == 1
  }

  /// Focus (Do Not Disturb) status for a handle.
  ///
  /// `_fetchUpdatedStatusForHandle:completion:` refreshes, and the reference then waits a
  /// second before reading because the completion fires before the value lands. That delay
  /// is transcribed rather than tuned: it is doing the same job here.
  static func focusStatus(handle: AnyObject) async throws -> Int {
    guard
      let manager = try? IMCoreRuntime.sharedInstance(
        ofClass: "IMHandleAvailabilityManager"
      )
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "checkFocusStatus", requires: "macOS Monterey or later"
      )
    }

    // The refresh is OPTIONAL — a stale-but-real status beats refusing to answer, because
    // most callers want to know whether someone is silenced rather than to force a network
    // round trip. But it is less optional than it looks.
    //
    // TWO spellings, newest first. Looking only for the UNDERSCORED
    // `_fetchUpdatedStatusForHandle:completion:` — what the reference calls — finds it
    // absent on macOS 26.5.2 and suggests the refresh is gone. It is not: the same method
    // is there without the underscore, and missing it makes every focus read return cached
    // data that did not need to be cached. See `docs/SEQUOIA_COMPATIBILITY.md` §5.2.
    let refreshSelector = [
      "fetchUpdatedStatusForHandle:completion:",
      "_fetchUpdatedStatusForHandle:completion:",
    ]
    .first { IMCoreRuntime.responds(manager, to: NSSelectorFromString($0)) }

    if let refreshSelector {
      let once = ResumeOnce<Void>()
      // Zero parameters, deliberately, and safe whichever spelling answered: a block
      // that declares none is called correctly no matter how many arguments IMCore
      // passes, because it never reads the argument registers. The reverse — declaring
      // parameters the caller does not supply — is what reads register garbage.
      let block: @convention(block) () -> Void = { once.finish() }
      do {
        try IMCoreRuntime.invoke(
          manager, refreshSelector,
          [handle, unsafeBitCast(block, to: AnyObject.self)]
        )
      } catch {
        once.finish()
      }
      await once.wait()
      // The reference's one-second settle, and only meaningful after a refresh: the
      // completion fires before the manager's own value is updated, so reading
      // immediately returns the previous status.
      try? await Task.sleep(for: .seconds(1))
    }

    guard
      IMCoreRuntime.responds(
        manager, to: NSSelectorFromString("availabilityForHandle:")
      )
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "checkFocusStatus",
        requires: "IMHandleAvailabilityManager's availability read on this macOS"
      )
    }
    guard
      let status = try? IMCoreRuntime.invoke(
        manager, "availabilityForHandle:", [handle]
      )
    else { return 0 }
    return (status as? NSNumber)?.intValue ?? 0
  }
}

enum PrivateAPIErrorBridge {
  static func noSuchChat(_ guid: String) -> any Error {
    PrivateAPIErrorShim.rejected("Messages does not know a chat with GUID \(guid)")
  }
  static func noSuchHandle(_ address: String) -> any Error {
    PrivateAPIErrorShim.rejected("No iMessage handle for \(address)")
  }
}

/// A local error type, so these wrappers do not have to import the contract's enum at every
/// call site. `IMCoreBridge` translates it at the boundary.
enum PrivateAPIErrorShim: Error, CustomStringConvertible {
  case rejected(String)
  var description: String {
    switch self {
    case .rejected(let reason): reason
    }
  }
}

// MARK: - Messages

/// `IMMessage` — one outgoing message.
///
/// Built through the eleven-argument designated initializer, which is why the invocation
/// bridge exists. Transcribed from `BlueBubblesHelper.m:1050`.
enum IMMessageBuilder {

  /// The flags word, and it is not arbitrary.
  ///
  /// These constants come from the shipping helper and encode what kind of message this
  /// is. Getting them wrong produces a message that sends and then renders incorrectly —
  /// an audio message that appears as a file, a subject that vanishes.
  enum Flags {
    /// A plain outgoing message.
    static let plain: Int64 = 0x100005
    /// Carries a subject line.
    static let withSubject: Int64 = 0x10000D
    /// An audio message, which Messages renders with a waveform.
    static let audio: Int64 = 0x300005
    /// A tapback. Note it is 0x5, not one of the above — an association is a different
    /// kind of message rather than a plain one with extra fields.
    static let association: Int64 = 0x5
  }

  /// A plain or attachment-bearing message.
  ///
  /// ObjC: `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:`
  /// `subject:balloonBundleID:payloadData:expressiveSendStyleID:` (BlueBubblesHelper.m:1050).
  ///
  /// Note there are TWO subject parameters. `messageSubject` is the attributed subject that
  /// actually appears; the later `subject:` is a legacy field the shipping helper passes
  /// nil for. Passing the text in the wrong one silently drops it.
  static func message(
    text: NSAttributedString,
    subject: NSAttributedString?,
    fileTransferGUIDs: [String],
    effectID: String?,
    threadIdentifier: String?,
    isAudioMessage: Bool
  ) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("Could not allocate an IMMessage")
    }

    let flags: Int64 =
      isAudioMessage
      ? Flags.audio
      : (subject != nil ? Flags.withSubject : Flags.plain)

    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:balloonBundleID:payloadData:expressiveSendStyleID:",
        [
          NSNull(),  // sender — nil means the local account
          NSNull(),  // time — nil means now
          text,
          subject ?? NSNull(),
          fileTransferGUIDs,
          flags,
          NSNull(),  // error
          NSNull(),  // guid — nil means Messages assigns one
          NSNull(),  // subject (legacy; see above)
          NSNull(),  // balloonBundleID
          NSNull(),  // payloadData
          effectID ?? NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage initializer returned nil")
    }

    // Reply threading. Set after construction because the initializer has no parameter
    // for it — ObjC: `messageToSend.threadIdentifier = threadIdentifier`.
    if let threadIdentifier {
      try IMCoreRuntime.invoke(message, "setThreadIdentifier:", [threadIdentifier])
    }
    return message
  }

  /// A tapback.
  ///
  /// ObjC: the `associatedMessageGUID:associatedMessageType:associatedMessageRange:`
  /// `messageSummaryInfo:` variant (BlueBubblesHelper.m:1053). A different initializer and
  /// a different flags word — an association is its own kind of message.
  static func association(
    text: NSAttributedString,
    associatedGUID: String,
    associatedType: Int64,
    range: NSRange,
    summaryInfo: [String: Any]?
  ) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("Could not allocate an IMMessage")
    }

    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:"
          + "messageSummaryInfo:",
        [
          NSNull(), NSNull(), text, NSNull(), NSNull(),
          Flags.association,
          NSNull(), NSNull(), NSNull(),
          associatedGUID,
          associatedType,
          NSValue(range: range),
          summaryInfo ?? NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage association initializer returned nil")
    }
    return message
  }

  /// An iMessage-app balloon: a plain message carrying a plugin bundle id and its payload.
  ///
  /// The same eleven-argument initializer everything else uses, with the two arguments the
  /// text path passes nil for actually filled in. The TEXT is the fallback line a device
  /// shows when it cannot draw the balloon; Apple's own app messages carry an empty one and
  /// let the layout's caption speak, and that is what is sent when no summary is given.
  static func appMessage(
    balloonBundleID: String, payload: Data, summary: String?
  ) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("Could not allocate an IMMessage")
    }
    guard
      let message = try IMCoreRuntime.invoke(
        allocated,
        "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
          + "subject:balloonBundleID:payloadData:expressiveSendStyleID:",
        [
          NSNull(), NSNull(), NSAttributedString(string: summary ?? ""), NSNull(), [],
          Flags.plain, NSNull(), NSNull(), NSNull(),
          balloonBundleID, payload, NSNull(),
        ]
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the app message")
    }
    return message
  }

  /// A sticker: an association that also carries a file transfer.
  ///
  /// TRANSCRIBED from Messages' own send, `-[CKChatController(CKChatController_Stickers)
  /// _sendCommSafetyVerifiedSticker:withMediaObject:composition:parentMessagePartChatItem:
  /// messageSummaryInfo:]` on macOS 26.5.2 (disassembled; see `docs/PRIVATE_API_SURFACE.md`
  /// § Stickers). It is the fourteen-argument association initializer — the tapback one
  /// with `threadIdentifier:` on the end — called with:
  ///
  ///     sender nil · time [NSDate date] · text = composition superFormatText
  ///     messageSubject nil · fileTransferGUIDs from the composition · flags 5
  ///     error nil · guid [NSString stringGUID] · subject nil
  ///     associatedMessageGUID = parent part chat item's guid   ("p:0/<message guid>")
  ///     associatedMessageType = 1000 (1001 for an emoji sticker)
  ///     associatedMessageRange = parent part's messagePartRange
  ///     messageSummaryInfo = whatever the caller had (nil from the drag-and-drop path)
  ///     threadIdentifier = parent part's threadIdentifier
  ///
  /// Two of those are not what the tapback path passes and both matter. The RANGE is the
  /// part's real range in the message text, not `(partIndex, 1)`: chat.db shows every
  /// received sticker with the parent part's text length as its range length, and the
  /// sticker's geometry is expressed relative to that part. The GUID is the CHAT ITEM's,
  /// with the `p:<part>/` prefix, which is how Messages knows which balloon to draw it on.
  ///
  /// The thirteen-argument initializer is used when the fourteen-argument one is absent,
  /// which loses the thread identifier and nothing else.
  static func sticker(
    text: NSAttributedString,
    fileTransferGUIDs: [String],
    guid: String,
    associatedGUID: String,
    associatedType: Int64,
    range: NSRange,
    summaryInfo: [String: Any]?,
    threadIdentifier: String?
  ) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("Could not allocate an IMMessage")
    }

    let base =
      "initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:"
      + "subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:"
      + "messageSummaryInfo:"
    var arguments: [Any] = [
      NSNull(), NSDate(), text, NSNull(), fileTransferGUIDs,
      Flags.association,
      NSNull(), guid, NSNull(),
      associatedGUID,
      associatedType,
      NSValue(range: range),
      summaryInfo ?? NSNull(),
    ]
    let selector: String
    if IMCoreRuntime.responds(allocated, to: NSSelectorFromString(base + "threadIdentifier:")) {
      selector = base + "threadIdentifier:"
      arguments.append(threadIdentifier ?? NSNull())
    } else {
      selector = base
    }

    guard let message = try IMCoreRuntime.invoke(allocated, selector, arguments) else {
      throw PrivateAPIErrorShim.rejected("IMMessage sticker initializer returned nil")
    }
    return message
  }
}

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
/// This is the only way to send an EMOJI tapback — `IMEmojiTapback` carries the emoji and
/// the sender writes it into `associatedMessageEmoji`. It is also what Messages uses for
/// the six named ones, so they go through it too when it exists, which fixes what the
/// association-initializer path got wrong (a bare target GUID where Messages writes
/// `p:<part>/<guid>`, and a range of `(part, 1)` where Messages writes the part's own).
/// That path stays as the fallback for a macOS without `IMTapbackSender`.
enum IMTapbacks {

  /// Whether Messages' own sender is available here.
  ///
  /// The SENDER only. Whether the tapback OBJECT it needs can be built is a separate
  /// question with a different answer per release, and `canBuild(_:)` is that question —
  /// see the comment there for why the two were once conflated and what it cost.
  static var senderAvailable: Bool {
    guard let sender = IMCoreRuntime.lookUpClass("IMTapbackSender") else { return false }
    return (sender as AnyObject).responds(to: NSSelectorFromString("alloc"))
      && class_getInstanceMethod(
        sender, NSSelectorFromString("initWithTapback:chat:messagePartChatItem:")) != nil
  }

  /// Whether `tapback(_:emoji:)` can actually construct this reaction on this macOS.
  ///
  /// **This is not the same question as `senderAvailable`, and treating it as one broke
  /// every reaction on Sonoma.** `IMTapbackSender` and its initializer are present on macOS
  /// 14.6.1, so the caller took the modern branch — and then
  /// `+[IMTapback tapbackWithAssociatedMessageType:]` was missing, because Apple NARROWED
  /// that constructor rather than adding it: 14.6.1 has only the
  /// `…:messageSummaryInfo:` and `…:representation:` forms. The association-initializer
  /// fallback, which sends all six named tapbacks correctly, was never reached.
  /// Measured — `docs/SONOMA_COMPATIBILITY.md` §2.1.
  ///
  /// Asked per RECEIVED REACTION rather than once, because the two kinds need different
  /// things and a release may have one without the other.
  ///
  /// MEASURED across all three releases since: the one-argument constructor arrived in
  /// **macOS 15**, alongside `IMEmojiTapback`, so both kinds take the Messages path on 15
  /// and 26 and only 14 falls back. The per-kind question is therefore answered the same
  /// way on every release we support today — and it stays asked per kind, because that is
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
  /// disassembled). The transfer has to exist first — `IMStickers.mediaObject` creates and
  /// registers it — and the same sender sends it as every other tapback.
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

  /// Sends, and returns the message `send` answered with — the tapback's own `IMMessage`.
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

// MARK: - Polls

/// Creating a poll and voting on one, the way the Polls extension does through Messages.
///
/// `docs/POLLS.md` is the reference. A poll is an app message: an `MSMessage` whose `URL`
/// is a `data:` URL of JSON, sent through ChatKit's `+[CKComposition
/// compositionWithMSMessage:appExtensionIdentifier:]`, which resolves the plugin, its icon
/// and its balloon bundle id and hands back a composition to send like any other. A vote is
/// a custom acknowledgement: `_MSMessageCustomAcknowledgement` produces the payload and
/// `+[IMMessage customAcknowledgementMessageWithPayloadData:…]` the message.
///
/// `Messages.framework` (the public iMessage-app API) is not necessarily loaded in
/// Messages.app until an extension runs, so it is `dlopen`ed on first use from its public
/// path — the one place in this helper a framework is loaded explicitly.
enum IMPolls {

  private static let frameworkPath =
    "/System/iOSSupport/System/Library/Frameworks/Messages.framework/Messages"

  private static func requireMessagesClass(_ name: String) throws -> AnyClass {
    if let found = IMCoreRuntime.lookUpClass(name) { return found }
    _ = dlopen(frameworkPath, RTLD_NOW)
    return try IMCoreRuntime.requireClass(name)
  }

  private static func allocate(_ type: AnyClass) throws -> AnyObject {
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate \(type)")
    }
    return allocated
  }

  /// The local account's address, which the JSON names as `creatorHandle` and
  /// `participantHandle`.
  static func ownHandle() throws -> String {
    guard let handle = IMAccountController.loginHandle(),
      let id = ((try? IMCoreRuntime.string(handle, "ID")) ?? nil), !id.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("no iMessage login handle — is Messages signed in?")
    }
    return id
  }

  /// `data:,<base64 JSON>` with Messages' own query suffix on a poll (`?src=p&c=<n>`).
  static func dataURL(json: [String: Any], suffix: String = "") throws -> NSURL {
    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    guard let url = NSURL(string: "data:," + data.base64EncodedString() + suffix) else {
      throw PrivateAPIErrorShim.rejected("could not build the poll data URL")
    }
    return url
  }

  static func pollJSON(title: String, options: [PollOptionSpec], creator: String) -> [String: Any] {
    [
      "version": 1,
      "item": [
        "title": title,
        "creatorHandle": creator,
        "orderedPollOptions": options.map { option -> [String: Any] in
          [
            "optionIdentifier": option.id,
            "text": option.text,
            "attributedText": option.text,
            "canBeEdited": option.canBeEdited,
            "creatorHandle": option.creatorHandle ?? creator,
          ]
        },
      ] as [String: Any],
    ]
  }

  static func votesJSON(optionIDs: [String], voter: String) -> [String: Any] {
    [
      "version": 1,
      "item": [
        "votes": optionIDs.map { ["participantHandle": voter, "voteOptionIdentifier": $0] }
      ] as [String: Any],
    ]
  }

  /// The composition for a new poll. ChatKit does the archive, the icon and the plugin
  /// lookup; the caller sends it like any composition.
  static func composition(title: String, options: [String]) throws -> AnyObject {
    let creator = try ownHandle()
    let specs = options.map {
      PollOptionSpec(id: UUID().uuidString, text: $0, creatorHandle: creator)
    }
    return try composition(title: title, options: specs, creator: creator, session: nil)
  }

  /// The composition for a poll re-sent in a new state: the SAME session, so ChatKit files
  /// it as an update of the original rather than a new poll. Options added by this account
  /// carry its handle; the ones already there keep their creators.
  static func updateComposition(_ request: PollUpdateRequest) throws -> AnyObject {
    let own = try ownHandle()
    guard let uuid = UUID(uuidString: request.sessionID) else {
      throw PrivateAPIErrorShim.rejected("the poll session id is not a UUID")
    }
    let specs = request.options.map {
      PollOptionSpec(
        id: $0.id, text: $0.text, creatorHandle: $0.creatorHandle ?? own,
        canBeEdited: $0.canBeEdited)
    }
    return try composition(
      title: request.title, options: specs, creator: request.creatorHandle ?? own,
      session: uuid)
  }

  /// The UPDATE message for a poll re-sent in a new state, ready for `sendMessage:`.
  ///
  /// MEASURED twice before this: the same session alone lands as a second poll, and so
  /// does naming the root on the composition's plugin payload — `IMPluginPayload.isUpdate`
  /// is a bare ivar with no setter, filled in only when the extension host builds the
  /// payload. So the update branch of `-[CKComposition(IMSuperFormat)
  /// _messageFromPayload:firstGUID:]` is reproduced here instead: the payload the
  /// composition built, handed to `+[IMMessage breadcrumbMessageWithText:
  /// associatedMessageGUID:balloonBundleID:fileTransferGUIDs:payloadData:threadIdentifier:]`,
  /// which writes `associatedMessageType` 2 (disassembled: `mov w8, #2`, flags 5) against the
  /// root. That is the row Messages' own "Add Choice" produces.
  static func updateMessage(_ request: PollUpdateRequest) throws -> AnyObject {
    let composition = try updateComposition(request)
    guard let payload = try IMCoreRuntime.send(composition, "shelfPluginPayload"),
      let data = try IMCoreRuntime.send(payload, "data")
    else {
      throw PrivateAPIErrorShim.rejected("the poll composition carries no plugin payload")
    }
    guard
      let text = try IMCoreRuntime.invoke(composition, "superFormatText:", [NSNull()])
        as? NSAttributedString
    else {
      throw PrivateAPIErrorShim.rejected("the poll composition produced no message text")
    }
    let messageClass: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        messageClass as AnyObject,
        "breadcrumbMessageWithText:associatedMessageGUID:balloonBundleID:fileTransferGUIDs:"
          + "payloadData:threadIdentifier:",
        [text, request.rootGUID.rawValue, PollsApp.balloonBundleID, NSNull(), data, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the poll update")
    }
    return message
  }

  private static func composition(
    title: String, options: [PollOptionSpec], creator: String, session uuid: UUID?
  ) throws -> AnyObject {
    let url = try dataURL(
      json: pollJSON(title: title, options: options, creator: creator),
      suffix: "?src=p&c=\(options.count)"
    )

    let sessionClass = try requireMessagesClass("MSSession")
    let session: AnyObject? =
      if let uuid {
        try IMCoreRuntime.invoke(
          try allocate(sessionClass), "initWithIdentifier:", [uuid as NSUUID])
      } else {
        try IMCoreRuntime.invoke(try allocate(sessionClass), "init")
      }
    guard let session else {
      throw PrivateAPIErrorShim.rejected("MSSession would not initialise")
    }
    let messageClass = try requireMessagesClass("MSMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        try allocate(messageClass), "initWithSession:", [session])
    else {
      throw PrivateAPIErrorShim.rejected("MSMessage would not initialise")
    }
    try IMCoreRuntime.invoke(message, "setURL:", [url])
    // A LIVE layout wrapping the template, not the template alone. MEASURED: a poll sent
    // with only `MSMessageTemplateLayout` arrives as a plain balloon reading "Sent a poll"
    // with an "Add Choice" button and no options — the transcript falls back to the
    // template because the archive has no `liveLayoutInfo`. Apple's polls carry one
    // (`{layoutClass: MSMessageLiveLayout}`), which `MSMessage` writes itself when its
    // layout is an `MSMessageLiveLayout`; the template becomes the `alternateLayout` and
    // still supplies the caption other devices show while the poll loads.
    let templateClass = try requireMessagesClass("MSMessageTemplateLayout")
    guard let template = try IMCoreRuntime.invoke(try allocate(templateClass), "init") else {
      throw PrivateAPIErrorShim.rejected("MSMessageTemplateLayout would not initialise")
    }
    try? IMCoreRuntime.invoke(template, "setCaption:", ["Sent a poll"])
    let liveClass = try requireMessagesClass("MSMessageLiveLayout")
    guard
      let live = try IMCoreRuntime.invoke(
        try allocate(liveClass), "initWithAlternateLayout:", [template])
    else {
      throw PrivateAPIErrorShim.rejected("MSMessageLiveLayout would not initialise")
    }
    try IMCoreRuntime.invoke(message, "setLayout:", [live])
    try? IMCoreRuntime.invoke(message, "setSummaryText:", ["Sent a poll"])

    let compositionClass: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        compositionClass as AnyObject, "compositionWithMSMessage:appExtensionIdentifier:",
        [message, PollsApp.extensionIdentifier])
    else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit would not build a composition for the Polls extension — is it installed?")
    }
    return composition
  }

  /// The vote message, ready for `-[IMChat sendMessage:]`.
  ///
  /// Transcribed from `-[CKCoreChatController transcriptCollectionViewController:
  /// balloonViewDidRequestSendCustomAcknowledgementPayload:forPlugin:error:]`: the
  /// acknowledgement's archived payload, the poll-state GUID it answers (bare — ChatKit
  /// prefixes `bp:` only to look the chat item up), the Polls bundle id, and a summary
  /// carrying what the notification shows. `configureMessageSummaryInfoForChatItem:` wants
  /// a ChatKit chat item; the four keys it produces for a vote are written directly.
  static func voteMessage(_ request: PollVoteRequest) throws -> AnyObject {
    let voter = try ownHandle()
    guard let uuid = UUID(uuidString: request.sessionID) else {
      throw PrivateAPIErrorShim.rejected("the poll session id is not a UUID")
    }
    let sessionClass = try requireMessagesClass("MSSession")
    guard
      let session = try IMCoreRuntime.invoke(
        try allocate(sessionClass), "initWithIdentifier:", [uuid as NSUUID])
    else {
      throw PrivateAPIErrorShim.rejected("MSSession would not initialise")
    }
    let ackClass = try requireMessagesClass("_MSMessageCustomAcknowledgement")
    guard
      let ack = try IMCoreRuntime.invoke(
        try allocate(ackClass), "initWithSession:isFromMe:time:", [session, true, NSDate()])
    else {
      throw PrivateAPIErrorShim.rejected("the acknowledgement would not initialise")
    }
    try IMCoreRuntime.invoke(
      ack, "setURL:", [try dataURL(json: votesJSON(optionIDs: request.optionIDs, voter: voter))])
    guard
      let payload = try IMCoreRuntime.invoke(
        ack, "_payloadDataFromAppName:adamID:", [PollsApp.appName, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("the acknowledgement produced no payload")
    }

    let summary: [String: Any] = [
      "amc": 9,
      "ams": "Sent a vote",
      "amb": PollsApp.balloonBundleID,
      "amd": PollsApp.appName,
    ]
    let messageClass: AnyClass = try IMCoreRuntime.requireClass("IMMessage")
    guard
      let message = try IMCoreRuntime.invoke(
        messageClass as AnyObject,
        "customAcknowledgementMessageWithPayloadData:associatedMessageGUID:balloonBundleID:"
          + "messageSummaryInfo:threadIdentifier:",
        [payload, request.stateGUID.rawValue, PollsApp.balloonBundleID, summary, NSNull()])
    else {
      throw PrivateAPIErrorShim.rejected("IMMessage would not build the vote")
    }
    return message
  }
}

// MARK: - Reply threads

/// What a reply carries so that Messages threads it.
///
/// A thread identifier is not a message GUID. `IMCreateThreadIdentifier` formats it as
/// `r:<part index>:<range location>:<range length>:<message guid>` (disassembled from IMCore
/// on macOS 26.5.2), and imagent splits it back with
/// `IMMessageThreadIdentifierGetComponents` into chat.db's `thread_originator_guid` and
/// `thread_originator_part` (`0:0:29`). Hand it a bare GUID and the split fails, the message
/// sends, and it is simply not a reply — measured on both send paths, with no error
/// anywhere. The shipping Objective-C helper never made that mistake: from its first reply
/// support (Big Sur, October 2021) it resolves the target PART chat item, reuses the thread
/// it is already in, or asks IMCore to create one (`BlueBubblesHelper.m:1106`), on every
/// macOS it runs on. This is that, in the order it does it, and it is the only path — the
/// bare GUID was the port's invention and there is no release it is known to be right on.
///
/// **Synchronous, and used inside the same block as the send.** The originator comes back
/// from an accessor at +0, alive only until the autorelease pool drains — and a Swift
/// `await` drains it. The first version of this returned it from an `async` function and
/// Messages crashed in `objc_retain` on the way back (Messages-2026-09-02-211127.ips). The
/// caller loads the part asynchronously (that reference is retained by the Swift array it
/// came out of) and then does everything else without suspending.
enum IMThreads {

  struct Reply {
    /// What goes in `threadIdentifier`.
    let identifier: String
    /// The `IMMessage` that started the thread, for `threadOriginator`. Best effort: a
    /// reply threads without it, but Messages' own sends set it and so does the reference.
    let originator: AnyObject?
  }

  /// The thread a reply to this message part belongs to.
  static func reply(for part: AnyObject) throws -> Reply {
    // Already in a thread: join it, so a reply to a reply lands under the same originator
    // rather than starting a thread under the reply.
    if let existing = ((try? IMCoreRuntime.string(part, "threadIdentifier")) ?? nil),
      !existing.isEmpty
    {
      let originatorItem = ((try? IMCoreRuntime.send(part, "threadOriginator")) ?? nil)
      return Reply(identifier: existing, originator: originatorItem.flatMap(message(of:)))
    }
    return Reply(identifier: try createIdentifier(for: part), originator: message(of: part))
  }

  /// `IMCreateThreadIdentifierForMessagePartChatItem`, an exported C function in IMCore.
  ///
  /// Looked up by name rather than linked, for the reason everything else here is: a
  /// symbol that moves must degrade to a report, not a helper that fails to load.
  ///
  /// **The return is +0, `Create` in the name notwithstanding.** Its disassembly ends in
  /// `b objc_autoreleaseReturnValue` (and so does `IMCreateThreadIdentifier` under it), and
  /// the reference declares it as a plain `NSString *` C function, which ARC also treats as
  /// unretained — the CF "Create rule" does not apply to Objective-C returns. Taking it as
  /// retained consumed a reference Messages still held through the message's copied
  /// `threadIdentifier`, and TextInput later crashed reading the freed string
  /// (Messages-2026-09-02-212814.ips, `-[TIInputContextEntry threadIdentifier]`). So:
  /// unretained, bridged to a String that keeps its own reference.
  ///
  /// When the symbol is absent the identifier is formatted here from the same three values
  /// the function reads off the part (its index, its range in the message text and the
  /// message GUID).
  private static func createIdentifier(for part: AnyObject) throws -> String {
    typealias Create = @convention(c) (AnyObject) -> Unmanaged<NSString>?
    if let symbol = dlsym(
      UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
      "IMCreateThreadIdentifierForMessagePartChatItem"
    ) {
      let create = unsafeBitCast(symbol, to: Create.self)
      if let identifier = create(part)?.takeUnretainedValue() {
        let copied = String(identifier)
        if !copied.isEmpty { return copied }
      }
    }

    // The function's own recipe, from its disassembly: `r:%lu:%lu:%lu:%@`.
    let index = (try? IMCoreRuntime.integer(part, "index")) ?? 0
    let range = try IMStickers.partRange(part)
    guard let message = message(of: part),
      let guid = ((try? IMCoreRuntime.string(message, "guid")) ?? nil), !guid.isEmpty
    else {
      throw PrivateAPIErrorShim.rejected("could not identify the message being replied to")
    }
    return "r:\(max(index, 0)):\(range.location):\(range.length):\(guid)"
  }

  /// The `IMMessage` behind a chat item or a message item.
  ///
  /// Both answer `message`; guarded because an aggregate (gallery) part is a different
  /// class and a missing selector here must cost the originator, not the send.
  private static func message(of item: AnyObject) -> AnyObject? {
    guard IMCoreRuntime.responds(item, to: NSSelectorFromString("message")) else { return nil }
    return (try? IMCoreRuntime.send(item, "message")) ?? nil
  }
}

// MARK: - Stickers

/// The sticker model and the ChatKit objects that turn one into a sendable composition.
///
/// Every selector here was read out of Messages' own drag-and-drop send on macOS 26.5.2
/// (`-[CKChatController sendSticker:withDragTarget:draggedSticker:]` and what it calls),
/// so the objects are built the way Messages builds them rather than assembled from the
/// attachment path with a flag flipped. The difference is visible on every other device:
/// a plain attachment sent with `associatedMessageType` 1000 has no `stickerUserInfo`,
/// no `isSticker` on its transfer and no attribution, and iOS draws it as a broken
/// attachment rather than a sticker.
///
/// The chain, in the order Messages runs it:
///
///     IMSticker  ──▶  +[IMSticker userInfoDictionaryWithLayoutIntent:…]   (the geometry)
///                ──▶  -[CKMediaObjectManager mediaObjectWithSticker:stickerUserInfo:]
///                        copies the file into ChatKit's staging area, creates the
///                        transfer through -[CKIMFileTransfer initWithStickerFileURL:…]
///                        (isSticker = YES, stickerUserInfo, attributionInfo), registers
///                        it with IMFileTransferCenter
///                ──▶  +[CKComposition stickerCompositionWithMediaObjects:]
///                ──▶  IMMessage (IMMessageBuilder.sticker)
///                ──▶  -[CKConversation sendMessage:newComposition:NO]
enum IMStickers {

  /// The pack every user-made sticker on this Mac belongs to.
  ///
  /// Read from the `pid` of received stickers and from the attribution row Messages writes
  /// for its own: user-generated stickers (the ones lifted out of a photo) are attributed
  /// to the built-in Stickers extension, and this is its plugin identifier. It doubles as
  /// the balloon bundle id, which is what `mediaObjectWithSticker:` looks up to attach the
  /// "Stickers" attribution that the sticker detail sheet shows on the receiving device.
  static let userGeneratedPackID =
    "com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:"
    + "com.apple.Stickers.UserGenerated.MessagesExtension"

  /// An `IMSticker` for a file on disk.
  ///
  /// ObjC: `-[IMSticker initWithStickerID:stickerPackID:fileURL:accessibilityLabel:
  /// accessibilityName:moodCategory:stickerName:]`. The sticker id is a fresh UUID with
  /// the file's extension, which is the shape Messages uses for its own (`sid` on the
  /// attachment row is `<UUID>.heic`); it identifies the sticker in recents and in the
  /// dedup of the receiving device's sticker drawer, so it must not repeat across sends.
  ///
  /// TWO GENERATIONS. `accessibilityName:` was inserted **in the middle** of the keyword
  /// list in macOS 15, right after `accessibilityLabel:`:
  ///
  ///   15, 26    …fileURL:accessibilityLabel:accessibilityName:moodCategory:stickerName:
  ///   14        …fileURL:accessibilityLabel:moodCategory:stickerName:
  ///
  /// so the older form takes one fewer argument, not the same arguments under another name.
  /// Calling only the newer meant stickers did not send at all on Sonoma
  /// (`docs/SONOMA_COMPATIBILITY.md` §3). Every argument after the URL is `NSNull` here —
  /// Messages leaves them nil for a user-generated sticker — which is why dropping one
  /// changes nothing about the sticker that gets built.
  static func sticker(path: String) throws -> AnyObject {
    guard FileManager.default.fileExists(atPath: path) else {
      throw PrivateAPIErrorShim.rejected("no file at \(path)")
    }
    let type: AnyClass = try IMCoreRuntime.requireClass("IMSticker")
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate an IMSticker")
    }
    let url = URL(fileURLWithPath: path)
    let extensionPart = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
    let stickerID = UUID().uuidString + extensionPart

    let leading: [Any] = [stickerID, userGeneratedPackID, url as NSURL]
    let candidates: [(String, [Any])] = [
      (
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:accessibilityName:"
          + "moodCategory:stickerName:",
        leading + [NSNull(), NSNull(), NSNull(), NSNull()]
      ),
      (
        "initWithStickerID:stickerPackID:fileURL:accessibilityLabel:moodCategory:"
          + "stickerName:",
        leading + [NSNull(), NSNull(), NSNull()]
      ),
    ]
    guard
      let (selector, arguments) = candidates.first(where: {
        IMCoreRuntime.responds(allocated, to: NSSelectorFromString($0.0))
      })
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "sendSticker", requires: "an IMSticker initWithStickerID: initializer")
    }
    guard
      let sticker = try IMCoreRuntime.invoke(
        allocated,
        selector,
        arguments
      )
    else {
      throw PrivateAPIErrorShim.rejected("IMSticker would not initialise for \(path)")
    }
    // What `mediaObjectWithSticker:` looks up for attribution. Set separately because the
    // initializer has no parameter for it.
    if IMCoreRuntime.responds(sticker, to: NSSelectorFromString("setBallonBundleID:")) {
      try? IMCoreRuntime.invoke(sticker, "setBallonBundleID:", [userGeneratedPackID])
    }
    return sticker
  }

  /// The `stickerUserInfo` dictionary: where the sticker sits on its parent.
  ///
  /// ObjC: `+[IMSticker userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:
  /// yScalar:scale:rotation:initialFrameIndex:stickerPositionVersion:externalURI:]`,
  /// which writes the `sli`/`spw`/`sxs`/`sys`/`ssa`/`sro`/`safi`/`spv`/`suri` keys.
  /// Messages passes layout intent 0, frame index 0 and position version 0 for a dropped
  /// sticker, and so does this. The external URI is `[sticker getSafeExternalURI]` there —
  /// a string, EMPTY for a sticker with no App Store origin — and it must be a string: the
  /// builder puts all ten values in a dictionary literal, and nil raises
  /// `attempt to insert nil object from objects[9]` (measured).
  ///
  /// TWO GENERATIONS, and unlike the initializer above the difference is at the END:
  /// `externalURI:` was appended in macOS 15. Sonoma's longest form stops at
  /// `stickerPositionVersion:`, so it takes eight values rather than nine and the
  /// dictionary it builds simply has no `suri` key — which is what a Sonoma sticker
  /// legitimately looks like, since `externalURI` is empty for a user-generated one
  /// anyway. `docs/SONOMA_COMPATIBILITY.md` §3.
  static func userInfo(placement: StickerPlacement) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("IMSticker")
    let geometry: [Any] = [
      UInt(0), placement.parentPreviewWidth, placement.xScalar, placement.yScalar,
      placement.scale, placement.rotation, UInt(0), UInt(0),
    ]
    let candidates: [(String, [Any])] = [
      (
        "userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:"
          + "rotation:initialFrameIndex:stickerPositionVersion:externalURI:",
        geometry + [""]
      ),
      (
        "userInfoDictionaryWithLayoutIntent:parentPreviewWidth:xScalar:yScalar:scale:"
          + "rotation:initialFrameIndex:stickerPositionVersion:",
        geometry
      ),
    ]
    guard
      let (selector, arguments) = candidates.first(where: {
        (type as AnyObject).responds(to: NSSelectorFromString($0.0))
      })
    else {
      throw PrivateAPIError.unavailableOnThisOS(
        method: "sendSticker",
        requires: "an IMSticker userInfoDictionaryWithLayoutIntent: class method")
    }
    guard
      let dictionary = try IMCoreRuntime.invoke(type as AnyObject, selector, arguments)
    else {
      throw PrivateAPIErrorShim.rejected("IMSticker produced no sticker user info")
    }
    return dictionary
  }

  /// The ChatKit media object wrapping a sticker transfer.
  ///
  /// ObjC: `-[CKMediaObjectManager mediaObjectWithSticker:stickerUserInfo:]`. This is the
  /// step that does the work the attachment path does by hand elsewhere: it copies the
  /// file into ChatKit's own staging directory, creates the transfer through
  /// `initWithStickerFileURL:…` — which is where `isSticker`, `stickerUserInfo` and the
  /// attribution land on the `IMFileTransfer` — and registers it with the transfer center.
  /// It logs and returns nil when any of that fails, so nil here is reported rather than
  /// sent.
  static func mediaObject(sticker: AnyObject, userInfo: AnyObject) throws -> AnyObject {
    let manager = try IMCoreRuntime.sharedInstance(ofClass: "CKMediaObjectManager")
    guard
      let media = try IMCoreRuntime.invoke(
        manager, "mediaObjectWithSticker:stickerUserInfo:", [sticker, userInfo]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "ChatKit would not build a media object for the sticker — the file may not be an "
          + "image, or could not be copied into Messages' container"
      )
    }
    return media
  }

  /// ObjC: `+[CKComposition stickerCompositionWithMediaObjects:]`, which is
  /// `compositionWithMediaObjects:subject:nil` under a name that says what it is for.
  static func composition(media: AnyObject) throws -> AnyObject {
    let type: AnyClass = try IMCoreRuntime.requireClass("CKComposition")
    guard
      let composition = try IMCoreRuntime.invoke(
        type as AnyObject, "stickerCompositionWithMediaObjects:", [[media]]
      )
    else {
      throw PrivateAPIErrorShim.rejected("could not build a sticker composition")
    }
    return composition
  }

  /// The message text a composition sends as: the attachment placeholder character
  /// carrying the transfer GUID as an attribute.
  ///
  /// ObjC: `-[CKComposition superFormatText:]`, called with a NULL out-pointer. Messages
  /// passes a real one to collect the transfer GUIDs; the GUID is read off the media
  /// object instead, because the invocation bridge only writes nil into pointer arguments
  /// (and rightly — see `BBSetArgument`). Same text either way.
  static func superFormatText(_ composition: AnyObject) throws -> NSAttributedString {
    guard
      let text = try IMCoreRuntime.invoke(composition, "superFormatText:", [NSNull()])
        as? NSAttributedString
    else {
      throw PrivateAPIErrorShim.rejected("the sticker composition produced no message text")
    }
    return text
  }

  /// The range of a message part within its message's text.
  ///
  /// ObjC: `-[IMMessagePartChatItem messagePartRange]`. A struct return, which is why the
  /// invocation bridge boxes those as `NSValue`.
  static func partRange(_ part: AnyObject) throws -> NSRange {
    guard let value = try IMCoreRuntime.invoke(part, "messagePartRange") as? NSValue else {
      throw PrivateAPIErrorShim.rejected("that message part reports no range")
    }
    return value.rangeValue
  }
}

// MARK: - The sticker store

/// Writing into this Mac's sticker store, which is what puts a sticker in the picker.
///
/// The store is `stickers.stickerdb` inside the `com.apple.stickersd.group` container, owned
/// by `stickersd`. READING it needs none of this — the server opens that SQLite file
/// directly, so listing stickers works on a Mac with no helper at all (see
/// `StickerLibrary`). Writing does: the container is entitled to the group, and Messages
/// holds that entitlement while this server does not.
///
/// The only write Messages exposes is a DONATION to recents:
///
///     -[_STKMessagesObjCStoreFacade
///         donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:
///         externalURI:name:accessibilityName:metadata:attributionInfo:error:]
///
/// which is what Messages itself calls after sending a sticker. There is no "add to the
/// saved library" call on the facade, and that asymmetry is real rather than an oversight
/// on our part — saved stickers are created by the Stickers extension lifting a subject out
/// of a photo, which is a UI flow, not an API. `docs/STICKER_LIBRARY.md` records the
/// measurements.
enum IMStickerStore {

  /// Stickers.framework is private and may not be loaded until the picker is first opened.
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/Stickers.framework/Stickers"

  private static func requireStickersClass(_ name: String) throws -> AnyClass {
    if let found = IMCoreRuntime.lookUpClass(name) { return found }
    _ = dlopen(frameworkPath, RTLD_NOW)
    return try IMCoreRuntime.requireClass(name)
  }

  private static func allocate(_ type: AnyClass) throws -> AnyObject {
    guard
      let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?
        .takeUnretainedValue()
    else {
      throw PrivateAPIErrorShim.rejected("could not allocate \(type)")
    }
    return allocated
  }

  /// The role the store files a single-image sticker under.
  ///
  /// Messages writes TWO representations for a sticker it made itself — a `still` HEIC at
  /// full size and a `keyboard` PNG preview — and NO role at all (an empty string) for the
  /// emoji and Genmoji rows. A single uploaded image is the second shape, so the role is
  /// left empty rather than claimed to be a still of something with no keyboard preview.
  static let singleImageRole = ""

  /// One representation over an image's bytes.
  ///
  /// **`_STKStickerUIStickerRepresentation`, not `STKStickerRepresentation`** — and the
  /// difference is not cosmetic. `STKStickerRepresentation` is the archivable model, and its
  /// `-init` is a Swift **unimplemented initializer**: it loads the strings
  /// `"Stickers.Representation"` and `"init()"` and executes `brk #0x1`. Calling it does not
  /// fail, it TRAPS — measured, and it took Messages down with `EXC_BREAKPOINT` at
  /// `Stickers` + 0x7306c, which is that `brk` exactly.
  ///
  /// The type the donation actually wants was read out of the facade itself:
  /// `-donateStickerToRecentsWithIdentifier:…` calls `type metadata accessor for
  /// Stickers._STKStickerUIStickerRepresentation` at +76, before it touches anything else.
  /// That class has a real, complete initializer — `-initWithData:type:size:role:` — which
  /// is why nothing here needs setters.
  static func representation(data: Data, role: String = singleImageRole) throws -> AnyObject {
    let type: AnyClass = try requireStickersClass("_STKStickerUIStickerRepresentation")
    let (uti, size) = try Self.describe(data)
    guard
      let representation = try IMCoreRuntime.invoke(
        try allocate(type), "initWithData:type:size:role:",
        [data as NSData, uti, NSValue(size: size), role]
      )
    else {
      throw PrivateAPIErrorShim.rejected(
        "the sticker store would not accept that image as a representation")
    }
    return representation
  }

  /// The image's uniform type identifier and pixel size, read from the bytes.
  ///
  /// Read rather than taken from the filename: the store records a UTI per representation
  /// and a size it draws with, and a client that uploads a PNG named `.heic` should not end
  /// up with a row that lies about either. ImageIO is the same decoder Messages uses.
  private static func describe(_ data: Data) throws -> (uti: String, size: CGSize) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let uti = CGImageSourceGetType(source) as String?
    else {
      throw PrivateAPIErrorShim.rejected(
        "that file is not an image any installed decoder recognises")
    }
    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
    guard width > 0, height > 0 else {
      throw PrivateAPIErrorShim.rejected("that image reports no dimensions")
    }
    return (uti, CGSize(width: width, height: height))
  }

  /// Attribution: who this sticker came from, shown on the sticker detail sheet.
  ///
  /// Attributed to the built-in Stickers extension, the same as `IMStickers` uses for a
  /// send, because that is what a sticker made on this Mac genuinely is as far as the
  /// receiving device can tell.
  static func attribution() throws -> AnyObject {
    let type: AnyClass = try requireStickersClass("_STKStickerAttributionInfo")
    guard
      let info = try IMCoreRuntime.invoke(
        try allocate(type), "initWithAdamID:bundleIdentifier:name:",
        [NSNull(), IMStickers.userGeneratedPackID, "Stickers"]
      )
    else {
      throw PrivateAPIErrorShim.rejected("_STKStickerAttributionInfo would not initialise")
    }
    return info
  }

  /// Donates a sticker to recents, and answers with the identifier the store filed it under.
  ///
  /// The identifier is minted here rather than by the store — the selector takes it — and
  /// the external URI is built in the store's own `sticker:///user/identifier/<UUID>` shape,
  /// which is what every user-generated row in `stickers.stickerdb` carries.
  static func donateToRecents(
    data: Data, name: String?, accessibilityName: String?
  ) throws -> (identifier: UUID, externalURI: String) {
    let type: AnyClass = try requireStickersClass("_STKMessagesObjCStoreFacade")
    guard let facade = try IMCoreRuntime.invoke(try allocate(type), "init") else {
      throw PrivateAPIErrorShim.rejected("_STKMessagesObjCStoreFacade would not initialise")
    }

    let identifier = UUID()
    let externalURI = "sticker:///user/identifier/\(identifier.uuidString)"
    let representation = try representation(data: data)

    // -1 is what every row Messages wrote for a plain sticker carries; 0 is what the two
    // rows with an effect carry. No effect is the honest value for an uploaded image.
    let noEffect = Int64(-1)
    let result = try IMCoreRuntime.invoke(
      facade,
      "donateStickerToRecentsWithIdentifier:representations:stickerEffectEnum:externalURI:"
        + "name:accessibilityName:metadata:attributionInfo:error:",
      [
        // A STRING, not an NSUUID. Measured: passing the UUID object raises
        // `-[__NSConcreteUUID length]: unrecognized selector`, so the facade takes the
        // uppercase dashed form the store's own `ZEXTERNALURI` rows use.
        identifier.uuidString, [representation], noEffect, externalURI,
        name ?? "", accessibilityName ?? "", NSNull(), try attribution(), NSNull(),
      ]
    )

    // The selector returns BOOL and reports why through its `error` out-parameter, which
    // the invocation bridge cannot fill in — so a false here is reported as a refusal
    // rather than dressed up with a reason we do not have.
    if let answered = result as? NSNumber, !answered.boolValue {
      throw PrivateAPIErrorShim.rejected(
        "the sticker store refused the donation — the image may not be a type Stickers "
          + "reads, or stickersd may not be running"
      )
    }
    return (identifier, externalURI)
  }
}

extension IMChat {

  /// ObjC: `[chat sendMessage:]` (BlueBubblesHelper.m:1080).
  func send(_ message: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "sendMessage:", [message])
  }

  /// The GUID Messages assigned to what was just sent.
  ///
  /// ObjC: `[[chat lastSentMessage] guid]`. Read AFTER the send, because the GUID does not
  /// exist until Messages has accepted the message — there is no return value from
  /// `sendMessage:` to take it from.
  func lastSentMessageGUID() throws -> String? {
    guard let last = try IMCoreRuntime.invoke(object, "lastSentMessage") else { return nil }
    return try IMCoreRuntime.invoke(last, "guid") as? String
  }
}

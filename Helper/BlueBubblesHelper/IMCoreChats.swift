//  IMCoreObjects
//  Typed wrappers over the IMCore objects the port needs.
//
//  Each is a thin box around an `AnyObject` reached through `IMCoreRuntime`, so a selector
//  that moved in a macOS release fails on the one operation that needed it rather than
//  anywhere else. The alternative, the shipping helper's approach, is a hand-maintained
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
import HelperObjC
import HelperShared
import ObjectiveC.runtime

enum IMChatRegistry {

  /// Looks up an existing chat. Nil when Messages does not know the GUID.
  ///
  /// ObjC: `[[IMChatRegistry sharedInstance] existingChatWithGUID:]` (BlueBubblesHelper.m:159).
  ///
  /// Deliberately `existingChatWithGUID:` rather than a variant that creates one: a typo
  /// in a client's GUID should be an error, not a new empty conversation.
  static func chat(guid: String) throws -> IMChat? {
    let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
    guard let object = try IMCoreRuntime.send(registry, "existingChatWithGUID:", guid) else {
      return nil
    }
    return IMChat(object)
  }

  /// The chat whose IDENTIFIER (`chat.chat_identifier`: an address for a one-to-one chat, a
  /// `chat…` id for a group) is `chatIdentifier`, or nil when the registry has none.
  ///
  /// An identifier is not a GUID and is never reported as one: this is the lookup that turns
  /// one into the chat, whose `guid` is what goes on the wire. Present on 14.6.1 through
  /// 27.0.1 (`docs/headers/*/IMChatRegistry.h`).
  static func chat(chatIdentifier: String) throws -> IMChat? {
    let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
    guard
      let object = try IMCoreRuntime.send(
        registry, "existingChatWithChatIdentifier:", chatIdentifier)
    else { return nil }
    return IMChat(object)
  }

  /// The chat a pinned-conversation identifier names, or nil when the registry has none.
  ///
  /// A pinning identifier is NOT a chat GUID, so `existingChatWithGUID:` cannot resolve
  /// one; this is the registry's own lookup for them, present on 14.6.1 through 27.0.1.
  static func chat(pinningIdentifier: String) throws -> IMChat? {
    let registry = try IMCoreRuntime.sharedInstance(ofClass: "IMChatRegistry")
    guard
      let object = try IMCoreRuntime.send(
        registry, "existingChatWithPinningIdentifier:", pinningIdentifier)
    else { return nil }
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

/// `CKConversation`: the ChatKit view of a chat.
///
/// Participant changes go through this rather than `IMChat`: ChatKit is what enforces the
/// recipient limit, and `canInsertMoreRecipients` is the only way to know before trying.
enum CKConversationList {

  static func conversation(guid: String) throws -> CKConversation? {
    // `sharedConversationList`, and resolved at call time rather than load time.
    // ChatKit is not loaded when the dylib is inserted, so a reference taken at load
    // would be nil forever; the comment at BlueBubblesHelper.m:177 records exactly this.
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
  /// Takes a BOOL, so it goes through a typed IMP: `perform` would pass the boxed
  /// NSNumber's pointer as the byte, and a non-zero address always reads as `true`.
  func setLocalUserIsTyping(_ isTyping: Bool) throws {
    try IMCoreRuntime.callBool(object, "setLocalUserIsTyping:", isTyping)
  }

  /// Whether the other party is typing.
  ///
  /// ObjC: `chat.lastIncomingMessage.isTypingMessage` (BlueBubblesHelper.m:205). Note it
  /// is derived from the last incoming message rather than read directly; there is no
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
  /// The underscore is not a typo: the public `setDisplayName:` does not exist on IMChat,
  /// and this private one is what the shipping helper uses.
  /// ObjC: `[chat leave]`.
  ///
  /// `canLeaveChat` is consulted first because IMCore's `leave` on a one-to-one chat is a
  /// silent no-op: the caller would see success and the chat would still be there.
  /// ObjC: `[chat leave]`, falling back to `leaveiMessageGroup` (BlueBubblesHelper.m:576).
  ///
  /// Both are tried because the reference does: `leave` is not present on every macOS this
  /// runs on. `canLeaveChat` is consulted first only to turn the common no-op (leaving a
  /// one-to-one chat, which has nobody to leave) into an explanation rather than silence.
  func leave() throws {
    if let can = try? IMCoreRuntime.bool(object, "canLeaveChat"), can == false {
      throw PrivateAPIErrorShim.rejected(
        "this conversation cannot be left: one-to-one chats have nobody to leave"
      )
    }
    // ORDER MATTERS, and `leaveConversation` leads, but see the caveat below before
    // trusting that it helps.
    //
    // WHAT IS ESTABLISHED: `leave` returns without complaint on macOS 26 and the
    // conversation is still there afterwards. No participant-change row appears in
    // `chat.db`, so nothing happened. That is the same shape as the participant selectors,
    // which were removed outright, except this one fails quietly instead of trapping.
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
    // Until then this ordering is harmless (the ladder skips what is absent) and must not
    // be read as a fix.
    let selector = try IMCoreRuntime.requireResponding(
      object, among: ["leaveConversation", "leave", "leaveiMessageGroup"])
    try IMCoreRuntime.invoke(object, selector)
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
      filterCategory: filterCategory(),
      isKnownSender: (try? IMCoreRuntime.bool(object, "cachedIsKnownSender")) ?? false,
      isInUnknownSendersFilter: (try? IMCoreRuntime.bool(object, "inUnknownSendersFilter"))
        ?? false,
      wasDetectedAsSMSSpam: (try? IMCoreRuntime.bool(object, "wasDetectedAsSMSSpam")) ?? false,
      canReportJunk: hasMessageToReportAsJunk()
    )
  }

  /// ObjC: `-filterCategory`, which filter bucket the conversation sits in. Nil when this
  /// release cannot say.
  ///
  /// **macOS 27 has no answer, and nil is the honest one.** It took `filterCategory`,
  /// `filterSubCategory` and `smsCategory` off `IMChat` together (the 27.0.1 dump) and left
  /// no getter that reads a chat's category. `IMChatContext` still carries a `filterCategory`,
  /// but the one factory that builds a context for a given chat,
  /// `+[IMMutableChatContext chatContextForPinnedChat:]`, sets it to a literal 0: measured by
  /// disassembling it on 27.0.1, and by every chat on this Mac reading 0 through it, Junk and
  /// unknown senders included. A rung that always answers "inbox" is worse than none, so there
  /// is not one; a client is told the category is unknown rather than told the wrong one.
  func filterCategory() -> Int? {
    guard IMCoreRuntime.responds(object, to: "filterCategory") else {
      return nil
    }
    return try? IMCoreRuntime.integer(object, "filterCategory")
  }

  /// Whether this conversation has anything to report as junk.
  ///
  /// **Laddered, and the only field in `filterState()` that is.** `-_messageToReportJunk`
  /// arrives in macOS 15 — absent on 14.6.1, present on 15.6.1 and 26.5.2 — and reading it
  /// through a bare `try?` collapsed two different answers into one `false`: the property
  /// returning nil, which truthfully means nothing to report, and the selector not being
  /// there at all. On Sonoma that reported `false` for every conversation while
  /// `reportJunk(toCarrier:pendingCount:)` would go on to report one perfectly well through
  /// `-reportJunkToCarrier`, so a client that hides its button on this flag hid a working
  /// button. The evidence is the dumps themselves: `docs/headers/macos-14.6.1/IMChat.h`
  /// declares `-allMessagesToReportAsSpam` and no `-_messageToReportJunk`, and 15.6.1 and
  /// 26.5.2 declare both. `docs/MACOS_COMPATIBILITY.md` §3b carries the sibling ladder.
  ///
  /// The older rung is `-allMessagesToReportAsSpam` being non-empty, which is the same
  /// source the junk ladder ALREADY reconstructs `-reportJunk`'s BOOL from on 14 and 15
  /// (see `reportJunk(toCarrier:pendingCount:)`). So on the release that needs the fallback,
  /// the flag and the call it gates answer from one place instead of contradicting one
  /// another.
  ///
  /// **The fallback runs only where the property is absent, never as a cross-check.**
  /// Everything else in `filterState()` is a cache IMCore keeps for the UI and answers with
  /// no work; `-allMessagesToReportAsSpam` walks every loaded chat item and rebuilds the
  /// array (see `messagesToReportAsSpamCount()`), which is not a cost to put on a read that
  /// clients poll.
  ///
  /// It inherits that walk's limit: the count sees the LOADED transcript, so on Sonoma a
  /// conversation Messages has never opened still answers `false`. That is strictly better
  /// than answering `false` for all of them, and closing it is the wider question in
  /// `../TODO.md`, not something a selector ladder can reach.
  private func hasMessageToReportAsJunk() -> Bool {
    if IMCoreRuntime.responds(object, to: "_messageToReportJunk") {
      // The guard changes nothing where the selector exists, which is what makes this safe
      // on 15 and 26 without a live run on each: `IMCoreRuntime.send` opens with the SAME
      // `responds(to:)` check and throws `selectorMissing` when it fails. Hoisting it just
      // separates the two answers `try?` used to flatten together — a nil return, which
      // truthfully means nothing to report, from the selector being absent.
      return (try? IMCoreRuntime.send(object, "_messageToReportJunk")) != nil
    }
    // The same call `messagesToReportAsSpamCount()` makes, deliberately, rather than a
    // second copy of it: if that method ever loads the transcript first, this flag starts
    // telling the truth in the same change.
    return ((try? messagesToReportAsSpamCount()) ?? 0) > 0
  }

  /// How many messages a spam report would cover.
  ///
  /// This is what makes a dry run possible: the count is readable without reporting
  /// anything, so the path can be exercised against a real conversation.
  ///
  /// **It counts LOADED items, not the conversation.** Disassembled on 26.5.2,
  /// `-allMessagesToReportAsSpam` is one line: `[self messagesToReportAsSpamFromChatItems:
  /// [self chatItems]]`, and `-chatItems` builds its answer from the chat's in-memory
  /// `_items` through `chatItemRulesClass`. Nothing in that path queries `chat.db`. So a
  /// conversation whose transcript Messages has not loaded reports **zero** here, and a
  /// conversation the user has scrolled through reports more than one it has not.
  ///
  /// That is not a version difference; the same selectors are on 14.6.1, 15.6.1 and
  /// 26.5.2, and `IMChat` carries `loadMessagesUpToGUID:`, `loadMessagesBeforeDate:` and
  /// `loadUnreadMessagesWithLimit:` on all three. Nothing here calls them yet; see
  /// `../TODO.md`.
  ///
  /// Also not free: each call constructs a rules object, walks every loaded item and
  /// replaces the chat-item array, which is why `reportJunk(toCarrier:pendingCount:)` takes
  /// the count rather than reading it a second time.
  func messagesToReportAsSpamCount() throws -> Int {
    let messages = (try? IMCoreRuntime.objects(object, "allMessagesToReportAsSpam")) ?? []
    return messages.count
  }

  /// ObjC: `-markAsSpam:` / `-markAsSpam:isJunkReportedToCarrier:`.
  ///
  /// **The argument is a COUNT, not a reason code**, and the return is a count too, read
  /// from the disassembly rather than from the header, which says only `unsigned long long`:
  /// the method runs a `MarkAsSpam` query, calls `-_setCountOfMessagesMarkedAsSpam:` and
  /// returns an `integerValue`. So it is handed the number of messages this conversation
  /// has to report, which is `-allMessagesToReportAsSpam`'s count.
  ///
  /// `docs/PRIVATE_API_SURFACE.md` §3. If this turns out to be a category after all,
  /// the mistake is contained here: nothing above this line lets a client choose the number.
  func markAsSpam(count: Int, reportToCarrier: Bool) throws -> Int {
    let quantity = NSNumber(value: count)
    if IMCoreRuntime.responds(
      object, to: "markAsSpam:isJunkReportedToCarrier:"
    ) {
      return try IMCoreRuntime.callReturningInteger(
        object, "markAsSpam:isJunkReportedToCarrier:", [quantity, reportToCarrier]
      )
    }
    return try IMCoreRuntime.callReturningInteger(object, "markAsSpam:", [quantity])
  }

  /// ObjC: `-reportJunk`, plus the carrier relay when asked for.
  ///
  /// THREE GENERATIONS, and macOS 26 renamed both halves at once:
  ///
  ///   27        -reportJunk                    (no relay call at all)
  ///   26        -reportJunk                    -reportJunkToCarrierViaRelay:(BOOL)
  ///   14, 15    -reportJunkToCarrier           (the same call does both)
  ///
  /// On 14 and 15 there is only `-reportJunkToCarrier`, which reports and relays together;
  /// so `toCarrier` cannot be honoured as a choice there. It is honoured as a FLOOR: the
  /// report happens either way, and asking not to relay does not suppress it. Refusing the
  /// whole call to respect the flag would be worse; reporting junk is the point.
  ///
  /// **The relay is reported as what was DONE, never as what was asked.** macOS 27 removed
  /// `-reportJunkToCarrierViaRelay:` with no replacement on `IMChat` (the 27.0.1 dump; the
  /// carrier machinery now sits in `IMCarrierReportJunkHelper` and
  /// `-[IMChatRegistry _chat:sendReportJunkMessage:]`, neither called here). Whether `-reportJunk`
  /// relays on its own there is unmeasured: finding out means filing a real report. So
  /// `relayedToCarrier` is false on 27, and a client asking for the relay is told it did not
  /// happen rather than told it did.
  ///
  /// **The return has to be reconstructed on the older path.** `-reportJunk` returns whether
  /// there was anything to report; `-reportJunkToCarrier` returns void. So the count that
  /// `-reportJunk` is answering about is read first, from `-allMessagesToReportAsSpam`, which
  /// is on all three releases and is what `messagesToReportAsSpamCount()` already uses.
  ///
  /// Measured on 14.6.1, 15.6.1 and 26.5.2; see `docs/MACOS_COMPATIBILITY.md` §2b.
  /// `pendingCount` is what `messagesToReportAsSpamCount()` answered BEFORE this call, and
  /// it is a parameter rather than a second lookup for two reasons. It has to be read
  /// before the report, because afterwards the list is no longer the answer to "was there
  /// anything to report", and every caller has already read it, to decide the dry run.
  /// Reading it again here would be a second walk of `chatItems`, which is not free: see
  /// `messagesToReportAsSpamCount()` for what that costs.
  func reportJunk(toCarrier: Bool, pendingCount: Int) throws -> JunkReport {
    let selector = try IMCoreRuntime.requireResponding(
      object, among: ["reportJunk", "reportJunkToCarrier"])
    if selector == "reportJunk" {
      let reported = try IMCoreRuntime.callReturningBool(object, "reportJunk")
      let canRelay = IMCoreRuntime.responds(
        object, to: "reportJunkToCarrierViaRelay:")
      if toCarrier, canRelay {
        try IMCoreRuntime.invoke(object, "reportJunkToCarrierViaRelay:", [true])
      }
      return JunkReport(reported: reported, relayedToCarrier: toCarrier && canRelay)
    }

    try IMCoreRuntime.invoke(object, "reportJunkToCarrier")
    // One call that reports and relays together, so the relay happened whatever was asked.
    return JunkReport(reported: pendingCount > 0, relayedToCarrier: pendingCount > 0)
  }

  /// What `reportJunk(toCarrier:pendingCount:)` did.
  struct JunkReport {
    /// Whether there was anything to report.
    let reported: Bool
    /// Whether this call asked Messages to relay the report to the carrier.
    let relayedToCarrier: Bool
  }

  /// ObjC: `-updateIsFiltered:`, or recovery from Junk, which is not the same operation.
  ///
  /// `updateIsFiltered:` moves the chat between filters. Recovery has to undo the junk state
  /// as well, and macOS 26 folded both into one call:
  ///
  ///   26        -recoverFromJunkTo:(category)      undoes junk AND sets the filter
  ///   14, 15    -recoverFromJunk                   undoes junk only; the filter is ours
  ///
  /// So the older path is two calls, in that order: `updateIsFiltered:` alone moves the
  /// conversation out of the Junk FILTER while leaving it marked as junk, half the job,
  /// silently. `docs/MACOS_COMPATIBILITY.md` §3b.
  func updateFilter(category: Int, recovering: Bool) throws {
    if recovering {
      if IMCoreRuntime.responds(object, to: "recoverFromJunkTo:") {
        try IMCoreRuntime.invoke(object, "recoverFromJunkTo:", [NSNumber(value: category)])
        return
      }
      if IMCoreRuntime.responds(object, to: "recoverFromJunk") {
        try IMCoreRuntime.invoke(object, "recoverFromJunk")
        // Falls through to the filter move below, which is the other half.
      }
    }
    try IMCoreRuntime.invoke(object, "updateIsFiltered:", [NSNumber(value: category)])
  }

  /// Asks the daemon to download this conversation's background asset.
  ///
  /// Void and completion-less all the way down; it reaches
  /// `refetchChatBackgroundIfNeededForChatIdentifier:style:account:` on the remote daemon,
  /// which downloads in the background. "Did it work" is answered by the file appearing in
  /// `~/Library/Messages/TranscriptBackgroundCache`, not by this call.
  func refetchTranscriptBackground() throws {
    try IMCoreRuntime.invoke(object, "refetchLocalTranscriptBackgroundAssetIfNecessary")
  }

  /// ObjC: `editMessageItem:atPartIndex:…backwardCompatabilityText:` (BlueBubblesHelper.m:322).
  ///
  /// THREE selector generations, newest first (the reference does the same), and for the
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
    let (selector, arguments) = try IMCoreRuntime.requireResponding(object, among: candidates)
    try IMCoreRuntime.invoke(object, selector, arguments)
  }

  /// ObjC: `retractMessagePart:`; what a client calls "unsend".
  /// Cancels a scheduled message before it is delivered.
  ///
  /// Takes the message ITEM, not the GUID. MEASURED: the GUID form,
  /// `cancelScheduledMessageWithGUID:destinations:cancelType:` with nil destinations,
  /// returns without raising and leaves the row exactly as it was: still
  /// `schedule_state 2`, still due at its delivery time. The item form is what IMChat's own
  /// logging calls "(IMChat) Cancel scheduled message items", and it is the one the
  /// transcript's cancel action reaches.
  ///
  /// Cancel type 1 is the value IMCore's own path passes.
  func cancelScheduledMessage(item: AnyObject) throws {
    let selector = "cancelScheduledMessageItem:cancelType:"
    try IMCoreRuntime.requireResponding(object, to: selector)
    try IMCoreRuntime.invoke(object, selector, [item, UInt(1)])
  }

  /// Moves a scheduled message, or releases it to send now.
  ///
  /// ObjC: `-[IMChat editScheduledMessageItem:scheduleType:deliveryTime:]`, with the plural
  /// as the fallback: the transcript's own "Send Now" goes through the plural because a
  /// scheduled SECTION can hold several messages due at the same time
  /// (`-[CKTranscriptCollectionViewController dateCellRequestedScheduledMessageModification:
  /// scheduleType:deliveryTime:]` fetches them with `messagesForScheduledMessageSectionWithTranscriptItem:`).
  /// Addressing one message, the singular is the direct form.
  ///
  /// Send now is `scheduleType 0` with a NIL delivery time: the values that cell passes,
  /// and the branch IMCore logs as "Modifying scheduled time to be immediate". Rescheduling
  /// keeps `ScheduledSend.type` and gives the new date.
  func editScheduledMessage(item: AnyObject, scheduleType: UInt, deliveryTime: Date?) throws {
    let time: Any = deliveryTime.map { $0 as NSDate } ?? NSNull()
    let (selector, target) = try IMCoreRuntime.requireResponding(
      object,
      among: [
        ("editScheduledMessageItem:scheduleType:deliveryTime:", item),
        ("editScheduledMessageItems:scheduleType:deliveryTime:", [item] as AnyObject),
      ])
    try IMCoreRuntime.invoke(object, selector, [target, scheduleType, time])
  }

  /// Rewrites one part of a scheduled message before it goes out.
  ///
  /// ObjC: `-[IMChat editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:]`,
  /// which takes the message ITEM, the part index as a `long long`, the replacement as an
  /// attributed string, and a translation this passes nil for. Distinct from editing a SENT
  /// message (`CKConversation editMessageItem:partIndex:withNewComposition:`): nothing has
  /// been delivered, so IMCore rewrites the pending item in place rather than sending an
  /// edit that recipients see as one.
  ///
  /// TWO GENERATIONS. `newPartTranslation:` was appended in macOS 26:
  ///
  ///   26        …atPartIndex:withNewPartText:newPartTranslation:
  ///   15        …atPartIndex:withNewPartText:
  ///
  /// The older rung drops the argument this already passes as `NSNull()`, so nothing about
  /// the edit changes; Sequoia simply has no translation parameter to pass nil to.
  ///
  /// **macOS 14 reaches neither, and that is correct.** Sonoma has no Send Later at all
  /// (`CKSendLaterPluginInfo` is absent), so there is no scheduled message to edit and the
  /// request is refused by the gate at `MessageInterface.swift` long before it arrives here.
  /// `docs/MACOS_COMPATIBILITY.md` §3b.
  func editScheduledMessageText(
    item: AnyObject, partIndex: Int, text: NSAttributedString
  ) throws {
    let candidates: [(String, [Any])] = [
      (
        "editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:",
        [item, partIndex, text, NSNull()]
      ),
      (
        "editScheduledMessageItem:atPartIndex:withNewPartText:",
        [item, partIndex, text]
      ),
    ]
    let (selector, arguments) = try IMCoreRuntime.requireResponding(object, among: candidates)
    try IMCoreRuntime.invoke(object, selector, arguments)
  }

  func retractMessagePart(_ part: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "retractMessagePart:", [part])
  }

  func setDisplayName(_ name: String) throws {
    try IMCoreRuntime.invoke(object, "_setDisplayName:", [name])
  }
}

/// Mute state, from whichever of the two stores this macOS has.
///
/// MEASURED on macOS 26 (see `docs/PRIVATE_API_SURFACE.md` §2): `IMMutedChatList` is the
/// store, it is the `com.apple.MobileSMS.CKDNDList` defaults domain under `CKDNDListKey`,
/// keyed by MUTE IDENTIFIER rather than chat GUID (a hash for a 1:1 chat, the group id for
/// a group), and the value is an unmute instant in epoch seconds. Muted-ness is that instant
/// compared against now, which is why a timed mute needs nothing scheduled and why an
/// expired entry is not the same as a muted chat.
///
/// **`IMMutedChatList` does not exist on macOS 14**: not the selectors, the whole class
/// (`docs/MACOS_COMPATIBILITY.md` §3b, "Mute state"). What Sonoma has, and what 26 still has
/// alongside the list, is the older pair on `IMChat` itself: `-isMuted`, `-muteUntilDate`
/// and `-setMuteUntilDate:`.
///
/// So every operation here is written twice, and `list()` returning nil is the switch: nil,
/// not a throw, so the chat-level path is reachable on the one release that needs it (§2 of
/// that document).
///
/// The list is still PREFERRED wherever it exists, and not out of habit: it carries
/// `syncToPairedDevice:`, and it is where Messages itself reads on 26.
///
/// The chat property `ignoreAlertsFlag` still appears in `chat.properties` on older
/// conversations. It is not consulted on either path: Messages does not consult it either.

extension IMChat {

  /// ObjC: `[chat sendMessage:]` (BlueBubblesHelper.m:1080).
  func send(_ message: AnyObject) throws {
    try IMCoreRuntime.invoke(object, "sendMessage:", [message])
  }

  /// The GUID of the newest message this chat records as sent, or nil.
  ///
  /// Never the answer to "what did I just send" on its own: it is whatever was sent LAST,
  /// which is the previous message until ours lands. Read before a send whose own call
  /// returns nothing, so `sentTapback(since:on:)` can tell the new message from the old.
  func lastSentMessageGUID() throws -> String? {
    guard let last = try IMCoreRuntime.invoke(object, "lastSentMessage") else { return nil }
    return try IMCoreRuntime.string(last, "guid")
  }

  /// The tapback a send that returned nothing has just put into this chat, CONFIRMED to be
  /// that tapback, or nil.
  ///
  /// `-[IMTapbackSender send]` is void on 14.6.1 and 15.6.1 and returns the message only
  /// from 26.5.2 (`docs/headers/*/IMTapbackSender.h`), so on the older releases the message
  /// can only be found afterwards, on the chat. `lastSentMessage` alone is the previous
  /// message whenever ours has not landed yet, so the candidate is accepted only when it is
  /// NOT the message that was newest before the send (`before`) and it is a tapback on the
  /// message reacted to (its `associatedMessageGUID` names `target`, behind a `p:N/` or
  /// `bp:` part prefix). Anything else is nil, and the send is reported as unconfirmed
  /// rather than answered with another message's GUID.
  func sentTapback(since before: String?, on target: String) throws -> AnyObject? {
    guard let last = try IMCoreRuntime.invoke(object, "lastSentMessage"),
      let guid = try IMCoreRuntime.string(last, "guid"), !guid.isEmpty, guid != before,
      IMCoreRuntime.responds(last, to: "associatedMessageGUID"),
      let associated = try IMCoreRuntime.string(last, "associatedMessageGUID"),
      associated.hasSuffix(target)
    else { return nil }
    return last
  }
}

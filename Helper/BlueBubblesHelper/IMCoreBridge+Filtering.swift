//  IMCoreBridge+Filtering
//  Known senders, spam, junk reporting and the filter a chat sits in.
//  `ChatFiltering`.
//
//  One role's worth of `IMCoreBridge`; the class, its shared plumbing and the porting rules
//  are in `IMCoreBridge.swift`.

import AppKit
import BBPrivateAPIContract
import Foundation
import HelperShared

extension IMCoreBridge {

  /// PORTED. ObjC: `[chat deleteAllHistory]`.
  ///
  /// Destructive and synced: the messages go from every device on the account. The gate is
  /// above this: the route demands an explicit confirmation and raises a user alert,
  /// because a helper cannot tell an intended clear from an accidental one.
  public func clearChatHistory(_ chat: ChatIdentifier) async throws -> Bool {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).deleteAllHistory()
    }
  }

  public func chatFilterState(chat: ChatIdentifier) async throws -> ChatFilterState {
    try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue).filterState()
    }
  }

  /// PORTED. ObjC: `[chat markAsKnownAndSaveInContacts:completion:]`.
  ///
  /// The completion is bridged rather than ignored: it fires after IMCore has updated the
  /// filter, so returning before it would report the state as it was. A completion that
  /// never fires becomes a timeout, not a hang; IMCore calling back is not something this
  /// process can guarantee.
  public func markSenderKnown(
    chat: ChatIdentifier, saveInContacts: Bool
  ) async throws -> ChatFilterState {
    let conversation = try translating {
      try IMChatRegistry.requireChat(guid: chat.rawValue)
    }
    // IMCore has been observed firing a completion twice, and a second `resume` traps;
    // `ResumeOnce` is the latch. Its callback is not a promise either: after ten seconds the
    // state is read anyway: the write has normally landed, and reporting the CURRENT state
    // is more useful than failing a call that probably worked.
    let once = ResumeOnce<Void>()
    // ZERO PARAMETERS, matching every other completion bridged here.
    //
    // The header for this selector is `id /* block */`, so the block's arity is not
    // knowable from it. `FaceTimeBridge.callAwaitingCompletion` and
    // `FindMyBridge.requestLocationShare` both default to a zero-parameter block for
    // exactly that reason and cite a measured crash: a block declared with an argument
    // IMCore does not pass reads whatever is in the register and, if that value is then
    // bridged as an object, the host goes down. This site discards the value either way,
    // so declaring it bought nothing and carried that risk.
    let completion: @convention(block) () -> Void = { once.finish() }
    // THE INVOKE THROWS. It used to be wrapped in a `do/catch` that logged and carried on to
    // the state read below, which turned both of its failures into a success: a selector
    // this release does not have (every macOS below 26) and a refusal from IMCore (every
    // macOS, including the one where the feature works). Either way the caller was handed
    // the filter state as it already was, with a 200 on it, and no client can tell that from
    // "it worked and the flag did not move".
    //
    // The tolerance this method deliberately keeps is for the COMPLETION, not for the call:
    // `wait(timeout:)` returns whether or not IMCore calls back, so a completion that never
    // fires still reports the current state rather than hanging or failing. That was the
    // reasoning in the comment above, and it only ever applied to the wait.
    // `invoke` is `@discardableResult`, `translating` is not: the selector returns void and
    // the value is the wrapper's, so it is discarded here rather than at the inner call.
    _ = try translating {
      try IMCoreRuntime.invoke(
        conversation.object,
        "markAsKnownAndSaveInContacts:completion:",
        [saveInContacts, unsafeBitCast(completion, to: AnyObject.self)]
      )
    }
    await once.wait(timeout: .seconds(10))

    return try translating { try conversation.filterState() }
  }

  /// PORTED. New: no reference implementation for this one.
  public func markChatAsSpam(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let count = try conversation.messagesToReportAsSpamCount()
      guard !request.dryRun else {
        return ChatSpamResult(
          messageCount: count,
          reportedToCarrier: false,
          wasDryRun: true,
          filter: try conversation.filterState()
        )
      }
      let reported = try conversation.markAsSpam(
        count: count, reportToCarrier: request.reportToCarrier
      )
      return ChatSpamResult(
        messageCount: reported,
        reportedToCarrier: request.reportToCarrier,
        wasDryRun: false,
        filter: try conversation.filterState()
      )
    }
  }

  public func reportChatAsJunk(_ request: ChatSpamRequest) async throws -> ChatSpamResult {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: request.chat.rawValue)
      let count = try conversation.messagesToReportAsSpamCount()
      guard !request.dryRun else {
        return ChatSpamResult(
          messageCount: count,
          reportedToCarrier: false,
          wasDryRun: true,
          filter: try conversation.filterState()
        )
      }
      let reported = try conversation.reportJunk(
        toCarrier: request.reportToCarrier, pendingCount: count)
      return ChatSpamResult(
        messageCount: reported ? count : 0,
        reportedToCarrier: request.reportToCarrier,
        wasDryRun: false,
        filter: try conversation.filterState()
      )
    }
  }

  public func setChatFilter(chat: ChatIdentifier, category: Int) async throws -> ChatFilterState {
    try translating {
      let conversation = try IMChatRegistry.requireChat(guid: chat.rawValue)
      let current = try conversation.filterState()
      // Leaving Junk is `recoverFromJunkTo:`; everything else is `updateIsFiltered:`.
      // Junk is category 2 as measured on this machine; see `docs/CHAT_CONTROLS_PLAN.md` §5.2.
      try conversation.updateFilter(
        category: category, recovering: current.isFiltered != 0 && category == 0
      )
      return try conversation.filterState()
    }
  }
}

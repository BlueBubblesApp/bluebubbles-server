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
    let completion: @convention(block) (AnyObject?) -> Void = { _ in once.finish() }
    do {
      try IMCoreRuntime.invoke(
        conversation.object,
        "markAsKnownAndSaveInContacts:completion:",
        [saveInContacts, unsafeBitCast(completion, to: AnyObject.self)]
      )
      await once.wait(timeout: .seconds(10))
    } catch {
      BlueBubblesHelper.Logging.error("markAsKnown: \(error)")
    }

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

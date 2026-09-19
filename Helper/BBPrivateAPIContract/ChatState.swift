//  BBPrivateAPIContract: Chat state
//  Mute, filter and spam: the three per-chat flags the Private API can read and write.
//
//  Grouped because they are the same kind of thing and none of them is a message operation:
//  each is a property of the chat that outlives any message in it, and each has a read and a
//  write on `ChatMuting` or `ChatFiltering` in `PrivateAPI.swift`.
//
//  See `docs/CHAT_CONTROLS_PLAN.md`.

import Foundation

/// Whether a conversation is muted, and until when.
///
/// **Indefinite is not `nil`, and that distinction is measured rather than assumed.**
/// `IMMutedChatList` stores `[untilDate timeIntervalSince1970]` and decides muted-ness by
/// comparing that instant against now, so muting with no date stores `0.0` (1970), which
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
    // A date in the past is an EXPIRED mute, which is simply not muted; IMCore leaves
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
  public let chat: ChatIdentifier
  public let reportToCarrier: Bool
  /// Reports what WOULD happen (how many messages are eligible) and changes nothing.
  ///
  /// Exists so this path is testable against a real conversation without reclassifying it
  /// on every device on the account.
  public let dryRun: Bool

  public init(chat: ChatIdentifier, reportToCarrier: Bool = false, dryRun: Bool = false) {
    self.chat = chat
    self.reportToCarrier = reportToCarrier
    self.dryRun = dryRun
  }
}

/// What a spam or junk report did.
public struct ChatSpamResult: Codable, Sendable, Equatable {
  /// How many messages were reported, or for a dry run, how many would be.
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
  public let chat: ChatIdentifier
  /// When the mute lifts. `nil` means indefinitely, and is written as `Date.distantFuture`
  /// rather than as a nil date; see `ChatMuteState`.
  public let until: Date?
  /// Whether the change propagates to the paired iPhone. Exposed rather than hardcoded:
  /// muting here and not there is a legitimate thing to want, and so is the opposite.
  public let syncToPairedDevice: Bool

  public init(chat: ChatIdentifier, until: Date? = nil, syncToPairedDevice: Bool = true) {
    self.chat = chat
    self.until = until
    self.syncToPairedDevice = syncToPairedDevice
  }
}

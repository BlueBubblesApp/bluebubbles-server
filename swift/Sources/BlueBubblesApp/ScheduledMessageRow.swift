//  ScheduledMessageRow
//  What the Scheduled Messages page shows for one queued message.
//
//  Five decisions, and none of them is about layout: which section a message belongs in,
//  what its body reads as when there is none, which half of a chat GUID a person recognises,
//  how a stored recurrence is said aloud, and when a date should be relative rather than
//  absolute. They lived as `private func`s on `ScheduledMessagesView`, where a test cannot
//  reach them — touching a SwiftUI `View` type from a test process traps — so the page's
//  entire read of a record was unasserted.
//
//  Not a View, so the answers can be asserted; see `ScheduledMessageRowTests`, and
//  `SendLaterGuidance` for the same move on the notice above this list.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a decision that deserves a test cannot live on the
//  view that uses it.

import BBCore
import BBInterfaces
import BBSerialization
import Foundation

enum ScheduledMessageRow {

  // MARK: - Which section it belongs in

  static func status(of message: ScheduledMessage) -> ScheduledMessageStatus? {
    ScheduledMessageStatus(rawValue: message.status)
  }

  /// Upcoming and Past, in one place so the two cannot disagree about a status neither
  /// recognises.
  ///
  /// An unrecognised status counts as PAST rather than pending. A row the page cannot
  /// classify is one the server has already done something with — the statuses that exist
  /// are written by the sender — and showing it under "about to go out" would promise a send
  /// that is not coming.
  static func isUpcoming(_ message: ScheduledMessage) -> Bool {
    status(of: message) == .pending
  }

  static func partition(
    _ messages: [ScheduledMessage]
  ) -> (upcoming: [ScheduledMessage], past: [ScheduledMessage]) {
    (messages.filter(isUpcoming), messages.filter { !isUpcoming($0) })
  }

  // MARK: - Reading the record

  /// `payload` and `schedule` stay JSON because they genuinely are: both are opaque client
  /// blobs the server stores and never parses. Everything else on the row (status, error,
  /// the date) is a real column and is read as one.
  static func payload(of message: ScheduledMessage) -> JSONValue? {
    try? JSONValue.parse(message.payload)
  }

  static func text(of message: ScheduledMessage) -> String {
    let body = payload(of: message)?["message"]?.stringValue ?? ""
    return body.isEmpty ? "(no message text)" : body
  }

  /// The half of the chat GUID a person recognises.
  ///
  /// Through `ChatGUID`, not a split on `";-;"`. The split handled a DIRECT chat and left a
  /// group one untouched, because a group GUID is `any;+;chat…` and contains no `;-;` at
  /// all: every group in this list showed its raw GUID where every direct chat showed an
  /// address. `ChatGUID` knows both separators, and it is the type the rest of the server
  /// already uses for exactly this.
  ///
  /// A GUID it cannot parse is returned whole rather than dropped: an unfamiliar spelling is
  /// still the only identifier the row has.
  static func chat(of message: ScheduledMessage) -> String? {
    guard let guid = payload(of: message)?["chatGuid"]?.stringValue, !guid.isEmpty
    else { return nil }
    return ChatGUID(guid)?.address ?? guid
  }

  /// How often it repeats, in the words the composer's own picker used.
  ///
  /// Read back through `ScheduleRecurrence`, so a row says "daily" or "every 3 days". It
  /// rendered the stored WIRE value instead ("every 2 × daily") because the type that knows
  /// the vocabulary was private to the composer.
  static func recurrence(of message: ScheduledMessage) -> String? {
    guard let raw = message.schedule,
      let schedule = try? JSONValue.parse(raw),
      schedule["type"]?.stringValue == "recurring",
      let interval = schedule["intervalType"]?.stringValue,
      let recurrence = ScheduleRecurrence(intervalType: interval)
    else { return nil }
    return recurrence.summary(every: schedule["interval"]?.intValue ?? 1)
  }

  /// Anything inside this window of now is said relatively.
  ///
  /// "in 20 minutes" is what you want for something imminent and useless for something three
  /// months old. Eighteen hours rather than a day so that "tomorrow morning" reads as a date
  /// and not as "in 19 hours", which is a number nobody converts.
  static let relativeWindow: TimeInterval = 60 * 60 * 18

  /// When it goes out, relative or absolute.
  ///
  /// `now` is a parameter so this can be asserted at all: the rule is a comparison against
  /// the clock, and a function that reads the clock itself can only be tested by waiting.
  static func when(_ message: ScheduledMessage, now: Date = Date()) -> String {
    // A `Date` column read as a `Date`, not formatted to an ISO string in the interface and
    // parsed back here, and not read as epoch milliseconds, which the wire rule elsewhere
    // would suggest and which silently shows an em dash for every scheduled message.
    let date = message.scheduledFor
    if abs(date.timeIntervalSince(now)) < relativeWindow {
      return date.formatted(.relative(presentation: .named))
    }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  /// Whether `when` will phrase this relatively. Exposed so the rule can be asserted without
  /// depending on the locale's wording, which `formatted` owns and this file does not.
  static func isRelative(_ message: ScheduledMessage, now: Date = Date()) -> Bool {
    abs(message.scheduledFor.timeIntervalSince(now)) < relativeWindow
  }
}

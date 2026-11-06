//  AuditRepeatLimiter
//  One record per refused client per minute, and a count of the rest.
//
//  A refusal costs the client nothing and costs the server a row. A blocked client, a port
//  scanner or a misconfigured app that keeps retrying a wrong password is refused at the rate
//  it can send, and a row per refusal lets anyone who can reach the server fill its disk:
//  measured, 150,000 refused requests are about 95 MB of `app.db`, the database that also
//  holds the settings, and the retention sweep is no ceiling against a rate.
//
//  So a DENIED record about a CLIENT is kept once per window for each kind, client and route,
//  and the repeats inside the window are counted rather than stored. When the window closes,
//  one `audit.repeats_suppressed` record says how many there were and over what span, so the
//  gap is visible and sized rather than silent. Nothing else is limited: a success is an
//  action somebody took, an operator's or the server's own refusal is rare, and a failure is
//  worth seeing every time.
//
//  Bounded: at most `maximumOpenWindows` keys are tracked, and a new key past that closes the
//  oldest window early (its count is reported, not lost). A client rotating addresses gains a
//  window per address, and each address is blocked by access control after a handful of
//  failures, so the bound is reached only by a large botnet, which it then caps.
//
//  A value type the recorder owns and calls from inside its actor, so it needs no lock of its
//  own; time is the events' own `occurredAt`, so a test needs no clock.

import BBCore
import Foundation

struct AuditRepeatLimiter {

  /// How long one window lasts, from the record that opened it.
  static let window: TimeInterval = 60
  /// How many keys may have a window open at once.
  static let maximumOpenWindows = 1_024

  struct Key: Hashable {
    let kind: AuditEventKind
    let client: String?
    let route: String?
  }

  private struct OpenWindow {
    /// The record that was kept, which the summary copies its envelope from.
    let first: AuditEvent
    var suppressed = 0
    var firstSuppressedAt: Date?
    var lastSuppressedAt: Date?

    var closesAt: Date { first.occurredAt.addingTimeInterval(AuditRepeatLimiter.window) }
  }

  private var windows: [Key: OpenWindow] = [:]
  /// The earliest `closesAt` of any open window, so an event that closes nothing costs a
  /// comparison rather than a walk over every window.
  private var nextClose: Date?

  /// Whether this kind of record is limited at all.
  static func isLimited(_ event: AuditEvent) -> Bool {
    guard event.outcome == .denied, case .client = event.actor else { return false }
    return true
  }

  static func key(for event: AuditEvent) -> Key {
    Key(kind: event.kind, client: event.actor.identifier, route: event.route)
  }

  /// When the next window with a count to report closes, for a caller that wants to write the
  /// summary without waiting for the next event. Nil when nothing is waiting to be reported.
  var nextSummaryDue: Date? {
    windows.values.filter { $0.suppressed > 0 }.map(\.closesAt).min()
  }

  var openWindowCount: Int { windows.count }

  /// Decides whether `event` is stored, and returns the summaries of every window that had
  /// closed by the time it occurred, which go to the store first.
  mutating func admit(_ event: AuditEvent) -> (keep: Bool, summaries: [AuditEvent]) {
    var summaries = close(before: event.occurredAt)
    guard Self.isLimited(event) else { return (true, summaries) }

    let key = Self.key(for: event)
    if var open = windows[key] {
      open.suppressed += 1
      open.firstSuppressedAt = open.firstSuppressedAt ?? event.occurredAt
      open.lastSuppressedAt = event.occurredAt
      windows[key] = open
      return (false, summaries)
    }

    if windows.count >= Self.maximumOpenWindows,
      let oldest = windows.min(by: { $0.value.first.occurredAt < $1.value.first.occurredAt })
    {
      windows[oldest.key] = nil
      if let summary = Self.summary(of: oldest.value) { summaries.append(summary) }
    }
    let open = OpenWindow(first: event)
    windows[key] = open
    nextClose = min(nextClose ?? open.closesAt, open.closesAt)
    return (true, summaries)
  }

  /// Closes every window that ended at or before `now`, returning a summary for each that
  /// counted anything.
  mutating func close(before now: Date) -> [AuditEvent] {
    guard let due = nextClose, due <= now else { return [] }
    var summaries: [AuditEvent] = []
    var earliest: Date?
    for (key, open) in windows {
      if open.closesAt <= now {
        windows[key] = nil
        if let summary = Self.summary(of: open) { summaries.append(summary) }
      } else {
        earliest = min(earliest ?? open.closesAt, open.closesAt)
      }
    }
    nextClose = earliest
    return summaries.sorted { $0.occurredAt < $1.occurredAt }
  }

  /// Closes every window now, whatever its age. For the recorder stopping.
  mutating func closeAll() -> [AuditEvent] {
    let summaries = windows.values.compactMap(Self.summary(of:))
    windows = [:]
    nextClose = nil
    return summaries.sorted { $0.occurredAt < $1.occurredAt }
  }

  /// The record for a window's repeats, or nil when there were none.
  ///
  /// Built with no task-local context: the summary is written from whichever task closed the
  /// window, which is somebody else's request, and must not join to it.
  private static func summary(of open: OpenWindow) -> AuditEvent? {
    guard open.suppressed > 0, let firstAt = open.firstSuppressedAt,
      let lastAt = open.lastSuppressedAt
    else { return nil }
    let first = open.first
    let who = first.actor.identifier ?? "an unidentified client"
    let route = first.route.map { " on \($0)" } ?? ""
    return AuditContext.$current.withValue(nil) {
      AuditEvent(
        kind: .repeatsSuppressed,
        outcome: .denied,
        actor: first.actor,
        source: first.source,
        route: first.route,
        subject: first.subject,
        summary: "\(open.suppressed) more \(first.kind.rawValue) records from \(who)\(route) "
          + "were counted rather than stored.",
        metadata: [
          "repeated_kind": .string(first.kind.rawValue),
          "suppressed_count": .int(open.suppressed),
          "first_at": .string(AuditTimestamp.string(from: firstAt)),
          "last_at": .string(AuditTimestamp.string(from: lastAt)),
          "window_seconds": .int(Int(window)),
        ],
        occurredAt: lastAt
      )
    }
  }
}

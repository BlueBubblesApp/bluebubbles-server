//  AuditRowSummary
//  What the Audit Log page says about one record.
//
//  How an actor reads in a column, which outcome deserves a colour, when a timestamp is
//  relative, and what the detail sheet shows for the metadata: each is a decision rather than
//  layout, and each lived nowhere a test could reach until it was here. Not a View, so the
//  answers can be asserted; see `AuditRowSummaryTests`.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`: a decision that deserves a test cannot live on the
//  view that uses it.

import BBAudit
import BBCore
import Foundation

enum AuditRowSummary {

  // MARK: - Who

  /// The actor as a column reads it: "Client 10.0.0.5", "Operator", "Server (http)".
  ///
  /// A client nothing identified says so rather than showing a blank cell, because a blank
  /// in a Who column reads as a row with no author, and an authentication failure from an
  /// unidentifiable source is exactly the row an auditor is looking for.
  static func actor(_ actor: AuditActor) -> String {
    switch actor {
    case .client(let address?): "Client \(address)"
    case .client(nil): "Unidentified client"
    case .operator: "Operator"
    case .system(let component): "Server (\(component))"
    }
  }

  // MARK: - How it went

  /// Whether the outcome is worth a colour. Success is the ordinary case and gets none, so
  /// the two that are not stand out on a page of rows.
  enum OutcomeTone: Equatable {
    case neutral
    case failed
    case denied
  }

  static func tone(_ outcome: AuditOutcome) -> OutcomeTone {
    switch outcome {
    case .success: .neutral
    case .failure: .failed
    case .denied: .denied
    }
  }

  /// The word in the outcome tag.
  static func outcome(_ outcome: AuditOutcome) -> String {
    switch outcome {
    case .success: "OK"
    case .failure: "Failed"
    case .denied: "Denied"
    }
  }

  // MARK: - When

  /// How far back a timestamp is said relatively ("3 minutes ago") before it becomes a
  /// date. A day: within it the relative form is what a person scanning recent activity
  /// wants, and past it they want to be able to match the row against a log.
  static let relativeWindow: TimeInterval = 24 * 60 * 60

  static func isRecent(_ occurredAt: Date, now: Date = Date()) -> Bool {
    now.timeIntervalSince(occurredAt) < relativeWindow && occurredAt <= now
  }

  static func when(_ occurredAt: Date, now: Date = Date()) -> String {
    if isRecent(occurredAt, now: now) {
      return occurredAt.formatted(.relative(presentation: .named))
    }
    return occurredAt.formatted(date: .abbreviated, time: .shortened)
  }

  /// The timestamp as the record carries it, for the detail sheet and for matching against
  /// a receiver's copy: RFC 3339 UTC, the same string the CSV and syslog hold.
  static func exactTime(_ occurredAt: Date) -> String {
    AuditTimestamp.string(from: occurredAt)
  }

  // MARK: - What it was about

  /// "setting db_poll_interval", "client 10.0.0.5", or empty for a record about nothing in
  /// particular (a startup, a sweep).
  static func subject(_ subject: AuditSubject?) -> String {
    guard let subject else { return "" }
    return "\(subject.kind.replacingOccurrences(of: "_", with: " ")) \(subject.id)"
  }

  // MARK: - Detail

  /// The metadata as the detail sheet shows it: pretty-printed JSON with sorted keys, which
  /// is the same document a receiver holds, so what the person reads here is what their
  /// SIEM query will see. An empty object for a record with no metadata, never a blank.
  static func metadataJSON(_ metadata: [String: AuditValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(AuditValue.object(metadata)) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - Export

  /// The name the save panel proposes: the product, the word, and the day, so a folder of
  /// exports sorts by date and nothing in the name is a guess at the content.
  static func exportFileName(now: Date = Date(), calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: now)
    let year = parts.year ?? 0
    let month = parts.month ?? 0
    let day = parts.day ?? 0
    return String(format: "bluebubbles-audit-%04d-%02d-%02d.csv", year, month, day)
  }
}

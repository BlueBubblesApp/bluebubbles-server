//  AuditCSV
//  The audit log as a spreadsheet.
//
//  RFC 4180: a header row, one record per line, CRLF line endings, and a field is quoted when
//  it holds a comma, a quote, a carriage return or a newline, with quotes doubled inside. The
//  envelope's columns are the table's columns in the table's order, and the kind-specific
//  fields travel as one `metadata` column holding the JSON document, because a spreadsheet
//  with a column per key of every kind would be mostly empty cells and would change shape
//  every time a kind was added.
//
//  Written a page at a time through a file handle. The export of a year of records must not
//  hold a year of records.
//
//  See `docs/AUDIT_LOG.md`.

import BBCore
import Foundation

public enum AuditCSV {

  /// The columns, in order. Matches `audit_event`'s columns, which is what lets someone
  /// re-import an export into a table of the same shape.
  public static let columns = [
    "id", "uuid", "occurred_at", "category", "kind", "outcome", "severity", "actor_kind",
    "actor_id", "source", "request_id", "route", "subject_kind", "subject_id", "summary",
    "metadata",
  ]

  public static var header: String {
    columns.joined(separator: ",") + "\r\n"
  }

  /// One record as a line, CRLF included.
  public static func line(for event: AuditEvent) -> String {
    let metadata = String(
      decoding: (try? AuditJSON.encode(JSONValue.object(event.metadata))) ?? Data("{}".utf8),
      as: UTF8.self)
    let fields: [String] = [
      event.id.map(String.init) ?? "",
      event.uuid.uuidString.lowercased(),
      AuditTimestamp.string(from: event.occurredAt),
      event.category.rawValue,
      event.kind.rawValue,
      event.outcome.rawValue,
      event.severity.rawValue,
      event.actor.kind,
      event.actor.identifier ?? "",
      event.source.rawValue,
      event.requestID ?? "",
      event.route ?? "",
      event.subject?.kind ?? "",
      event.subject?.id ?? "",
      event.summary,
      metadata,
    ]
    return fields.map(escape).joined(separator: ",") + "\r\n"
  }

  /// A field as it goes between the commas.
  ///
  /// Quoted only when it has to be, so an export of plain identifiers opens the same in a
  /// spreadsheet and in a text editor. A field a spreadsheet would read as a formula is also
  /// quoted and prefixed with a single quote, which is the one defence a CSV has; the summary
  /// is written by this server, but the actor id is a client's address and the route is a
  /// client's choice.
  ///
  /// The triggers and the prefix are OWASP's. A leading tab or carriage return is a trigger
  /// because spreadsheets skip leading whitespace before deciding, which is also why the
  /// prefix is a quote and not the tab this used: `\t=cmd` is not neutral. Checked on the
  /// first SCALAR, because `\r\n` is one `Character` and a check on `first` cannot see it.
  public static func escape(_ field: String) -> String {
    var value = field
    if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
      value = "'" + value
    }
    let needsQuoting = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
    guard needsQuoting || value != field else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// What an export wrote, and what it could not.
public struct AuditExportSummary: Sendable, Equatable {
  /// Records written to the file.
  public let written: Int
  /// Matching rows this build could not read, and so left out. Said to the person and in the
  /// `audit.exported` record, because an export that silently omits rows misrepresents the
  /// log it is a copy of.
  public let unreadable: Int
}

/// Writes a filtered export to a file.
public struct AuditCSVExporter: Sendable {

  private let repository: AuditRepository

  public init(repository: AuditRepository) {
    self.repository = repository
  }

  /// Writes every record matching `query`, oldest first, to `url`, replacing what is there.
  public func export(
    matching query: AuditQuery = AuditQuery(), to url: URL
  ) async throws -> AuditExportSummary {
    try Data(AuditCSV.header.utf8).write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()

    var written = 0
    let unreadable = try await repository.forEachPage(matching: query) { page in
      var chunk = ""
      for event in page { chunk += AuditCSV.line(for: event) }
      try handle.write(contentsOf: Data(chunk.utf8))
      written += page.count
    }
    return AuditExportSummary(written: written, unreadable: unreadable)
  }
}

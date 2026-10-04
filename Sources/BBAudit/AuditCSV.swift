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
      decoding: (try? AuditJSON.encode(AuditValue.object(event.metadata))) ?? Data("{}".utf8),
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
  /// spreadsheet and in a text editor. A field starting with `=`, `+`, `-` or `@` is also
  /// quoted and prefixed with a tab, which is the one defence a CSV has against a cell that a
  /// spreadsheet would otherwise evaluate as a formula; the summary is written by this
  /// server, but the actor id is a client's address and the route is a client's choice.
  public static func escape(_ field: String) -> String {
    var value = field
    if let first = value.first, "=+-@".contains(first) {
      value = "\t" + value
    }
    let needsQuoting = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
    guard needsQuoting || value != field else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

/// Writes a filtered export to a file.
public struct AuditCSVExporter: Sendable {

  private let repository: AuditRepository

  public init(repository: AuditRepository) {
    self.repository = repository
  }

  /// Writes every record matching `query`, oldest first, to `url`, replacing what is there.
  /// Returns how many records were written.
  public func export(matching query: AuditQuery = AuditQuery(), to url: URL) async throws -> Int
  {
    try Data(AuditCSV.header.utf8).write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()

    var written = 0
    try await repository.forEachPage(matching: query) { page in
      var chunk = ""
      for event in page { chunk += AuditCSV.line(for: event) }
      try handle.write(contentsOf: Data(chunk.utf8))
      written += page.count
    }
    return written
  }
}

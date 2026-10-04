//  AuditCSVTests
//  The export opens in a spreadsheet and in a text editor, and nothing in it is a formula.
//
//  RFC 4180 is the easy half. The half worth pinning is the formula defence: an actor id is a
//  client's address and a route is a client's choice, so a field starting with `=` reaches
//  the spreadsheet of whoever opens the export, where it would be evaluated.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import BBPersistence
import Foundation
import Testing

@testable import BBAudit

@Suite("Audit CSV")
struct AuditCSVTests {

  @Test("A plain field is written as it is")
  func plainField() {
    #expect(AuditCSV.escape("auth.credential_rejected") == "auth.credential_rejected")
    #expect(AuditCSV.escape("") == "")
  }

  @Test("A field holding a comma, a quote or a line break is quoted, with quotes doubled")
  func quoting() {
    #expect(AuditCSV.escape("a,b") == "\"a,b\"")
    #expect(AuditCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    #expect(AuditCSV.escape("two\nlines") == "\"two\nlines\"")
    #expect(AuditCSV.escape("cr\rhere") == "\"cr\rhere\"")
  }

  @Test("A field a spreadsheet would evaluate is neutralised")
  func formulaDefence() {
    for lead in ["=SUM(A1)", "+1", "-1", "@cmd"] {
      let escaped = AuditCSV.escape(lead)
      #expect(escaped.hasPrefix("\"\t"), "\(lead) was not neutralised: \(escaped)")
      #expect(escaped.hasSuffix("\""))
    }
  }

  @Test("The header names the table's columns in the table's order")
  func header() {
    #expect(AuditCSV.header.hasSuffix("\r\n"))
    #expect(AuditCSV.columns.first == "id")
    #expect(AuditCSV.columns.last == "metadata")
    #expect(AuditCSV.columns.count == 16)
    #expect(AuditCSV.header.split(separator: ",").count == AuditCSV.columns.count)
  }

  @Test("A line has one field per column and ends in CRLF")
  func line() {
    let event = AuditEvent(
      kind: .clientBlocked, outcome: .success, actor: .system(component: "access-control"),
      subject: .client("203.0.113.9"), summary: "203.0.113.9 was blocked, twice.",
      metadata: ["failure_count": .int(3)], id: 7)
    let line = AuditCSV.line(for: event)
    #expect(line.hasSuffix("\r\n"))
    #expect(line.hasPrefix("7,"))
    #expect(line.contains("\"203.0.113.9 was blocked, twice.\""))
    #expect(line.contains("\"{\"\"failure_count\"\":3}\""))
    #expect(line.contains(",access_control,access_control.client_blocked,success,"))
  }

  @Test("An export writes the header and every matching record, oldest first")
  func export() async throws {
    let repository = AuditRepository(
      database: try AppDatabase.inMemory(contributors: [AuditSchema.self]))
    _ = try await repository.insert(
      (1...3).map {
        AuditEvent(
          kind: .apiRequest, summary: "request \($0)",
          occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
      })
    let url = FileManager.default.temporaryDirectory
      .appending(path: "audit-export-\(UUID().uuidString).csv")
    defer { try? FileManager.default.removeItem(at: url) }

    let written = try await AuditCSVExporter(repository: repository).export(to: url)
    #expect(written == 3)

    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\r\n")
    #expect(lines.count == 4)
    #expect(String(lines[0]) + "\r\n" == AuditCSV.header)
    #expect(lines[1].contains("request 1"))
    #expect(lines[3].contains("request 3"))
  }
}

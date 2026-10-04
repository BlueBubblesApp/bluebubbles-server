//  AuditDocumentationTests
//  Every event kind and every metadata field the server can write is in `docs/AUDIT_LOG.md`.
//
//  The documentation is the contract a SIEM rule or a Postgres query is written against, and
//  a kind that exists in code and not in the document is a record somebody receives and
//  cannot look up. `AuditEventKind.metadataFields` is the one declaration of what a kind
//  carries; this reads the document and refuses a kind, a field, a category, a subject kind
//  or a CSV column it does not name.

import Foundation
import Testing

@testable import BBAudit

@Suite("Audit log documentation")
struct AuditDocumentationTests {

  private static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func document() throws -> String {
    try String(contentsOf: root.appending(path: "docs/AUDIT_LOG.md"), encoding: .utf8)
  }

  @Test("Every event kind is documented, with every metadata field it declares")
  func everyKindIsDocumented() throws {
    let text = try Self.document()
    var missing: [String] = []
    for kind in AuditEventKind.allCases {
      guard let range = text.range(of: "`\(kind.rawValue)`") else {
        missing.append(kind.rawValue)
        continue
      }
      // The field is named somewhere AFTER the kind's heading, which is where its table is.
      let after = text[range.upperBound...]
      for field in kind.metadataFields where !after.contains("`\(field.name)`") {
        missing.append("\(kind.rawValue).\(field.name)")
      }
    }
    #expect(
      missing.isEmpty,
      Comment(rawValue: "docs/AUDIT_LOG.md does not describe: " + missing.joined(separator: ", ")))
  }

  @Test("Every category, outcome, severity, source and actor kind is documented")
  func everyEnumerationIsDocumented() throws {
    let text = try Self.document()
    var missing: [String] = []
    for category in AuditCategory.allCases where !text.contains("`\(category.rawValue)`") {
      missing.append("category \(category.rawValue)")
    }
    for outcome in AuditOutcome.allCases where !text.contains("`\(outcome.rawValue)`") {
      missing.append("outcome \(outcome.rawValue)")
    }
    for severity in AuditSeverity.allCases where !text.contains("`\(severity.rawValue)`") {
      missing.append("severity \(severity.rawValue)")
    }
    for source in AuditSource.allCases where !text.contains("`\(source.rawValue)`") {
      missing.append("source \(source.rawValue)")
    }
    for actor in ["client", "operator", "system"] where !text.contains("`\(actor)`") {
      missing.append("actor kind \(actor)")
    }
    #expect(missing.isEmpty, Comment(rawValue: "undocumented: " + missing.joined(separator: ", ")))
  }

  @Test("Every subject kind the server writes is documented")
  func subjectKinds() throws {
    let text = try Self.document()
    let subjects = [
      AuditSubject.setting("k"), .service("s"), .client("c"), .route("r"), .webhook(1),
      .scheduledMessage(1), .allowlistEntry("a"),
    ]
    for subject in subjects {
      #expect(text.contains("`\(subject.kind)`"), "subject kind \(subject.kind) is undocumented")
    }
  }

  @Test("Every CSV column and every envelope key is documented")
  func columnsAndKeys() throws {
    let text = try Self.document()
    for column in AuditCSV.columns {
      #expect(text.contains("`\(column)`"), "CSV column \(column) is undocumented")
    }
    let keys = AuditEvent(kind: .recordingStarted, summary: "x").document(hostname: "h").keys
    for key in keys {
      #expect(text.contains("`\(key)`"), "envelope key \(key) is undocumented")
    }
    #expect(text.contains("`schema_version`"))
    #expect(text.contains(String(AuditEvent.schemaVersion)))
  }

  @Test("The syslog layout the document describes is the one the code writes")
  func syslogLayout() throws {
    let text = try Self.document()
    #expect(text.contains(SyslogMessage.appName))
    #expect(text.contains("RFC 5424"))
    #expect(text.contains("\(SyslogTransportKind.tls.defaultPort)"))
    #expect(text.contains("\(SyslogTransportKind.tcp.defaultPort)"))
    #expect(text.contains("\(AuditRetentionPolicy.defaultDays)"))
  }
}

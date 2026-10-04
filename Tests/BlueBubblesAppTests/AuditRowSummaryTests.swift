//  AuditRowSummaryTests
//  What the Audit Log page says about a record, asserted without a view.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAudit
import BBCore
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Audit row summary")
struct AuditRowSummaryTests {

  @Test("The actor column names who, and never leaves a blank cell")
  func actor() {
    #expect(AuditRowSummary.actor(.client(address: "203.0.113.9")) == "Client 203.0.113.9")
    #expect(AuditRowSummary.actor(.client(address: nil)) == "Unidentified client")
    #expect(AuditRowSummary.actor(.operator) == "Operator")
    #expect(AuditRowSummary.actor(.system(component: "startup")) == "Server (startup)")
  }

  @Test("Only a failure or a refusal gets a colour")
  func tone() {
    #expect(AuditRowSummary.tone(.success) == .neutral)
    #expect(AuditRowSummary.tone(.failure) == .failed)
    #expect(AuditRowSummary.tone(.denied) == .denied)
    #expect(AuditRowSummary.outcome(.success) == "OK")
    #expect(AuditRowSummary.outcome(.denied) == "Denied")
  }

  @Test("A timestamp within a day is relative; older is a date")
  func when() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(AuditRowSummary.isRecent(now.addingTimeInterval(-60), now: now))
    #expect(!AuditRowSummary.isRecent(now.addingTimeInterval(-2 * 24 * 3600), now: now))
    // A clock that has gone backwards puts a record in the future; that is not "recent".
    #expect(!AuditRowSummary.isRecent(now.addingTimeInterval(60), now: now))
    #expect(AuditRowSummary.exactTime(now) == "2023-11-14T22:13:20.000Z")
    #expect(!AuditRowSummary.when(now.addingTimeInterval(-3 * 24 * 3600), now: now).isEmpty)
  }

  @Test("The subject reads as a kind and an identifier, or nothing")
  func subject() {
    #expect(AuditRowSummary.subject(.setting("socket_port")) == "setting socket_port")
    #expect(AuditRowSummary.subject(.scheduledMessage(4)) == "scheduled message 4")
    #expect(AuditRowSummary.subject(nil) == "")
  }

  @Test("The metadata is shown as the sorted, pretty JSON a receiver holds")
  func metadataJSON() {
    let json = AuditRowSummary.metadataJSON(["status": .int(200), "handler": .string("h")])
    #expect(json.hasPrefix("{\n"))
    #expect(json.contains("\"handler\" : \"h\"") || json.contains("\"handler\": \"h\""))
    let handler = json.range(of: "handler")?.lowerBound
    let status = json.range(of: "status")?.lowerBound
    #expect(handler != nil && status != nil && handler! < status!, "keys are sorted")
    let empty = AuditRowSummary.metadataJSON([:])
    #expect(empty == "{\n\n}" || empty == "{}")
  }

  @Test("The export file is named for the product and the day")
  func exportFileName() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let name = AuditRowSummary.exportFileName(
      now: Date(timeIntervalSince1970: 1_700_000_000), calendar: calendar)
    #expect(name == "bluebubbles-audit-2023-11-14.csv")
  }
}

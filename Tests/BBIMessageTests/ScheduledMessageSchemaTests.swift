//  ScheduledMessageSchemaTests
//  Send Later is a Sequoia feature, and a Sonoma Mac has to be told so.
//
//  `schedule_type` and `schedule_state` were added in macOS 15 and the deployment floor is
//  macOS 14, where `GET /api/v2/message/send-later` hit SQLite's "no such column:
//  m.schedule_type" and answered 500. That reads as a broken server rather than as a feature
//  this Mac does not have, and it is the one route in the group with no gate: the write side
//  already refuses on the OS version.
//
//  `SchemaProfile.supportsScheduledMessages` existed for precisely this check and had no
//  caller anywhere in the tree, which is the shape this audit kept finding: a guard that was
//  written, tested, and never wired to the thing it guards.

import BBPersistence
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Scheduled message schema gate")
struct ScheduledMessageSchemaTests {

  /// A `chat.db` with the columns of one macOS release or the other.
  private func repository(withScheduleColumns: Bool) throws -> MessageRepository {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("schedule-schema-\(UUID().uuidString).sqlite").path
    let queue = try DatabaseQueue(path: path)
    let scheduleColumns =
      withScheduleColumns ? ", schedule_type INTEGER, schedule_state INTEGER" : ""
    try queue.write { db in
      try db.execute(
        sql: "CREATE TABLE message "
          + "(ROWID INTEGER PRIMARY KEY, guid TEXT, date INTEGER\(scheduleColumns))"
      )
    }

    var columns: Set<String> = ["ROWID", "guid", "date"]
    if withScheduleColumns { columns.formUnion(["schedule_type", "schedule_state"]) }
    let profile = SchemaProfile(
      tables: ["message"], messageColumns: columns, chatColumns: [], handleColumns: [],
      attachmentColumns: [], dateUnit: .nanoseconds
    )
    return MessageRepository(database: try ReadOnlyDatabase(path: path), profile: profile)
  }

  @Test("Sonoma's schema reports the feature as unsupported")
  func sonomaReportsUnsupported() throws {
    // The capability, which is what the interface layer refuses on. Before this it was
    // never read, so the query ran and failed inside SQLite instead.
    #expect(try repository(withScheduleColumns: false).supportsScheduledMessages == false)
  }

  @Test("Sequoia's schema reports it as supported")
  func sequoiaReportsSupported() throws {
    #expect(try repository(withScheduleColumns: true).supportsScheduledMessages == true)
  }

  @Test("The query runs where the columns exist")
  func queryRunsOnSequoia() async throws {
    // The other half: the gate must not refuse a Mac that CAN do this. An empty result is
    // the right answer for a database with no scheduled rows.
    let rows = try await repository(withScheduleColumns: true).pendingScheduledMessages()
    #expect(rows.isEmpty)
  }
}

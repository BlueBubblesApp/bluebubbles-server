//  RowLiteralTests
//  The two values a chat.db row invents when a column is NULL, and the premise of each.
//
//  A fallback literal in a row type reaches the wire with the right key and the right type,
//  so the parity diff cannot see it. These pin the value, and for `handle.service` the
//  reason the value is unreachable: Apple's schema forbids the NULL that would select it.

import BBCore
import BBPersistence
import BBSerialization
import BBTestCore
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Row fallback literals")
struct RowLiteralTests {

  /// `docs/database/samples`, found from this file rather than the working directory.
  private static let samples = Repository.url("docs/database/samples")

  @Test("A NULL chat style is a direct chat, and is serialized as 45")
  func nullStyleIsDirect() throws {
    let chat = try Row([
      "ROWID": 3, "guid": "iMessage;-;+12025550143", "style": nil as Int?,
      "chat_identifier": "+12025550143",
    ]).mapped(in: .chatDatabase) { try ChatRow($0, dateUnit: .nanoseconds) }
    #expect(chat.style == 45)
    #expect(!chat.isGroup)
    #expect(ChatSerializer.serialize(chat)["style"] == .int(45))
  }

  @Test("A NULL handle service reads as iMessage")
  func nullServiceIsIMessage() throws {
    let handle = try Row([
      "ROWID": 7, "id": "+12025550143", "service": nil as String?,
    ]).mapped(in: .chatDatabase) { try HandleRow($0) }
    #expect(handle.service == "iMessage")
  }

  /// The premise that makes the `service` fallback dead code on a real database. If a
  /// release relaxes the constraint, this fails and the fallback becomes a wire value that
  /// needs deciding.
  @Test("Every sampled schema declares handle.service NOT NULL")
  func serviceIsNotNullInEverySample() throws {
    let releases = try FileManager.default.contentsOfDirectory(
      at: Self.samples, includingPropertiesForKeys: nil)
    var checked = 0
    for release in releases {
      // Not every release's sample set has a handle table; those have nothing to check.
      let file = release.appendingPathComponent("handle.sql")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let sql = try String(contentsOf: file, encoding: .utf8)
      checked += 1
      #expect(
        sql.range(of: #"service\s+TEXT\s+NOT NULL"#, options: .regularExpression) != nil,
        "\(release.lastPathComponent)/handle.sql")
    }
    #expect(checked >= 5, "found \(checked) sampled handle schemas")
  }
}

//  ChatLastReadTimestampTests
//  What `lastReadMessageTimestamp` carries on a chat, as a VALUE.
//
//  The parity diff compares keys and types, so a raw Apple timestamp would pass it: a number
//  either way. Clients compare this with the epoch milliseconds on every other date field.

import BBCore
import BBIMessage
import BBSerialization
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("A chat's last read timestamp")
struct ChatLastReadTimestampTests {

  private func chat(
    lastRead: Int64?, unit: AppleTimestamp.Unit = .nanoseconds, hasColumn: Bool = true
  ) throws -> ChatRow {
    var columns: [String: (any DatabaseValueConvertible)?] = [
      "ROWID": 3, "guid": "iMessage;-;+12025550143", "style": 45,
    ]
    if hasColumn { columns["last_read_message_timestamp"] = lastRead }
    return try Row(columns).mapped(in: .chatDatabase) { try ChatRow($0, dateUnit: unit) }
  }

  /// 2026-11-02T00:00:00Z, the same instant in both units a `chat.db` stores dates in.
  private static let epochMilliseconds: Int64 = 1_793_577_600_000
  private static let secondsSince2001: Int64 = 815_270_400

  @Test(
    "It goes out as epoch milliseconds, whichever unit the database stores",
    arguments: [
      (secondsSince2001 * 1_000_000_000, AppleTimestamp.Unit.nanoseconds),
      (secondsSince2001, .seconds),
    ])
  func convertedToEpochMilliseconds(raw: Int64, unit: AppleTimestamp.Unit) throws {
    let output = ChatSerializer.serialize(try chat(lastRead: raw, unit: unit))
    #expect(output["lastReadMessageTimestamp"] == .int64(Self.epochMilliseconds))
  }

  /// Zero is "never" in this schema, and read as a date it is a chat read in 2001. A schema
  /// without the column still has the key, so a client has one shape to read.
  @Test("A chat never read, or a schema without the column, sends null")
  func neverReadIsNull() throws {
    for row in [
      try chat(lastRead: 0), try chat(lastRead: nil), try chat(lastRead: nil, hasColumn: false),
    ] {
      #expect(ChatSerializer.serialize(row)["lastReadMessageTimestamp"] == .null)
    }
  }

  /// An extra field can push a notification over `FCMSender.maximumPayloadBytes`, and the sender
  /// then sheds the chat roster to fit.
  @Test("It stays off the notification payload")
  func notOnNotifications() throws {
    let output = ChatSerializer.serialize(
      try chat(lastRead: Self.secondsSince2001 * 1_000_000_000), isForNotification: true)
    #expect(output["lastReadMessageTimestamp"] == nil)
  }
}

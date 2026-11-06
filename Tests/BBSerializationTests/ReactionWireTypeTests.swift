//  ReactionWireTypeTests
//  What `associatedMessageType` carries for each association id, as a VALUE.
//
//  The parity diff compares keys and types, and every entry below is a string or a null either
//  way, so it would pass a map with two names swapped. Clients branch on this string to draw a
//  tapback, so the values are the contract: the reference's message-type transformer, which
//  answers the digits for any id outside its table.
//
//  Through the shipping serializer on both projections, because the push payload is where a
//  field being dropped would cost a notification its text.

import BBCore
import BBIMessage
import BBSerialization
import Foundation
import GRDB
import Testing

@Suite("Reaction wire values")
struct ReactionWireTypeTests {

  static let expected: [(id: Int, wire: String?)] = [
    (0, nil),
    (2, "2"), (3, "3"),
    (1000, "sticker"),
    (2000, "love"), (2001, "like"), (2002, "dislike"),
    (2003, "laugh"), (2004, "emphasize"), (2005, "question"),
    (2006, "2006"), (2007, "2007"),
    (3000, "-love"), (3001, "-like"), (3002, "-dislike"),
    (3003, "-laugh"), (3004, "-emphasize"), (3005, "-question"),
    (3006, "3006"), (3007, "3007"),
    (4000, "4000"),
  ]

  @Test("Every id serialises to the reference's value on both projections")
  func values() throws {
    let serializer = MessageSerializer(
      profile: .baseline(
        messageColumns: Set(Rows.messageColumns().keys).union(["associated_message_emoji"])))
    for (id, wire) in Self.expected {
      var columns = Rows.messageColumns()
      columns["associated_message_type"] = id
      columns["associated_message_guid"] = id == 0 ? nil : "p:0/ABC"
      let isEmojiTapback = id == 2006 || id == 3006
      columns["associated_message_emoji"] = isEmojiTapback ? "🔥" : nil
      let row = try Rows.message(columns)

      let full = serializer.serialize(row, context: .init(), config: .full)
      let push = serializer.serialize(
        row, context: .init(), config: .notification, isForNotification: true)
      let expectedType: JSONValue = wire.map { .string($0) } ?? .null
      for output in [full, push] {
        #expect(output["associatedMessageType"] == expectedType, "id \(id)")
        #expect(
          output["associatedMessageEmoji"] == (isEmojiTapback ? .string("🔥") : nil), "id \(id)")
      }
    }
  }
}

//  RequestedRelationsTests
//  `with`, parsed once, in both of the shapes it arrives in.
//
//  The reference's `parseWithQuery` (`api/http/api/v1/utils.ts`) takes a comma-separated
//  string or an array, trims and lowercases each entry and drops empties. The spellings of
//  the message relations, two per blob column, are asserted here so that every route reading
//  them reads the same set.

import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Requested relations")
struct RequestedRelationsTests {

  @Test("An array, a comma-separated string and a query string parse alike")
  func shapesAgree() {
    let array = RequestedRelations(.array([.string(" Chat "), .string(""), .int(3)]))
    let string = RequestedRelations(.string(" Chat ,,"))
    let query = RequestedRelations(commaSeparated: " Chat ,,")
    #expect(array.names == ["chat"])
    #expect(string == array)
    #expect(query == array)
  }

  @Test("Nothing asked for is empty, whatever the shape of nothing")
  func nothing() {
    #expect(RequestedRelations(nil).isEmpty)
    #expect(RequestedRelations(.null).isEmpty)
    #expect(RequestedRelations(.object([:])).isEmpty)
    #expect(RequestedRelations(commaSeparated: nil).isEmpty)
    #expect(RequestedRelations(commaSeparated: "").isEmpty)
  }

  @Test("Both spellings of each blob column, prefixed or not")
  func blobSpellings() {
    for spelling in ["attributedBody", "attributed-body", "message.attributedBody"] {
      #expect(RequestedRelations([spelling]).attributedBody, "\(spelling)")
    }
    for spelling in ["messageSummaryInfo", "message-summary-info", "message.messageSummaryInfo"] {
      #expect(RequestedRelations([spelling]).messageSummaryInfo, "\(spelling)")
    }
    for spelling in ["payloadData", "payload-data", "message.payloadData"] {
      #expect(RequestedRelations([spelling]).payloadData, "\(spelling)")
    }
    for spelling in ["attachment.metadata", "attachments.metadata"] {
      #expect(RequestedRelations([spelling]).attachmentMetadata, "\(spelling)")
    }
    #expect(!RequestedRelations(["attachment"]).attachmentMetadata)
  }

  /// Substring, not the reference's exact membership: `chat.participants` turns `chats` on.
  /// Deliberate; see the type's header.
  @Test("Matching is by substring")
  func substring() {
    let relations = RequestedRelations(["chat.participants"])
    #expect(relations.chats)
    #expect(relations.chatParticipants)
    #expect(!relations.attachments)
  }

  /// The body route is asserted directly: the parser takes a string `with` as
  /// `parseWithQuery` does. (The v1 validator still refuses a non-empty string on
  /// `POST /message/query` before it gets here, as `messageValidator.ts` declares
  /// `with: "array"`.)
  @Test("message/query reads the relations through the shared parser")
  func messageQueryUsesIt() throws {
    let query = try MessageInterface.Query.parse(
      .object(["with": .string("chat, attachment, attributed-body, attachments.metadata")]))
    #expect(query.withChats)
    #expect(query.withAttachments)
    #expect(query.withAttributedBody)
    #expect(query.withAttachmentMetadata)
    #expect(!query.withPayloadData)
  }
}

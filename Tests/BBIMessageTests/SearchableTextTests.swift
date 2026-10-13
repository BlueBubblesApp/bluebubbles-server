//  SearchableTextTests
//  The search index reads a message's words by the rule the wire `text` uses.
//
//  The indexer resolved them itself: `text` untrimmed and with its attachment placeholders,
//  or the decoder's raw `string` rather than `cleanText`. So a message's `text` in a response
//  and its words in the index were two different answers to one question, and a row whose
//  body would not decode vanished from the index with nothing logged.

import BBPersistence
import BBTestSupport
import Foundation
import GRDB
import Testing

@testable import BBIMessage

@Suite("Searchable text", .removingChatDBCopies)
struct SearchableTextTests {

  @Test("The index gets the words the wire gets: cleaned and trimmed")
  func indexMatchesTheWire() async throws {
    let path = try CommittedChatDB.copy(.sequoia)

    let placeholder = "\u{FFFC}"
    let writer = try DatabaseQueue(path: path.path)
    let (padded, onlyPlaceholder): (Int64, Int64) = try await writer.write { db in
      let ids = try Int64.fetchAll(db, sql: "SELECT ROWID FROM message ORDER BY ROWID LIMIT 2")
      try db.execute(
        sql: "UPDATE message SET text = ? WHERE ROWID = ?",
        arguments: ["  BB test words \(placeholder) \n", ids[0]])
      try db.execute(
        sql: "UPDATE message SET text = ?, attributedBody = NULL WHERE ROWID = ?",
        arguments: [placeholder, ids[1]])
      return (ids[0], ids[1])
    }

    let database = try ReadOnlyDatabase(path: path.path)
    let profile = try await SchemaProfile.detect(in: database, osMajorVersion: 15)
    let repository = MessageRepository(database: database, profile: profile)

    let rows = try await repository.searchableText(rowIDs: [padded, onlyPlaceholder])
    let byRow = Dictionary(uniqueKeysWithValues: rows.map { ($0.rowID, $0.text) })
    #expect(byRow[padded] == "BB test words")
    // An attachment with no caption says nothing, in the index as on the wire.
    #expect(byRow[onlyPlaceholder] == nil)

    // And it is the wire's answer, not merely a similar one.
    let wire = IMessageRow.universalText(
      text: "  BB test words \(placeholder) \n", attributedBody: nil, logMetadata: [:])
    #expect(byRow[padded] == wire)
  }
}

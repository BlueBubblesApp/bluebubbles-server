//  QueryExampleTests
//  The documented `POST /message/query` samples are requests this server accepts.
//
//  `RequestBodyTests` checks an example's SHAPE: an object, no undeclared key, nothing
//  required left out. That is all it can check from inside BBOpenAPI, and for a body whose
//  interesting field is SQL text it is not enough. `where` is an allowlist of eight
//  statements matched on shape, anything else is a 400, and the statements in the document
//  are hand-typed: a stray `ROWID >= :x` would read perfectly, pass every shape check, and
//  hand a client author a request the server refuses.
//
//  So these run each documented example through the parser the handler itself calls. That is
//  why this target reaches BBInterfaces at all, and the reach is deliberately one-way: the
//  document is checked against the server, never the other way round.
//
//  The project's own rule, from the `POST message/app` example that sent the one balloon that
//  route refuses: an example the server rejects is worse than no example, and vigilance is
//  not a mechanism.

import BBCore
import BBHTTPAPI
import BBInterfaces
import BBSerialization
import Testing

@testable import BBOpenAPI

@Suite("Query examples")
struct QueryExampleTests {

  /// `OrderedJSON` as the wire type the handler parses.
  ///
  /// The document is ordered because it is committed and diffed; a request body is not. The
  /// conversion is here rather than on either type because nothing but a test needs it.
  private func wire(_ value: OrderedJSON) -> JSONValue {
    switch value {
    case .null: .null
    case .bool(let flag): .bool(flag)
    case .int(let number): .int(number)
    case .double(let number): .double(number)
    case .string(let text): .string(text)
    case .array(let values): .array(values.map(wire))
    case .object(let members):
      .object(Dictionary(uniqueKeysWithValues: members.map { ($0.key, wire($0.value)) }))
    }
  }

  private var examples: [RequestBodies.Example] {
    RequestBodies.byHandler[.messageQuery]?.examples ?? []
  }

  @Test("Every documented example parses")
  func examplesParse() throws {
    #expect(!examples.isEmpty, "POST message/query documents no example")
    for example in examples {
      #expect(
        throws: Never.self,
        "the `\(example.name)` example is a request this server would refuse"
      ) {
        try MessageInterface.Query.parse(wire(example.value))
      }
    }
  }

  @Test("Every example's `where` reaches the filters it means to")
  func filtersAreUnderstood() throws {
    // Parsing is not enough on its own: `filters` is built from `where`, so an example whose
    // clauses all parsed and produced nothing would mean the document is demonstrating a
    // filter that does not filter. Each named sample says which filters it is for.
    let expected: [String: Int] = [
      "recent-in-chat": 0,
      "incremental-sync": 2,
      "search-one-chat": 3,
      "sent-by-me-to-one-handle": 2,
      "hydrate-by-guid": 1,
    ]
    #expect(
      Set(expected.keys) == Set(examples.map(\.name)),
      "the example names changed; this table names them one by one on purpose")
    for example in examples {
      let query = try MessageInterface.Query.parse(wire(example.value))
      #expect(
        query.filters.count == expected[example.name],
        "the `\(example.name)` example produced \(query.filters.count) filters")
    }
  }

  @Test("Between them the examples demonstrate every statement the server accepts")
  func everyStatementIsDemonstrated() throws {
    // The point of documenting `where` at all. A ninth statement added to `MessageFilter`
    // with no sample here is a filter a client author cannot discover, which is the state
    // this whole exercise started from.
    var seen: Set<String> = []
    for example in examples {
      for filter in try MessageInterface.Query.parse(wire(example.value)).filters {
        switch filter {
        case .rowIDGreaterThan: seen.insert("rowIDGreaterThan")
        case .rowIDAtMost: seen.insert("rowIDAtMost")
        case .isFromMe: seen.insert("isFromMe")
        case .textLike: seen.insert("textLike")
        case .guidIn: seen.insert("guidIn")
        case .notAssociated: seen.insert("notAssociated")
        case .chatGUID: seen.insert("chatGUID")
        case .handleAddress: seen.insert("handleAddress")
        }
      }
    }
    let all: Set<String> = [
      "rowIDGreaterThan", "rowIDAtMost", "isFromMe", "textLike", "guidIn", "notAssociated",
      "chatGUID", "handleAddress",
    ]
    let missing = all.subtracting(seen).sorted().joined(separator: ", ")
    #expect(missing.isEmpty, "no documented example demonstrates \(missing)")
  }

  @Test("Every relation the examples name is one the server loads")
  func relationsAreHonoured() throws {
    // A `with` entry is matched as a substring, so a misspelling is not an error: it simply
    // selects nothing, silently, and the example teaches a client to ask for a relation it
    // will never receive. Asserting on the parsed FLAGS is what catches that.
    let recent = try #require(examples.first { $0.name == "recent-in-chat" })
    let query = try MessageInterface.Query.parse(wire(recent.value))
    #expect(query.withChats)
    #expect(query.withChatParticipants)
    #expect(query.withAttachments)
    #expect(query.withAttributedBody)
    #expect(query.withMessageSummaryInfo)

    // And the documented relation list is not just the ones this example happens to use:
    // each name in the property's description selects something.
    let described = try #require(
      RequestBodies.byHandler[.messageQuery]?.properties.first { $0.name == "with" }?.description)
    for relation in [
      "chat", "chat.participants", "attachment", "attachment.metadata", "attributedBody",
      "messageSummaryInfo", "payloadData",
    ] {
      #expect(described.contains("`\(relation)`"), "the `with` description omits \(relation)")
      let single = try MessageInterface.Query.parse(.object(["with": .array([.string(relation)])]))
      let selected =
        single.withChats || single.withAttachments || single.withChatParticipants
        || single.withAttributedBody || single.withMessageSummaryInfo || single.withPayloadData
        || single.withAttachmentMetadata
      #expect(selected, "`with: [\"\(relation)\"]` selects no relation")
    }
  }
}

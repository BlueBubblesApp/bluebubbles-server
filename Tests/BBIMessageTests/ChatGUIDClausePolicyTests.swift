//  ChatGUIDClausePolicyTests
//  A chat GUID is matched in SQL in exactly one place.
//
//  Rule 3 in the root CLAUDE.md: chat GUIDs are not comparable, so a query never writes
//  `c.guid = ?`. The candidate clause that replaces it was hand-built five times, and one copy
//  fell back to `c.guid = ?` for a GUID `ChatGUID` could not parse. That is the shape a rule
//  in prose cannot hold: every copy looked right until the branch nobody exercised.
//
//  `MessageQueryPlan.chatCondition(_:alias:)` is the producer, and it interpolates the alias,
//  so no source line spells a chat alias next to a GUID comparison. Any line that does is a
//  second producer. The aliases are the two this module joins `chat` as; `chat.guid = ?` in
//  `MessageFilter` is the client's own statement text being parsed, not SQL we run.

import BBTestSupport
import Testing

@testable import BBIMessage

@Suite("Chat GUID clauses have one producer")
struct ChatGUIDClausePolicyTests {

  @Test("No source compares a chat alias's guid except through chatCondition")
  func oneProducer() throws {
    let pattern = try Regex(#"\b(c|cF)\.guid\s*(=|IN\b)"#)
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 101)
    let offences = SourceScanner.offences(in: files) { _, line in line.code.contains(pattern) }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue:
          "a chat GUID clause built by hand; use MessageQueryPlan.chatCondition(_:alias:):\n"
          + offences.report)
    )
  }

  @Test("An unparsable GUID is still matched as a candidate list, never with =")
  func unparsableGUIDUsesTheList() {
    let clause = MessageQueryPlan.chatCondition("not a chat guid")
    #expect(clause.condition == "c.guid IN (?)")
    #expect(clause.arguments.count == 1)
    #expect(MessageQueryPlan.chatCondition("x", alias: "cF").condition.hasPrefix("cF.guid IN"))
  }
}

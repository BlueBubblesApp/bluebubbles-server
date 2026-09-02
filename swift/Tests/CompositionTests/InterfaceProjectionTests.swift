//  InterfaceProjectionTests
//  The interfaces layer returns values; one `serialize` step projects each onto the wire.
//
//  These pin the projections that used to be built inline inside the interface methods and
//  therefore had no test of their own. Every key here is v1 surface a client reads, so a
//  rename is a client break and the assertions are on exact key sets.

import BBContacts
import BBDiagnostics
import BBSerialization
import Foundation
import Testing

@testable import BBInterfaces

@Suite("Interface projections")
struct InterfaceProjectionTests {

  @Test("Statistics totals project to the four counts")
  func totals() {
    let json = AdminInterface.serialize(
      AdminInterface.Totals(handles: 1, messages: 2, chats: 3, attachments: 4)
    )
    #expect(json.objectKeys == ["handles", "messages", "chats", "attachments"])
    #expect(json["messages"]?.intValue == 2)
  }

  @Test("Chat counts carry the sum and the per-service breakdown")
  func chatCounts() {
    let counts = ChatInterface.ChatCounts(breakdown: ["iMessage": 480, "SMS": 1])
    #expect(counts.total == 481)

    let json = ChatInterface.serialize(counts)
    #expect(json.objectKeys == ["total", "breakdown"])
    #expect(json["breakdown"]?["iMessage"]?.intValue == 480)
  }

  /// A send whose row never appeared answers with what it has, and never fails.
  ///
  /// This used to be the ONLY shape a send produced — identifiers, plus a `backend` key the
  /// reference does not send. It is now the fallback for a hydration that timed out, and it
  /// stays 200 on purpose: the send reached Messages, and reporting a failure would invite
  /// the client to send the message twice. `SendHydrationTests` covers the shape that
  /// matters, which is the message itself.
  @Test("A send whose row never arrived falls back to the identifiers")
  func sendOutcomeFallback() throws {
    let interface = MessageInterface(
      repository: try InterfaceFixtures.repository(), serializer: InterfaceFixtures.serializer
    )

    let privateAPI = interface.serialize(
      MessageInterface.SendOutcome(backend: .privateAPI, messageGUID: "MSG-1"),
      tempGUID: "TEMP-1"
    )
    #expect(privateAPI.objectKeys == ["guid", "tempGuid"])
    // No `backend`, on any send route. It named which path ran, nothing ever read it, and
    // the comment justifying it claimed clients did — which they cannot have, since the
    // reference has never sent it. `SendOutcome.backend` still records it off the wire.
    #expect(privateAPI["backend"] == nil)

    let appleScript = interface.serialize(
      MessageInterface.SendOutcome(backend: .appleScript, chatGUID: "iMessage;-;chat1")
    )
    #expect(appleScript.objectKeys == ["chatGuid"])
  }

  @Test("A contacts re-index reports what it did, in milliseconds")
  func reindexResult() {
    let json = ContactInterface.serialize(
      ContactsIngestResult(indexed: 412, skipped: 3, duration: .seconds(2))
    )
    #expect(json.objectKeys == ["indexed", "skipped", "durationMs"])
    #expect(json["durationMs"]?.intValue == 2000)
  }

  @Test("Merging keys into a JSON object leaves non-objects untouched")
  func merging() {
    #expect(
      JSONValue.object(["a": .int(1)]).merging(["b": .int(2)]).objectKeys == ["a", "b"]
    )
    #expect(JSONValue.string("x").merging(["b": .int(2)]) == .string("x"))
  }
}

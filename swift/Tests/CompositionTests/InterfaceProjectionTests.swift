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

  @Test("A Private API send reports the message GUID; an AppleScript send the chat")
  func sendOutcomeKeys() {
    let privateAPI = MessageInterface.serialize(
      MessageInterface.SendOutcome(backend: .privateAPI, messageGUID: "MSG-1"),
      includingBackend: true
    )
    #expect(privateAPI.objectKeys == ["guid", "backend"])
    #expect(privateAPI["backend"]?.stringValue == "private-api")

    let appleScript = MessageInterface.serialize(
      MessageInterface.SendOutcome(backend: .appleScript, chatGUID: "iMessage;-;chat1"),
      includingBackend: true
    )
    #expect(appleScript.objectKeys == ["chatGuid", "backend"])
  }

  @Test("The attachment and multipart routes never name the backend")
  func sendOutcomeWithoutBackend() {
    let json = MessageInterface.serialize(
      MessageInterface.SendOutcome(backend: .privateAPI, messageGUID: "MSG-1"),
      includingBackend: false
    )
    #expect(json.objectKeys == ["guid"])
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

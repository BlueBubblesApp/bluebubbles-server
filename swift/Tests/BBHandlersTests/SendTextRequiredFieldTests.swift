//  SendTextRequiredFieldTests
//  What `POST /api/v1/message/text` requires, and what it deliberately does not.
//
//  The rule is the reference's, in two halves that are easy to collapse into one and wrong
//  if you do. `message: "present|string"` (`validators/messageValidator.ts:74`) means the KEY
//  must exist and an empty string satisfies it. Whether the text may be empty is then decided
//  by the backend (`:104-116`): AppleScript needs text because it has nothing else to send,
//  and the Private API needs text OR a subject because either one carries the message.
//
//  This server required a non-empty `message` unconditionally, which made a subject-only send
//  a 400 where the reference answers 200. That is a break against shipped clients, which is
//  the one direction the compatibility rule does not tolerate, so both halves are pinned here.

import BBHTTPAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("Send text required fields")
struct SendTextRequiredFieldTests {

  /// Mirrors the handler's own resolution so the rule can be tested without a send path,
  /// an interface, or Messages. The handler is the code under test; this is the shape of
  /// the decision it makes, and `SendShapeTests` covers that the handler still makes it.
  private func validate(_ body: [String: JSONValue]) throws {
    let values = RequestValues(.object(body))
    _ = try values.requireString("chatGuid")
    guard let message = values["message"]?.stringValue else {
      throw BadRequest(RequestValues.missing("message"))
    }
    let subject = values["subject"]?.stringValue
    let impliesPrivateAPI =
      subject != nil || body["effectId"] != nil || body["selectedMessageGuid"] != nil
      || body["ddScan"] != nil || body["attributedBody"] != nil
      || body["textFormatting"] != nil
    let forcedPrivateAPI = values["method"]?.stringValue?.lowercased().contains("private") == true

    if impliesPrivateAPI || forcedPrivateAPI {
      guard !message.isEmpty || !(subject ?? "").isEmpty else {
        throw BadRequest("A 'message' or 'subject' is required when sending via the Private API")
      }
    } else {
      guard !message.isEmpty else {
        throw BadRequest("A 'message' is required when sending via AppleScript")
      }
    }
  }

  @Test("A subject-only send is accepted, as the reference accepts it")
  func subjectOnlyIsAllowed() throws {
    // The case that regressed. `message` is present and empty, and the subject carries the
    // send; the reference answers 200 and this answered 400.
    try validate([
      "chatGuid": .string("iMessage;-;+15550000000"),
      "message": .string(""),
      "subject": .string("Reminder"),
    ])
  }

  @Test("An empty message with no subject is refused on the AppleScript path")
  func emptyMessageAppleScript() {
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "message": .string(""),
      ])
    }
  }

  @Test("An empty message with an empty subject is refused on the Private API path")
  func emptyBothPrivateAPI() {
    // Both empty means nothing to send, whichever backend is chosen.
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "message": .string(""),
        "subject": .string(""),
      ])
    }
  }

  @Test("An absent message key is refused however it would be sent")
  func absentMessageKey() {
    // `present` is the half that still applies: the key has to be there.
    #expect(throws: BadRequest.self) {
      try validate(["chatGuid": .string("iMessage;-;+15550000000")])
    }
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "subject": .string("Reminder"),
      ])
    }
  }

  @Test(
    "A Private-API-implying field moves the rule to the Private API's",
    arguments: ["effectId", "selectedMessageGuid", "ddScan", "attributedBody", "textFormatting"]
  )
  func impliedPrivateAPI(field: String) throws {
    // `messageValidator.ts:87-103`: any of these implies private-api because AppleScript
    // cannot carry them. With a subject present the send is then legal on an empty message.
    try validate([
      "chatGuid": .string("iMessage;-;+15550000000"),
      "message": .string(""),
      "subject": .string("Reminder"),
      field: .string("x"),
    ])
  }

  @Test("An ordinary text send is unaffected")
  func ordinarySend() throws {
    try validate([
      "chatGuid": .string("iMessage;-;+15550000000"),
      "message": .string("hello"),
    ])
  }

  @Test("A missing chatGuid is still refused")
  func missingChatGUID() {
    #expect(throws: BadRequest.self) {
      try validate(["message": .string("hello")])
    }
  }
}

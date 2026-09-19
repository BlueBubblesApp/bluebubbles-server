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

  /// The handler's own validator, reached exactly as the route reaches it.
  @discardableResult
  private func validate(_ body: [String: JSONValue]) throws -> WriteHandlers.SendTextFields {
    try WriteHandlers.sendTextFields(from: RequestValues(.object(body)))
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
    arguments: ["effectId", "selectedMessageGuid", "ddScan", "attributedBody"]
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

  @Test("Text formatting implies the Private API, and must be a well-formed array")
  func textFormattingImpliesPrivateAPI() throws {
    // Its own case rather than a sixth argument above, because `textFormatting` is the one
    // implying field that is STRUCTURED: the others imply by being present, this one by being
    // a non-empty array of ranges. The mirror this suite used to call read it as "present",
    // so it accepted `textFormatting: "x"` — a string the real validator rejects outright.
    // That divergence is why the two copies had to become one.
    let range = JSONValue.object([
      "start": .int(0), "length": .int(3), "styles": .array([.string("bold")]),
    ])
    let fields = try validate([
      "chatGuid": .string("iMessage;-;+15550000000"),
      "message": .string(""),
      "subject": .string("Reminder"),
      "textFormatting": .array([range]),
    ])
    #expect(fields.formatting.count == 1)

    // Not an array at all is a 400, whatever else the request carries.
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "message": .string("hello"),
        "textFormatting": .string("x"),
      ])
    }
  }

  @Test("An unknown send method is refused")
  func unknownMethodIsRefused() {
    // The other half the mirror did not have. `method` is how a client forces a backend, and
    // an unrecognised one has to be a 400 rather than silently defaulting to AppleScript.
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "message": .string("hello"),
        "method": .string("carrier-pigeon"),
      ])
    }
  }

  @Test("Forcing the Private API moves the emptiness rule with it")
  func forcedPrivateAPIIsHonoured() throws {
    // `method: private-api` with a subject and an empty message is legal; the same request
    // without the subject is not, because neither half then carries the send.
    try validate([
      "chatGuid": .string("iMessage;-;+15550000000"),
      "message": .string(""),
      "subject": .string("Reminder"),
      "method": .string("private-api"),
    ])
    #expect(throws: BadRequest.self) {
      try validate([
        "chatGuid": .string("iMessage;-;+15550000000"),
        "message": .string(""),
        "method": .string("private-api"),
      ])
    }
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

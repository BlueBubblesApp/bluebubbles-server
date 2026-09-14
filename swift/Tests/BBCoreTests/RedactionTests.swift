//  RedactionTests
//  The exact shape an address takes in a log line.
//
//  Pinned as strings because the shape is the contract: a reader correlating a log against
//  Messages.app relies on "country code, then the last four" and "two letters, then the
//  domain", and a change that showed one digit more or fewer would silently change what a
//  support log reveals. The policy test (`LogRedactionPolicyTests`) checks that call sites
//  use these; this checks what they produce.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Testing

@testable import BBCore

@Suite("Redaction")
struct RedactionTests {

  @Test("An E.164 number keeps its country code and last four digits")
  func phone() {
    #expect(Redaction.address("+12025550143") == "+1…0143")
    #expect(Redaction.address("+15555550199") == "+1…0199")
  }

  @Test("Bare digits keep only the last four")
  func bareDigits() {
    #expect(Redaction.address("2025550143") == "…0143")
  }

  @Test("An email keeps two letters of the local part and the whole domain")
  func email() {
    #expect(Redaction.address("someone@example.com") == "so…@example.com")
    #expect(Redaction.address("a@example.org") == "a…@example.org")
  }

  @Test("A value too short to trim becomes the bare mask")
  func short() {
    #expect(Redaction.address("12345") == "…")
    #expect(Redaction.address("") == "…")
  }

  @Test("A direct chat GUID redacts its address field and keeps the prefix")
  func directChat() {
    #expect(Redaction.chatGUID("iMessage;-;+12025550143") == "iMessage;-;+1…0143")
    #expect(Redaction.chatGUID("any;-;someone@example.com") == "any;-;so…@example.com")
    #expect(Redaction.chatGUID("SMS;-;+12025550143") == "SMS;-;+1…0143")
  }

  @Test("A group chat GUID names a room, not a person, and passes through")
  func groupChat() {
    #expect(Redaction.chatGUID("iMessage;+;chat123456789") == "iMessage;+;chat123456789")
  }

  @Test("Something that is not a chat GUID is returned unchanged")
  func notAChat() {
    #expect(Redaction.chatGUID("chat123456789") == "chat123456789")
    #expect(Redaction.chatGUID("") == "")
  }

  @Test("Credential query values are blanked; host and path stay")
  func url() {
    #expect(
      Redaction.url("https://hooks.example.com/bb?password=hunter2&x=1")
        == "https://hooks.example.com/bb?password=***&x=1")
    #expect(
      Redaction.url("https://hooks.example.com/bb?GUID=abc&token=t")
        == "https://hooks.example.com/bb?GUID=***&token=***")
  }

  @Test("A URL without a query, or that does not parse, is returned as given")
  func urlPassThrough() {
    #expect(Redaction.url("https://hooks.example.com/bb") == "https://hooks.example.com/bb")
    #expect(Redaction.url("not a url") == "not a url")
  }
}

//  ChatGUIDShapeTests
//  The chat GUID a helper is handed, and what it says when that GUID was mangled on the way.
//
//  This exists because of a day spent chasing the wrong framework. `POST /message/attachment`
//  was reported as broken on every send, with "ChatKit does not know a conversation with GUID
//  any". The GUID in the request was `any;-;<address>`; what reached the helper was `any`,
//  because `curl -F` reads a semicolon in a field value as the start of a field OPTION and
//  sends only what precedes it. Measured on curl 8.7.1:
//
//      -F "chatGuid=any;-;+15555550100"            -> chatGuid: any
//      -F 'chatGuid=any\;-\;+15555550100'          -> chatGuid: any\
//      --form-string "chatGuid=any;-;+15555550100" -> chatGuid: any;-;+15555550100
//
//  The server was never at fault: `UploadedFileBodyTests` holds the recorded reference form
//  against the real parser and the GUID comes through whole. What was at fault was the error,
//  which named a framework that had not failed and gave a reader nothing to notice.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesHelper

@Suite("Chat GUID shape")
struct ChatGUIDShapeTests {

  @Test("A direct and a group GUID are both well formed")
  func wellFormed() {
    #expect(ChatIdentifier("any;-;+15555550100").isWellFormed)
    #expect(ChatIdentifier("iMessage;-;person@example.com").isWellFormed)
    #expect(ChatIdentifier("SMS;-;+15555550100").isWellFormed)
    #expect(ChatIdentifier("any;+;chat000000000000000001").isWellFormed)
    #expect(ChatIdentifier("iMessage;+;chat000000000000000001").isWellFormed)
  }

  /// Each of these is a GUID that lost its separator somewhere in transit. The first is the
  /// one that actually happened.
  @Test("A GUID cut short at a semicolon is not")
  func truncated() {
    #expect(!ChatIdentifier("any").isWellFormed)
    #expect(!ChatIdentifier("any\\").isWellFormed)
    #expect(!ChatIdentifier("iMessage").isWellFormed)
    #expect(!ChatIdentifier("").isWellFormed)
    #expect(!ChatIdentifier("+15555550100").isWellFormed)
  }

  /// The address is not judged, only the shape: `any` is a service name on macOS 26 and the
  /// address can be a number, an email or a room name. Anything stricter would refuse a
  /// spelling Apple introduces next.
  @Test("The service and address are not judged")
  func shapeOnly() {
    #expect(ChatIdentifier("whatever;-;whatever").isWellFormed)
    #expect(ChatIdentifier("RCS;-;+15555550100").isWellFormed)
  }

  @Test("A mangled GUID is told why it cannot match")
  func explainsTruncation() {
    let reason = String(describing: PrivateAPIErrorBridge.noSuchChat("any"))
    #expect(reason.contains("is not a chat GUID"))
    // The remedy, not just the diagnosis: this is the sentence that ends the investigation.
    #expect(reason.contains("--form-string"))
  }

  /// A well-formed GUID that simply is not there gets the plain answer. Naming `curl` for a
  /// deleted conversation would be the same mistake in the other direction.
  @Test("A well-formed GUID that is missing gets the plain answer")
  func plainMiss() {
    let reason = String(describing: PrivateAPIErrorBridge.noSuchChat("any;-;+15555550100"))
    #expect(reason.contains("Messages does not know a chat with GUID any;-;+15555550100"))
    #expect(!reason.contains("--form-string"))
  }
}

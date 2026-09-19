//  PollPayloadTests
//  The archive walk and the two JSON shapes, against a payload built the way MSMessage
//  builds one: a keyed archive of a dictionary holding an NSURL, a name and an NSUUID.

import Foundation
import Testing

@testable import BBIMessage

@Suite("Poll payloads")
struct PollPayloadTests {

  private func archive(json: String, query: String = "", session: UUID = UUID()) throws -> Data {
    let body = Data(json.utf8).base64EncodedString()
    let dictionary: NSDictionary = [
      "URL": NSURL(string: "data:," + body + query)!,
      "an": "Polls",
      "sessionIdentifier": session as NSUUID,
    ]
    return try NSKeyedArchiver.archivedData(withRootObject: dictionary, requiringSecureCoding: true)
  }

  @Test("A poll archive yields its JSON and session, with the URL query stripped")
  func pollArchive() throws {
    let session = UUID()
    let json =
      #"{"version":1,"item":{"title":"Dinner?","creatorHandle":"me@example.com","orderedPollOptions":[{"optionIdentifier":"A","text":"Pizza","canBeEdited":false}]}}"#
    let envelope = try #require(
      PollPayload.envelope(from: try archive(json: json, query: "?src=p&c=1", session: session)))
    #expect(envelope.sessionID == session.uuidString)
    let poll = try JSONDecoder().decode(PollPayload.Definition.self, from: envelope.json)
    #expect(poll.item.title == "Dinner?")
    #expect(poll.item.orderedPollOptions.map(\.text) == ["Pizza"])
  }

  @Test("A vote archive decodes to the voter's selection")
  func voteArchive() throws {
    let json =
      #"{"version":1,"item":{"votes":[{"participantHandle":"me@example.com","voteOptionIdentifier":"A"},{"participantHandle":"me@example.com","voteOptionIdentifier":"B"}]}}"#
    let envelope = try #require(PollPayload.envelope(from: try archive(json: json)))
    let votes = try JSONDecoder().decode(PollPayload.Votes.self, from: envelope.json)
    #expect(votes.item.votes.map(\.voteOptionIdentifier) == ["A", "B"])
  }

  @Test("Not an archive, not a data URL, or nothing at all is nil rather than a crash")
  func garbage() throws {
    #expect(PollPayload.envelope(from: nil) == nil)
    #expect(PollPayload.envelope(from: Data("junk".utf8)) == nil)
    let plain: NSDictionary = ["URL": NSURL(string: "https://example.com")!]
    let data = try NSKeyedArchiver.archivedData(withRootObject: plain, requiringSecureCoding: true)
    #expect(PollPayload.envelope(from: data) == nil)
  }
}

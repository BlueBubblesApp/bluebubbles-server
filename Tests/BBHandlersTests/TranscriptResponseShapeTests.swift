//  TranscriptResponseShapeTests
//  What `GET /api/v2/transcript/chat` emits, held against what the document declares.
//
//  Same check as `StickerResponseShapeTests`, for the same reason: `ResponseBodies` is
//  hand-written for a route no fixture covers, and every other test over it compares the
//  declaration to itself. Executing the serializer and comparing key sets is the one check
//  that can catch a declared field the handler never writes, or a written one the document
//  never promises.
//
//  Key sets only. The values are the interface's business and are covered in
//  `TranscriptInterfaceTests`.

import BBHTTPAPI
import BBInterfaces
import BBOpenAPI
import BBSerialization
import BBTranscript
import Foundation
import Testing

@testable import BBHandlers

@Suite("The transcript chat listing matches what the document declares")
struct TranscriptResponseShapeTests {

  private func keys(of value: JSONValue) -> Set<String> {
    guard case .object(let members) = value else {
      Issue.record("expected a JSON object")
      return []
    }
    return Set(members.keys)
  }

  private var candidate: TranscriptInterface.ChatCandidate {
    TranscriptInterface.ChatCandidate(
      chat: Transcript.Chat(
        guid: "iMessage;+;chat123456789", displayName: "Team", isGroup: true,
        service: "iMessage",
        participants: [
          Transcript.Participant(
            address: "+15555550101", service: "iMessage", name: "Alice Example",
            nameSource: .contacts)
        ]),
      lastMessageDate: Date(timeIntervalSince1970: 1_788_396_119), isArchived: false)
  }

  @Test("A conversation emits exactly the declared fields")
  func chatShapeMatches() throws {
    let body = try #require(ResponseBodies.byHandler[.transcriptChats])
    let declared = try #require(body.variants.first).properties
    let emitted = keys(of: TranscriptHandlers.serialize(candidate))
    #expect(emitted == Set(declared.map(\.name)))
  }

  @Test("A participant emits exactly the declared fields")
  func participantShapeMatches() throws {
    let body = try #require(ResponseBodies.byHandler[.transcriptChats])
    let declared = try #require(body.variants.first).properties
    let participants = try #require(declared.first { $0.name == "participants" })
    guard case .array(of: .object(let nested)) = participants.schema else {
      Issue.record("participants should be declared as an array of objects")
      return
    }
    let emitted = keys(of: TranscriptHandlers.serialize(candidate.chat.participants[0]))
    #expect(emitted == Set(nested.map(\.name)))
  }

  @Test("The export body reads every field the document declares")
  func exportBodyFieldsAreRead() throws {
    let body = try #require(RequestBodies.byHandler[.transcriptExport])
    let request = try TranscriptHandlers.exportRequest(
      RequestValues(
        .object([
          "chat_guid": .string("iMessage;+;chat123456789"),
          "format": .string("html"),
          "after": .string("2024-01-01"),
          "before": .int(1_711_929_599_000),
          "attachments": .string("files"),
          "archive": .bool(false),
          "participants": .object(["+15555550101": .string("Alice Example")]),
          "me_label": .string("Myself"),
          "time_zone": .string("America/New_York"),
          "convert_attachments": .bool(false),
          "download_purged_attachments": .bool(true),
        ])))
    #expect(request.format == .html)
    #expect(request.attachmentMode == .files)
    // Files always travel as one archive, whatever `archive` said.
    #expect(request.archive)
    #expect(request.participantNames == ["+15555550101": "Alice Example"])
    #expect(request.meLabel == "Myself")
    #expect(request.timeZone.identifier == "America/New_York")
    #expect(!request.convertAttachments)
    #expect(request.downloadPurgedAttachments)
    #expect(request.after != nil)
    #expect(request.before == Date(timeIntervalSince1970: 1_711_929_599))
    // Every declared property is one the parser names, so the document cannot promise a
    // field the route ignores.
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/BBHandlers/TranscriptHandlers.swift"),
      encoding: .utf8)
    for property in body.properties {
      #expect(source.contains("\"\(property.name)\""), "\(property.name) is not read")
    }
  }

  @Test("An unknown format is refused with the allowed spellings")
  func unknownFormatIsRefused() {
    #expect(throws: BadRequest.self) {
      try TranscriptHandlers.exportRequest(
        RequestValues(.object(["chat_guid": .string("x"), "format": .string("pdf")])))
    }
  }

  @Test("A date that is neither milliseconds nor ISO 8601 is refused")
  func unreadableDateIsRefused() {
    #expect(throws: BadRequest.self) {
      try TranscriptHandlers.exportRequest(
        RequestValues(.object(["chat_guid": .string("x"), "after": .string("yesterday")])))
    }
  }
}

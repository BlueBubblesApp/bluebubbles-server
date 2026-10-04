//  TranscriptRequestShapeTests
//  The export request as the handler reads it, held against what the document declares.
//
//  `RequestBodies` is hand-written for a route no fixture covers, so the one check that can
//  catch a promised field the route ignores is to run the parser and look for every
//  declared name in the file that reads them.

import BBHTTPAPI
import BBOpenAPI
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("The transcript export request matches what the document declares")
struct TranscriptRequestShapeTests {

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

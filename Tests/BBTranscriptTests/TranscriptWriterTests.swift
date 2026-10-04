//  TranscriptWriterTests
//  The three file shapes, read back from disk.
//
//  Each writer is driven with the same two messages and the file is parsed or searched for
//  what the model said: the JSON is decoded and checked field by field, the plain text is
//  checked line by line, and the HTML is checked for its escaping, because an unescaped
//  `<` in a message is the one way a transcript page can run something.

import Foundation
import Testing

@testable import BBTranscript

@Suite("Transcript writers")
struct TranscriptWriterTests {

  private let zone = TimeZone(identifier: "UTC")!
  private let alice = Transcript.Participant(
    address: "+15555550101", service: "iMessage", name: "Alice Example", nameSource: .contacts)

  private func header(_ format: TranscriptFormat, mode: Transcript.AttachmentMode = .files)
    -> Transcript.Header
  {
    Transcript.Header(
      chat: Transcript.Chat(
        guid: "iMessage;+;chat1", displayName: "Team", isGroup: true, service: "iMessage",
        participants: [alice]),
      format: format, attachmentMode: mode,
      after: Date(timeIntervalSince1970: 1_700_000_000), before: nil, timeZone: zone,
      meLabel: "Me", exportedAt: Date(timeIntervalSince1970: 1_700_100_000),
      generator: "BlueBubbles Server test")
  }

  private var messages: [Transcript.Message] {
    [
      Transcript.Message(
        guid: "MSG-1", date: Date(timeIntervalSince1970: 1_700_000_000), isFromMe: false,
        sender: alice, text: "hello <world> & \"friends\"\nsecond line",
        attachments: [
          Transcript.Attachment(
            guid: "ATT-1", name: "photo.jpg", mimeType: "image/jpeg", byteSize: 2048,
            exportedPath: "attachments/ATT-1/photo.jpg")
        ],
        edits: [Transcript.Edit(date: Date(timeIntervalSince1970: 1_699_999_000), text: "helo")]),
      Transcript.Message(
        guid: "MSG-2", date: Date(timeIntervalSince1970: 1_700_090_000), isFromMe: true,
        kind: .reaction(
          Transcript.Reaction(type: "love", targetGUID: "MSG-1", targetSummary: "hello"))),
    ]
  }

  private func render(_ format: TranscriptFormat) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-transcript-\(UUID().uuidString).\(format.fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = format.makeWriter(output: try TranscriptOutput(url: url))
    try writer.begin(header(format))
    var summary = Transcript.Summary()
    for message in messages {
      try writer.write(message)
      summary.record(message)
    }
    try writer.finish(summary)
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test("JSON carries the header, every message, and the summary")
  func json() throws {
    let text = try render(.json)
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    let root = try #require(object)
    #expect(root["schema_version"] as? Int == JSONTranscriptWriter.schemaVersion)
    #expect(root["time_zone"] as? String == "UTC")
    #expect(root["me_label"] as? String == "Me")
    let chat = try #require(root["chat"] as? [String: Any])
    #expect(chat["title"] as? String == "Team")
    let participants = try #require(chat["participants"] as? [[String: Any]])
    #expect(participants.first?["name_source"] as? String == "contacts")
    let range = try #require(root["range"] as? [String: Any])
    #expect(range["after"] as? Int == 1_700_000_000_000)
    #expect(range["before"] is NSNull)

    let rows = try #require(root["messages"] as? [[String: Any]])
    #expect(rows.count == 2)
    let first = rows[0]
    #expect(first["kind"] as? String == "message")
    #expect(first["date"] as? Int == 1_700_000_000_000)
    #expect(first["date_iso"] as? String == "2023-11-14T22:13:20Z")
    #expect((first["sender"] as? [String: Any])?["address"] as? String == "+15555550101")
    let attachments = try #require(first["attachments"] as? [[String: Any]])
    #expect(attachments[0]["path"] as? String == "attachments/ATT-1/photo.jpg")
    let edits = try #require(first["edits"] as? [[String: Any]])
    #expect(edits[0]["text"] as? String == "helo")
    let second = rows[1]
    #expect(second["kind"] as? String == "reaction")
    let reaction = try #require(second["reaction"] as? [String: Any])
    #expect(reaction["target_guid"] as? String == "MSG-1")
    #expect(reaction["is_removal"] as? Bool == false)

    let summary = try #require(root["summary"] as? [String: Any])
    #expect(summary["message_count"] as? Int == 2)
    #expect(summary["reaction_count"] as? Int == 1)
    #expect(summary["attachments_copied"] as? Int == 1)
  }

  @Test("Plain text is one timestamped line per message with a day heading")
  func plainText() throws {
    let text = try render(.txt)
    #expect(text.hasPrefix("Conversation: Team\n"))
    #expect(text.contains("  - Alice Example (+15555550101)\n"))
    #expect(text.contains("---- Tuesday, 14 November 2023 ----\n"))
    #expect(
      text.contains(
        "[2023-11-14 22:13:20] Alice Example: hello <world> & \"friends\"\n    second line\n"
          + "    1 Photo (attachments/ATT-1/photo.jpg)\n"))
    #expect(text.contains("    (earlier version, 2023-11-14 21:56:40: helo)\n"))
    #expect(text.contains("[2023-11-15 23:13:20] — Me loved “hello”\n"))
    #expect(text.hasSuffix("Messages: 2\nReactions: 1\nAttachments: 1\nAttachments included: 1\n"
        + "Spanning: 2023-11-14 22:13:20 to 2023-11-15 23:13:20\n"))
  }

  @Test("HTML escapes the words and shows the photo inline")
  func html() throws {
    let text = try render(.html)
    #expect(text.hasPrefix("<!DOCTYPE html>"))
    #expect(text.contains("<title>Team</title>"))
    #expect(text.contains("hello &lt;world&gt; &amp; &quot;friends&quot;<br>second line"))
    #expect(!text.contains("<world>"))
    #expect(text.contains("<img src=\"attachments/ATT-1/photo.jpg\""))
    let event = "<div class=\"event\"><time>2023-11-15 23:13:20</time> Me loved “hello”</div>"
    #expect(text.contains(event))
    #expect(text.contains("<details class=\"edits\">"))
    #expect(text.contains("</html>"))
    #expect(!text.contains("<script"))
  }

  @Test("Without files an attachment is named, not linked")
  func metadataOnly() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-transcript-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = HTMLTranscriptWriter(output: try TranscriptOutput(url: url))
    try writer.begin(header(.html, mode: .metadata))
    var message = messages[0]
    message.attachments[0].exportedPath = nil
    try writer.write(message)
    try writer.finish(Transcript.Summary())
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("<div class=\"attachment\">📎 photo.jpg</div>"))
    #expect(!text.contains("<img"))
  }

  @Test("Every format names its file and its content type")
  func formats() {
    #expect(TranscriptFormat.json.fileExtension == "json")
    #expect(TranscriptFormat.txt.contentType == "text/plain; charset=utf-8")
    #expect(TranscriptFormat.html.title == "HTML page")
  }
}

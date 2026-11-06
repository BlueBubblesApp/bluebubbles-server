//  MultipartSegmentTests
//  An inline mention is one line: consecutive text parts become one composition append.
//
//  `compositionByAppendingText:` starts a new line when the composition already ends in
//  text, so a client's `["hey ", mention, " whatsup?"]` appended part by part arrived as
//  three lines. `CKCompositions.segments(of:)` is what joins them; these tests hold the
//  joined string, where the mention attribute lands, and that an attachment still splits.

import BBPrivateAPIContract
import Foundation
import Testing

@testable import BlueBubblesHelper

@Suite("Multipart segments")
struct MultipartSegmentTests {

  private static let mentionKey = NSAttributedString.Key("__kIMMentionConfirmedMention")

  private func texts(_ segments: [CKCompositions.Segment]) -> [String?] {
    segments.map {
      if case .text(let run) = $0 { return run.string }
      return nil
    }
  }

  @Test("An inline mention and the text around it are one run, the mention on its range only")
  func inlineMentionIsOneRun() throws {
    let segments = CKCompositions.segments(of: [
      MessagePart(text: "hey "),
      MessagePart(text: "Name", mention: "someone@example.com"),
      MessagePart(text: " whatsup?"),
    ])
    #expect(segments.count == 1)
    guard case .text(let run) = try #require(segments.first) else {
      Issue.record("expected a text segment")
      return
    }
    #expect(run.string == "hey Name whatsup?")

    var mentioned: [String] = []
    run.enumerateAttribute(
      Self.mentionKey, in: NSRange(location: 0, length: run.length)
    ) { value, range, _ in
      guard let value = value as? String else { return }
      #expect(value == "someone@example.com")
      mentioned.append((run.string as NSString).substring(with: range))
    }
    #expect(mentioned == ["Name"])
  }

  @Test("Formatting stays on the part it was given for, offset into the joined run")
  func formattingKeepsItsPart() throws {
    let segments = CKCompositions.segments(of: [
      MessagePart(text: "hi "),
      MessagePart(text: "bold", formatting: [FormattedRange(start: 0, length: 4, styles: [.bold])]),
    ])
    guard case .text(let run) = try #require(segments.first) else {
      Issue.record("expected a text segment")
      return
    }
    let bold = NSAttributedString.Key("__kIMTextBoldAttributeName")
    #expect(run.attribute(bold, at: 0, effectiveRange: nil) == nil)
    var range = NSRange()
    #expect(run.attribute(bold, at: 3, effectiveRange: &range) as? Int == 1)
    #expect(range == NSRange(location: 3, length: 4))
  }

  @Test("An attachment splits the text around it, and empty parts are dropped")
  func attachmentSplitsText() {
    let segments = CKCompositions.segments(of: [
      MessagePart(text: "before "),
      MessagePart(text: "", mention: "someone@example.com"),
      MessagePart(text: "too"),
      MessagePart(attachmentPath: "/tmp/file.png"),
      MessagePart(text: "after"),
      MessagePart(),
    ])
    #expect(texts(segments) == ["before too", nil, "after"])
    guard case .media(let path) = segments[1] else {
      Issue.record("expected the attachment in the middle")
      return
    }
    #expect(path == "/tmp/file.png")
  }
}

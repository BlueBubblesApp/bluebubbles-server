//  MultipartSegmentTests
//  An inline mention is one line: consecutive text parts become one composition append.
//
//  `compositionByAppendingText:` starts a new line when the composition already ends in
//  text, so a client's `["hey ", mention, " whatsup?"]` appended part by part arrived as
//  three lines. `CKCompositions.segments(of:)` is what joins them; these tests hold the
//  joined string, where the mention attribute lands, and that an attachment still splits.
//
//  They also hold the message-part tag on a joined run: every character or none, never a
//  formatted word tagged beside an untagged space, and numbered by the segment's position.

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

  private static let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")

  private func boldWhole(_ text: String) -> [FormattedRange] {
    [FormattedRange(start: 0, length: text.utf16.count, styles: [.bold])]
  }

  /// Each stretch of `run` with its part tag, as (text, tag or nil), so a gap shows up as a
  /// stretch whose tag is nil.
  private func partStretches(_ run: NSAttributedString) -> [(String, Int?)] {
    var stretches: [(String, Int?)] = []
    run.enumerateAttribute(
      Self.partKey, in: NSRange(location: 0, length: run.length)
    ) { value, range, _ in
      stretches.append(((run.string as NSString).substring(with: range), value as? Int))
    }
    return stretches
  }

  private func textRuns(_ segments: [CKCompositions.Segment]) -> [NSAttributedString] {
    segments.compactMap {
      if case .text(let run) = $0 { return run }
      return nil
    }
  }

  @Test("A plain part beside a formatted one is tagged too, so the run is one part")
  func plainTextBesideFormattingIsTagged() throws {
    let runs = textRuns(
      CKCompositions.segments(of: [
        MessagePart(text: "hi "),
        MessagePart(text: "there", formatting: boldWhole("there")),
      ]))
    let run = try #require(runs.first)
    #expect(run.string == "hi there")
    #expect(partStretches(run).map(\.0) == ["hi there"])
    #expect(partStretches(run).map(\.1) == [0])
  }

  @Test("Per-word formatting with plain spaces between the words is one tagged part")
  func perWordFormattingKeepsTheSpacesInThePart() throws {
    let runs = textRuns(
      CKCompositions.segments(of: [
        MessagePart(text: "Hello", formatting: boldWhole("Hello")),
        MessagePart(text: " "),
        MessagePart(text: "world", formatting: boldWhole("world")),
      ]))
    let run = try #require(runs.first)
    #expect(run.string == "Hello world")
    #expect(partStretches(run).map(\.1) == [0])
  }

  @Test("An unformatted mention in a run with formatting carries the part tag")
  func unformattedMentionIsTagged() throws {
    let runs = textRuns(
      CKCompositions.segments(of: [
        MessagePart(text: "Name", mention: "someone@example.com"),
        MessagePart(
          text: " ok", formatting: [FormattedRange(start: 1, length: 2, styles: [.bold])]),
      ]))
    let run = try #require(runs.first)
    #expect(run.string == "Name ok")
    #expect(partStretches(run).map(\.1) == [0])
    #expect(
      run.attribute(Self.mentionKey, at: 0, effectiveRange: nil) as? String == "someone@example.com"
    )
  }

  @Test("Plain parts with no formatting get no part tag at all")
  func plainPartsStayUntagged() throws {
    let runs = textRuns(
      CKCompositions.segments(of: [
        MessagePart(text: "hey "),
        MessagePart(text: "Name", mention: "someone@example.com"),
        MessagePart(text: " whatsup?"),
      ]))
    let run = try #require(runs.first)
    #expect(partStretches(run).map(\.1) == [nil])
  }

  @Test("A tagged run after an attachment is numbered by its position, not 0")
  func runAfterAttachmentTakesItsPosition() {
    let runs = textRuns(
      CKCompositions.segments(of: [
        MessagePart(text: "a", formatting: boldWhole("a")),
        MessagePart(attachmentPath: "/tmp/file.png"),
        MessagePart(text: "b "),
        MessagePart(text: "c", formatting: boldWhole("c")),
        MessagePart(attachmentPath: "/tmp/other.png"),
        MessagePart(text: "plain"),
      ]))
    #expect(runs.map(\.string) == ["a", "b c", "plain"])
    #expect(runs.map { partStretches($0).map(\.1) } == [[0], [2], [nil]])
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

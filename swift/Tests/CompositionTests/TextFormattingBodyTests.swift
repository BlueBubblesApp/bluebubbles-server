//  TextFormattingBodyTests
//  `textFormatting` in a request body, as a client would send it.

import BBHTTPAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation
import Testing

@testable import BBHandlers

@Suite("textFormatting request bodies")
struct TextFormattingBodyTests {

  @Test("The reference's shape parses, with the added effect")
  func parses() throws {
    let body = try JSONValue.parse(
      Data(
        #"[{"start":0,"length":5,"styles":["bold","italic"]},{"start":6,"length":3,"styles":[],"effect":"shake"}]"#
          .utf8))
    let ranges = try TextFormattingBody.parse(body)
    #expect(
      ranges == [
        FormattedRange(start: 0, length: 5, styles: [.bold, .italic]),
        FormattedRange(start: 6, length: 3, styles: [], effect: .shake),
      ])
  }

  @Test("Absent means no formatting; a non-array is refused")
  func absentAndWrongType() throws {
    #expect(try TextFormattingBody.parse(nil).isEmpty)
    #expect(throws: BadRequest.self) { try TextFormattingBody.parse(.string("bold")) }
  }

  @Test("An unknown style is refused with the reference's sentence")
  func unknownStyle() throws {
    let body = try JSONValue.parse(Data(#"[{"start":0,"length":1,"styles":["blink"]}]"#.utf8))
    #expect(throws: BadRequest.self) { try TextFormattingBody.parse(body) }
    do {
      _ = try TextFormattingBody.parse(body)
    } catch let error as BadRequest {
      #expect(error.errorMessage == "textFormatting[0].styles contains unsupported value: blink")
    }
  }

  @Test("An unknown effect is refused and the known ones are listed")
  func unknownEffect() throws {
    let body = try JSONValue.parse(Data(#"[{"start":0,"length":1,"effect":"wobble"}]"#.utf8))
    do {
      _ = try TextFormattingBody.parse(body)
      Issue.record("expected a refusal")
    } catch let error as BadRequest {
      #expect(error.errorMessage.contains("big, small, shake, nod, explode, ripple, bloom, jitter"))
    }
  }
}

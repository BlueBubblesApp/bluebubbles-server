//  TextFormattingValidationTests
//  The reference's `validateTextFormatting` rules, as the contract states them.

import BBPrivateAPIContract
import Testing

@Suite("Text formatting validation")
struct TextFormattingValidationTests {

  @Test("A well-formed set of ranges passes")
  func validPasses() throws {
    try FormattedRange.validate(
      [
        FormattedRange(start: 0, length: 5, styles: [.bold]),
        FormattedRange(start: 5, length: 6, effect: .big),
      ], utf16Length: 11)
  }

  @Test("The reference's refusals, in its words")
  func refusals() {
    func message(_ ranges: [FormattedRange], length: Int = 10) -> String? {
      do {
        try FormattedRange.validate(ranges, utf16Length: length)
        return nil
      } catch let error as TextFormattingError {
        return error.description
      } catch {
        return "\(error)"
      }
    }
    #expect(
      message([FormattedRange(start: -1, length: 1, styles: [.bold])])
        == "textFormatting[0].start must be an integer >= 0")
    #expect(
      message([FormattedRange(start: 0, length: 0, styles: [.bold])])
        == "textFormatting[0].length must be an integer > 0")
    #expect(
      message([FormattedRange(start: 8, length: 3, styles: [.bold])])
        == "textFormatting[0] range exceeds message length")
    #expect(
      message([FormattedRange(start: 0, length: 3)])
        == "textFormatting[0].styles must be a non-empty array, or an effect must be set")
    // The index in the sentence is the offending entry's.
    #expect(
      message([
        FormattedRange(start: 0, length: 1, styles: [.bold]),
        FormattedRange(start: 0, length: 0, styles: [.bold]),
      ])
        == "textFormatting[1].length must be an integer > 0")
  }

  @Test("Wire names are the reference's style strings")
  func wireNames() {
    #expect(TextStyle.allCases.map(\.rawValue) == ["bold", "italic", "underline", "strikethrough"])
    #expect(TextEffect(rawValue: "shake")?.attributeValue == 9)
  }
}

//  TextFormattingAttributesTests
//  The attributes Messages stores for styled text, written the way it stores them.

import BBPrivateAPIContract
import Foundation
import HelperShared
import Testing

@Suite("Text formatting attributes")
struct TextFormattingAttributesTests {

  private func attributes(_ text: NSAttributedString, at index: Int) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in text.attributes(at: index, effectiveRange: nil) {
      out[key.rawValue] = value
    }
    return out
  }

  @Test("Each style is its own attribute with the value 1, on exactly its range")
  func stylesLandOnTheirRanges() {
    let text = NSMutableAttributedString(string: "hello world")
    TextFormattingAttributes.apply(
      [
        FormattedRange(start: 0, length: 5, styles: [.bold, .italic]),
        FormattedRange(start: 6, length: 5, styles: [.strikethrough]),
      ], to: text)

    let h = attributes(text, at: 0)
    #expect(h["__kIMTextBoldAttributeName"] as? Int == 1)
    #expect(h["__kIMTextItalicAttributeName"] as? Int == 1)
    #expect(h["__kIMTextStrikethroughAttributeName"] == nil)
    // The space between the runs carries no style, only the part attribute.
    let space = attributes(text, at: 5)
    #expect(space["__kIMTextBoldAttributeName"] == nil)
    #expect(space["__kIMMessagePartAttributeName"] as? Int == 0)
    let w = attributes(text, at: 10)
    #expect(w["__kIMTextStrikethroughAttributeName"] as? Int == 1)
    #expect(w["__kIMTextBoldAttributeName"] == nil)
  }

  @Test("An effect is the IMTextEffectType number, and the menu's eight all map")
  func effectsAreTypeNumbers() {
    let text = NSMutableAttributedString(string: "boom")
    TextFormattingAttributes.apply(
      [FormattedRange(start: 0, length: 4, effect: .explode)], to: text)
    #expect(attributes(text, at: 0)["__kIMTextEffectAttributeName"] as? Int == 12)

    // Read from IMSharedUtilities on macOS 26.5.2 (IMTextEffectTypeFromName).
    let expected: [TextEffect: Int] = [
      .big: 5, .small: 11, .shake: 9, .nod: 8, .explode: 12, .ripple: 1, .bloom: 6, .jitter: 10,
    ]
    for (effect, number) in expected {
      #expect(effect.attributeValue == number)
      #expect(TextEffect(attributeValue: number) == effect)
    }
    #expect(TextEffect(attributeValue: 7) == nil)  // somersault: not on the menu
  }

  @Test("Ranges are UTF-16, so an emoji counts as two")
  func rangesAreUTF16() {
    let text = NSMutableAttributedString(string: "🎉 yes")
    TextFormattingAttributes.apply([FormattedRange(start: 3, length: 3, styles: [.bold])], to: text)
    #expect(attributes(text, at: 0)["__kIMTextBoldAttributeName"] == nil)
    #expect(attributes(text, at: 3)["__kIMTextBoldAttributeName"] as? Int == 1)
  }

  @Test("An out-of-bounds range is skipped and nothing else is touched")
  func outOfBoundsIsSkipped() {
    let text = NSMutableAttributedString(string: "short")
    TextFormattingAttributes.apply(
      [FormattedRange(start: 3, length: 10, styles: [.bold])], to: text)
    #expect(attributes(text, at: 4)["__kIMTextBoldAttributeName"] == nil)
  }

  @Test("No ranges means no attributes at all — a plain send stays plain")
  func emptyIsNoOp() {
    let text = NSMutableAttributedString(string: "plain")
    TextFormattingAttributes.apply([], to: text)
    #expect(attributes(text, at: 0).isEmpty)
  }
}

//  BBPrivateAPIContract: Text formatting
//  Inline styles and effects, and the ranges they apply to.
//
//  Separate from the send payloads that carry them because these four types are a closed
//  vocabulary taken from the reference helper's `TextFormattingStyle`, while the payloads
//  around them are this project's own shapes. The raw values are the contract: a client
//  written against the Objective-C helper sends the same strings here.
//
//  See `docs/PRIVATE_API_SURFACE.md` for what each maps to in IMCore.

import Foundation

/// One of the four inline styles Messages has carried since macOS 15 / iOS 18.
///
/// On the wire and in chat.db each is an attribute on the message's attributed text whose
/// value is the number 1, read back from real rows on this Mac, and the same four keys
/// the reference helper's `applyTextFormatting:` writes. The raw values are the
/// reference's `TextFormattingStyle` strings, so a client written against it sends the
/// same thing here.
public enum TextStyle: String, Codable, Sendable, CaseIterable {
  case bold, italic, underline, strikethrough

  public var attributeName: String {
    switch self {
    case .bold: "__kIMTextBoldAttributeName"
    case .italic: "__kIMTextItalicAttributeName"
    case .underline: "__kIMTextUnderlineAttributeName"
    case .strikethrough: "__kIMTextStrikethroughAttributeName"
    }
  }
}

/// An animated text effect: the eight the Messages compose menu offers.
///
/// The attribute is `__kIMTextEffectAttributeName` and its value is an `IMTextEffectType`
/// number. The numbers come from IMSharedUtilities itself on macOS 26.5.2: its exported
/// `IMTextEffectName*` constants fed through `IMTextEffectTypeFromName`, so "shake" is
/// Apple's `shakeHorizontal` (9) and "nod" is `shakeVertical` (8), and "ripple" is
/// `scaleRipple` (1). Four more types exist (stretch 2, squish 3, bounce 4, somersault 7)
/// that the menu does not offer; they are not exposed here because nothing has been seen
/// to send them.
public enum TextEffect: String, Codable, Sendable, CaseIterable {
  case big, small, shake, nod, explode, ripple, bloom, jitter

  public static let attributeName = "__kIMTextEffectAttributeName"

  public var attributeValue: Int {
    switch self {
    case .big: 5
    case .small: 11
    case .shake: 9
    case .nod: 8
    case .explode: 12
    case .ripple: 1
    case .bloom: 6
    case .jitter: 10
    }
  }

  /// The type number back to a name, for reading a row. Nil for a type the menu does not
  /// offer.
  public init?(attributeValue: Int) {
    guard let match = Self.allCases.first(where: { $0.attributeValue == attributeValue }) else {
      return nil
    }
    self = match
  }
}

/// A run of text to style: `start` and `length` in UTF-16 code units, which is what an
/// `NSAttributedString` range is and what JavaScript and Dart string indices are. A client
/// that counts characters some other way will style the wrong run on any text with an
/// emoji or a combining mark in it.
public struct FormattedRange: Codable, Sendable, Equatable {
  public var start: Int
  public var length: Int
  public var styles: [TextStyle]
  public var effect: TextEffect?

  public init(start: Int, length: Int, styles: [TextStyle] = [], effect: TextEffect? = nil) {
    self.start = start
    self.length = length
    self.styles = styles
    self.effect = effect
  }

  /// The reference's `validateTextFormatting` rules, with one relaxation: a range may
  /// carry an effect and no styles, since an effect is a thing on its own. The sentences
  /// are the reference's, because a client may already show them.
  public static func validate(_ ranges: [FormattedRange], utf16Length: Int) throws {
    for (index, range) in ranges.enumerated() {
      guard range.start >= 0 else {
        throw TextFormattingError("textFormatting[\(index)].start must be an integer >= 0")
      }
      guard range.length > 0 else {
        throw TextFormattingError("textFormatting[\(index)].length must be an integer > 0")
      }
      // Added, not multiplied out: `start` and `length` are each within bounds by the two
      // guards above, but their SUM is not. Plain `+` on two client-chosen integers traps
      // on overflow, so `{"start": 9223372036854775807, "length": 1}` passed both guards
      // and then stopped the process on this line. The reported-overflow form cannot trap
      // and reaches the same refusal, since a range that overflows is certainly longer than
      // any message.
      let (end, overflowed) = range.start.addingReportingOverflow(range.length)
      guard !overflowed, end <= utf16Length else {
        throw TextFormattingError("textFormatting[\(index)] range exceeds message length")
      }
      guard !range.styles.isEmpty || range.effect != nil else {
        throw TextFormattingError(
          "textFormatting[\(index)].styles must be a non-empty array, or an effect must be set"
        )
      }
    }
  }
}

public struct TextFormattingError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

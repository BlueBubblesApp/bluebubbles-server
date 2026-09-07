//  TextFormattingAttributes
//  Turns `FormattedRange`s into the attributes Messages stores.
//
//  In HelperShared rather than the helper proper so it can be tested without IMCore: it is
//  Foundation only. Both send paths call it — the IMCore one hands the string to the
//  `IMMessage` initializer, the ChatKit one to `compositionByAppendingText:` — and the
//  attributes travel unchanged into the message's attributed body either way, which is
//  where iOS reads them.

import BBPrivateAPIContract
import Foundation

public enum TextFormattingAttributes {

  /// Messages' own part attribute, which the reference helper writes over the whole string
  /// whenever it applies formatting. Written for the same reason: it is what every
  /// attributed body Messages produces carries, and a styled run without it has not been
  /// seen.
  public static let partAttributeName = "__kIMMessagePartAttributeName"

  /// Applies the ranges. Out-of-bounds ranges are skipped, not clamped — the interface
  /// validates before sending, so one reaching here is a bug worth not compounding.
  public static func apply(
    _ ranges: [FormattedRange], to text: NSMutableAttributedString, partIndex: Int = 0
  ) {
    guard !ranges.isEmpty else { return }
    let whole = NSRange(location: 0, length: text.length)
    text.addAttribute(.init(partAttributeName), value: partIndex, range: whole)
    for range in ranges {
      guard range.start >= 0, range.length > 0, range.start + range.length <= text.length
      else { continue }
      let nsRange = NSRange(location: range.start, length: range.length)
      for style in range.styles {
        text.addAttribute(.init(style.attributeName), value: 1, range: nsRange)
      }
      if let effect = range.effect {
        text.addAttribute(
          .init(TextEffect.attributeName), value: effect.attributeValue, range: nsRange
        )
      }
    }
  }
}

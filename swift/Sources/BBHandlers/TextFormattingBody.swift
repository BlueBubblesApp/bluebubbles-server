//  TextFormattingBody
//  `textFormatting` as a client sends it, into `FormattedRange`s.
//
//  The shape is the reference's (`TextFormattingRange`: `start`, `length`, `styles`), plus
//  an optional `effect` this server adds. Unknown style and effect names are refused with
//  the reference's sentence rather than dropped: a client that misspells "strikethrough"
//  should hear so, not send an unstyled message.

import BBHTTPAPI
import BBPrivateAPIContract
import BBSerialization
import Foundation

enum TextFormattingBody {

  static func parse(_ value: JSONValue?) throws -> [FormattedRange] {
    guard let value else { return [] }
    guard let entries = value.arrayValue else {
      throw BadRequest("textFormatting must be an array")
    }
    return try entries.enumerated().map { index, entry in
      guard case .object = entry else {
        throw BadRequest("textFormatting[\(index)] must be an object")
      }
      guard let start = entry["start"]?.intValue else {
        throw BadRequest("textFormatting[\(index)].start must be an integer >= 0")
      }
      guard let length = entry["length"]?.intValue else {
        throw BadRequest("textFormatting[\(index)].length must be an integer > 0")
      }
      let styles = try (entry["styles"]?.arrayValue ?? []).map { raw -> TextStyle in
        guard let name = raw.stringValue, let style = TextStyle(rawValue: name) else {
          throw BadRequest(
            "textFormatting[\(index)].styles contains unsupported value: "
              + (raw.stringValue ?? String(describing: raw)))
        }
        return style
      }
      var effect: TextEffect?
      if let raw = entry["effect"], raw != .null {
        guard let name = raw.stringValue, let known = TextEffect(rawValue: name) else {
          throw BadRequest(
            "textFormatting[\(index)].effect must be one of "
              + TextEffect.allCases.map(\.rawValue).joined(separator: ", "))
        }
        effect = known
      }
      return FormattedRange(start: start, length: length, styles: styles, effect: effect)
    }
  }
}

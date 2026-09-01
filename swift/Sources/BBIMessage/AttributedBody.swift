//  AttributedBody
//  Decodes `message.attributedBody` — the field that holds the message text.
//
//  Why this is not a hand-rolled parser any more
//  --------------------------------------------
//  It used to be. The Node server carries `node-typedstream` because JavaScript has no way
//  to read Apple's `typedstream` archives, and the first pass of this port transliterated
//  that decision into Swift as a byte-level reader. On a Mac that reasoning does not hold:
//  `NSUnarchiver` reads the format natively, because it is the class that wrote it.
//
//  The transliterated reader was also wrong. Measured against 4,000 real rows from a live
//  chat.db, where `message.text` gives ground truth:
//
//      NSUnarchiver          4000/4000 decoded, 4000/4000 text exactly correct
//      hand-rolled scanner   4000/4000 "decoded", 0/4000 correct
//
//  Not a ranking bug — a structural one. That scanner collected `tagNew` length-prefixed
//  strings, which in a real archive are the class names and attribute KEYS. The message text
//  is written through the type-encoded character-array path and never appeared in what it
//  scanned at all (0% of samples), so no amount of filtering could have recovered it. Every
//  message relying on the attributedBody fallback would have shown text lifted from somewhere
//  else in the archive.
//
//  The native path also recovers four attribute keys `node-typedstream` drops outright
//  (`__kIMCalendarEventAttributeName`, `__kIMDataDetectedAttributeName`,
//  `__kIMPhoneNumberAttributeName`, `__kIMAddressAttributeName`) and real `NSURL` values for
//  `__kIMLinkAttributeName`, which it reports as `undefined`.
//
//  Why the Objective-C shim
//  ------------------------
//  `NSUnarchiver` raises `NSArchiverArchiveInconsistency` on a truncated archive, and Swift
//  cannot catch Objective-C exceptions — the process aborts. chat.db is being written by
//  Messages while we read it, so torn rows happen. `BBTypedStreamShim` is a @try/@catch
//  barrier and nothing else. See its header.
//
//  Security note: `NSUnarchiver` is unkeyed and has no secure-coding mode, so it instantiates
//  whatever classes the archive names. The input is a local SQLite file owned by the user and
//  written by Messages; an attacker able to alter it already controls the machine. The keyed
//  (binary plist) path below IS class-restricted, because that API allows it.
//
//  See `.claude/docs/imessage.md`.

import BBCore
import BBTypedStreamShim
import Foundation

public enum AttributedBodyError: BBError, Equatable {
  /// The archive could not be read. `reason` carries the underlying failure.
  case decodingFailed(reason: String)
  /// `NSUnarchiver` is not present on this system.
  case unavailable
}

// MARK: - Values

/// One attribute value from an attributed-string run.
///
/// Modelled rather than passed through as `Any` so the serializer maps a closed set and an
/// unmodelled class is visible as `.unsupported` instead of silently becoming null.
public indirect enum AttributeValue: Sendable, Equatable {
  case string(String)
  case integer(Int)
  case double(Double)
  case boolean(Bool)
  /// `__kIMDataDetectedAttributeName` and friends. Base64 on the wire.
  case data(Data)
  case url(String)
  case array([AttributeValue])
  case dictionary([String: AttributeValue])
  case null
  /// A class not modelled here, named so the gap shows up in a log rather than vanishing.
  case unsupported(className: String)
}

public struct AttributedBodyRun: Sendable, Equatable {
  /// Character offset and length, matching `NSRange` and the legacy `range: [loc, len]`.
  public let location: Int
  public let length: Int
  public let attributes: [String: AttributeValue]

  public init(location: Int, length: Int, attributes: [String: AttributeValue]) {
    self.location = location
    self.length = length
    self.attributes = attributes
  }
}

/// The decoded content of `message.attributedBody`.
public struct AttributedBody: Sendable, Equatable {

  /// The string exactly as archived, placeholders included.
  ///
  /// This is what the wire's `string` field carries — the legacy decoder passes it through
  /// unsanitised, and clients index `runs` ranges against it. Stripping here would put the
  /// ranges out of alignment with the text they describe.
  public let string: String

  public let runs: [AttributedBodyRun]

  public init(string: String, runs: [AttributedBodyRun]) {
    self.string = string
    self.runs = runs
  }

  /// The message text: placeholders stripped and trimmed.
  ///
  /// Matches Node's `universalText(sanitize: true)`, which is what populates the `text`
  /// field. Distinct from `string` on purpose — see above.
  public var text: String { AttributedBodyDecoder.cleanText(string) }

  public static let empty = AttributedBody(string: "", runs: [])
}

// MARK: - Decoding

public enum AttributedBodyDecoder {

  /// U+FFFC OBJECT REPLACEMENT CHARACTER — where an attachment sits in the text. Clients
  /// render the attachment themselves, so leaving it in produces a stray glyph.
  static let attachmentPlaceholder: Character = "\u{FFFC}"

  /// Decodes a blob into its attributed string.
  ///
  /// Two formats appear in this column: the classic `typedstream` archive, and from Ventura
  /// onward an `NSKeyedArchiver` binary plist. They are told apart by magic bytes, because
  /// feeding one to the other's reader produces garbage rather than an error.
  public static func decode(_ data: Data) throws -> AttributedBody {
    guard !data.isEmpty else { return .empty }

    let attributed: NSAttributedString
    if isBinaryPlist(data) {
      attributed = try decodeKeyedArchive(data)
    } else {
      var error: NSError?
      guard let decoded = BBUnarchiveAttributedString(data, &error) else {
        let reason = error?.localizedFailureReason ?? "unknown"
        if error?.code == BBTypedStreamErrorCode.unavailable.rawValue {
          throw AttributedBodyError.unavailable
        }
        throw AttributedBodyError.decodingFailed(reason: reason)
      }
      attributed = decoded
    }

    return AttributedBody(string: attributed.string, runs: runs(of: attributed))
  }

  /// Splits an attributed string into its runs, preserving order.
  static func runs(of attributed: NSAttributedString) -> [AttributedBodyRun] {
    var result: [AttributedBodyRun] = []
    attributed.enumerateAttributes(
      in: NSRange(location: 0, length: attributed.length),
      options: []
    ) { attributes, range, _ in
      result.append(
        AttributedBodyRun(
          location: range.location,
          length: range.length,
          attributes: attributes.reduce(into: [:]) { mapped, pair in
            mapped[pair.key.rawValue] = value(of: pair.value)
          }
        )
      )
    }
    return result
  }

  /// Maps one Foundation attribute value into the modelled set.
  static func value(of object: Any) -> AttributeValue {
    switch object {
    case let number as NSNumber:
      // NSNumber erases Bool, and `true` arriving as `1` is a real client break. The
      // ObjC type encoding is the only reliable way back.
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
      let encoding = String(cString: number.objCType)
      if encoding == "d" || encoding == "f" { return .double(number.doubleValue) }
      return .integer(number.intValue)
    case let string as String:
      return .string(string)
    case let url as URL:
      return .url(url.absoluteString)
    case let data as Data:
      return .data(data)
    case is NSNull:
      return .null
    case let array as [Any]:
      return .array(array.map(value(of:)))
    case let dictionary as [String: Any]:
      return .dictionary(dictionary.mapValues(value(of:)))
    default:
      return .unsupported(className: String(describing: type(of: object)))
    }
  }

  /// `bplist` magic. Checked rather than inferred from the macOS version, because a restored
  /// or migrated database can carry either format regardless of the running system.
  static func isBinaryPlist(_ data: Data) -> Bool {
    data.count >= 8 && data.prefix(6).elementsEqual("bplist".utf8)
  }

  /// The Ventura-and-later path. Class-restricted, which the keyed API supports and the
  /// unkeyed one does not.
  static func decodeKeyedArchive(_ data: Data) throws -> NSAttributedString {
    let allowed: [AnyClass] = [
      NSAttributedString.self, NSMutableAttributedString.self,
      NSString.self, NSMutableString.self,
      NSDictionary.self, NSMutableDictionary.self,
      NSArray.self, NSMutableArray.self,
      NSNumber.self, NSData.self, NSMutableData.self,
      NSNull.self, NSUUID.self, NSURL.self,
    ]

    do {
      let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
      unarchiver.requiresSecureCoding = false
      defer { unarchiver.finishDecoding() }

      let root = unarchiver.decodeObject(of: allowed, forKey: NSKeyedArchiveRootObjectKey)
      if let attributed = root as? NSAttributedString { return attributed }
      if let string = root as? String { return NSAttributedString(string: string) }
      return NSAttributedString(string: "")
    } catch {
      throw AttributedBodyError.decodingFailed(reason: String(describing: error))
    }
  }

  /// Strips attachment placeholders and trims. Matches Node's `sanitizeStr`.
  public static func cleanText(_ input: String) -> String {
    input
      .filter { $0 != attachmentPlaceholder }
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension AttributedBodyError {
  public var code: String {
    switch self {
    case .decodingFailed: "attributed_body.decoding_failed"
    case .unavailable: "attributed_body.unavailable"
    }
  }

  public var domain: String { "iMessage" }

  public var title: String { "A message body could not be decoded" }

  public var body: String {
    switch self {
    case .decodingFailed(let reason): reason
    case .unavailable:
      "The message has no attributed body to decode."
    }
  }
}

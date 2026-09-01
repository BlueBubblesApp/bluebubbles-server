//  VCard
//  A vCard reader, for POST /api/v1/contact/import/vcf.
//
//  Deliberately small. This parses the subset of vCard 2.1/3.0/4.0 that carries a name, a
//  phone number and an email address, which is everything the contact index stores — a full
//  implementation would handle photos, addresses, and organisational hierarchies the server
//  has nowhere to put.
//
//  What it does handle, because real exports contain all of it:
//    - Line folding (a continuation line starts with a space or tab)
//    - Parameters on properties (`TEL;TYPE=CELL:...`, `TEL;type=cell,voice:...`)
//    - Quoted-printable encoding, which vCard 2.1 exports from older phones still use
//    - CRLF, LF and CR line endings, since files arrive from every platform

import Foundation

public struct VCard: Sendable, Equatable {
  public var firstName: String?
  public var lastName: String?
  public var displayName: String?
  public var nickname: String?
  public var birthday: String?
  public var externalID: String?
  public var phoneNumbers: [String] = []
  public var emailAddresses: [String] = []

  public init() {}

  /// Every card in a file. A malformed card is SKIPPED rather than failing the import: a
  /// contact export with one bad entry should not cost the user the other four hundred.
  public static func parse(_ text: String) -> [VCard] {
    var cards: [VCard] = []
    var current: VCard?

    for line in unfold(text) {
      let upper = line.uppercased()
      if upper.hasPrefix("BEGIN:VCARD") {
        current = VCard()
        continue
      }
      if upper.hasPrefix("END:VCARD") {
        if let card = current, card.isUsable { cards.append(card) }
        current = nil
        continue
      }
      guard current != nil else { continue }
      current?.absorb(line)
    }
    return cards
  }

  /// A card with no way to reach anyone is not worth storing — and the contact index
  /// requires at least one address anyway.
  var isUsable: Bool {
    !phoneNumbers.isEmpty || !emailAddresses.isEmpty
  }

  private mutating func absorb(_ line: String) {
    guard let colon = line.firstIndex(of: ":") else { return }
    let rawName = String(line[line.startIndex..<colon])
    var value = String(line[line.index(after: colon)...])

    let segments = rawName.split(separator: ";").map(String.init)
    guard let property = segments.first?.uppercased() else { return }
    let parameters = segments.dropFirst().map { $0.uppercased() }

    if parameters.contains(where: { $0.contains("QUOTED-PRINTABLE") }) {
      value = Self.decodeQuotedPrintable(value)
    }
    value = Self.unescape(value).trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return }

    switch property {
    case "N":
      // Structured: Family;Given;Middle;Prefix;Suffix — family name FIRST, which is
      // the field order people most often get backwards.
      let parts = value.components(separatedBy: ";")
      lastName = parts.first.flatMap { $0.isEmpty ? nil : $0 }
      if parts.count > 1, !parts[1].isEmpty { firstName = parts[1] }
    case "FN":
      displayName = value
    case "NICKNAME":
      nickname = value
    case "BDAY":
      birthday = value
    case "UID":
      externalID = value
    case "TEL":
      phoneNumbers.append(value)
    case "EMAIL":
      emailAddresses.append(value)
    default:
      break
    }
  }

  // MARK: - Lexing

  /// Splits into logical lines, joining folded continuations.
  ///
  /// A line beginning with a space or tab continues the previous one. Long phone lists and
  /// base64 photos are folded routinely, and treating a continuation as its own line makes
  /// the property before it silently truncate.
  static func unfold(_ text: String) -> [String] {
    // Normalised first, so a file with CRLF and one with bare CR both split the same way.
    let normalised =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    var lines: [String] = []
    for line in normalised.components(separatedBy: "\n") {
      if let first = line.first, first == " " || first == "\t" {
        guard !lines.isEmpty else { continue }
        lines[lines.count - 1] += line.dropFirst()
      } else if !line.isEmpty {
        lines.append(line)
      }
    }

    // vCard 2.1 quoted-printable soft line breaks: a value ending in `=` continues on
    // the next physical line with no leading whitespace, so unfolding above misses them.
    var joined: [String] = []
    for line in lines {
      if let last = joined.last, last.hasSuffix("=") {
        joined[joined.count - 1] = String(last.dropLast()) + line
      } else {
        joined.append(line)
      }
    }
    return joined
  }

  /// `\,` `\;` `\n` — escaped separators inside a value.
  static func unescape(_ value: String) -> String {
    var result = ""
    var iterator = value.makeIterator()
    while let character = iterator.next() {
      guard character == "\\" else {
        result.append(character)
        continue
      }
      switch iterator.next() {
      case "n", "N": result.append("\n")
      case "t": result.append("\t")
      case let escaped?: result.append(escaped)
      case nil: result.append("\\")
      }
    }
    return result
  }

  static func decodeQuotedPrintable(_ value: String) -> String {
    var bytes: [UInt8] = []
    let characters = Array(value.utf8)
    var index = 0
    while index < characters.count {
      if characters[index] == UInt8(ascii: "="), index + 2 < characters.count {
        let hex = String(decoding: characters[(index + 1)...(index + 2)], as: UTF8.self)
        if let byte = UInt8(hex, radix: 16) {
          bytes.append(byte)
          index += 3
          continue
        }
      }
      bytes.append(characters[index])
      index += 1
    }
    // Quoted-printable carries UTF-8 bytes, which is how accented names survive the
    // round trip. A decode failure falls back to the raw text rather than dropping it.
    return String(bytes: bytes, encoding: .utf8) ?? value
  }
}

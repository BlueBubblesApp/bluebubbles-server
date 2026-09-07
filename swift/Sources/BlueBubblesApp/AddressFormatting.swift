//  AddressFormatting
//  Presentation-only formatting for phone numbers and emails.
//
//  Display only, and deliberately nowhere near storage. The index stores the address as it was
//  entered plus a stripped lookup key; formatting here would put a THIRD spelling into
//  circulation, and the one thing worse than an ugly number is a number that does not match the
//  one a client sent.
//
//  Most addresses need nothing done to them — Contacts hands back "+1 (555) 010-1234" exactly
//  as the user typed it. This exists for the ones that do not: contacts created through
//  POST /api/v1/contact, which arrive as bare digits, and rows written before the raw address
//  was persisted at all.
//
//  Not a View, so it can be tested without a SwiftUI host.

import Foundation

enum AddressFormatting {

  /// A phone number as a person would write it, when we can tell. The input otherwise.
  ///
  /// NANP only. Guessing groupings for arbitrary international numbers needs a real metadata
  /// table, and a wrong guess reads worse than no guess — so anything that is not plainly a
  /// ten- or eleven-digit North American number is returned untouched.
  static func phone(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return trimmed }

    // Already punctuated — the user formatted it, or Contacts did. Leave it alone.
    if trimmed.contains(where: { " ()-.".contains($0) }) { return trimmed }

    let hasPlus = trimmed.hasPrefix("+")
    let digits = trimmed.filter(\.isNumber)

    if digits.count == 10 {
      return group(digits, countryCode: nil)
    }
    if digits.count == 11, digits.hasPrefix("1") {
      return group(String(digits.dropFirst()), countryCode: "1")
    }
    // A plain international number: at least separate the country code from the rest.
    if hasPlus, digits.count > 11 { return "+\(digits)" }
    return trimmed
  }

  private static func group(_ tenDigits: String, countryCode: String?) -> String {
    let area = tenDigits.prefix(3)
    let exchange = tenDigits.dropFirst(3).prefix(3)
    let line = tenDigits.suffix(4)
    let national = "(\(area)) \(exchange)-\(line)"
    return countryCode.map { "+\($0) \(national)" } ?? national
  }

  /// A list of addresses, formatted and joined for a table cell.
  static func list(_ addresses: [String], areEmails: Bool) -> String {
    addresses
      .map { areEmails ? $0 : phone($0) }
      .joined(separator: ", ")
  }
}

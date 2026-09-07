//  VCardTests
//
//  Every address here is synthetic: example.com (RFC 2606) and the reserved 555-01xx range.
//  See CONTRIBUTING.md on test data.

import Foundation
import Testing

@testable import BBContacts

@Suite("VCard")
struct VCardTests {

  @Test("reads a minimal 3.0 card")
  func minimal() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      VERSION:3.0
      N:Doe;Jane;;;
      FN:Jane Doe
      TEL;TYPE=CELL:+15555550101
      EMAIL;TYPE=INTERNET:jane@example.com
      END:VCARD
      """)
    #expect(cards.count == 1)
    // N is Family;Given — the field order most often reversed.
    #expect(cards[0].lastName == "Doe")
    #expect(cards[0].firstName == "Jane")
    #expect(cards[0].displayName == "Jane Doe")
    #expect(cards[0].phoneNumbers == ["+15555550101"])
    #expect(cards[0].emailAddresses == ["jane@example.com"])
  }

  @Test("reads several cards from one file")
  func multiple() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      FN:One
      TEL:+15555550101
      END:VCARD
      BEGIN:VCARD
      FN:Two
      EMAIL:two@example.com
      END:VCARD
      """)
    #expect(cards.count == 2)
    #expect(cards[1].emailAddresses == ["two@example.com"])
  }

  /// A folded line continues with leading whitespace. Treating the continuation as its own
  /// line silently truncates the property before it, which for a long phone list means
  /// losing numbers without any error.
  @Test("joins folded lines")
  func folding() {
    let cards = VCard.parse(
      "BEGIN:VCARD\r\nFN:A Very Long\r\n  Display Name\r\nTEL:+15555550102\r\nEND:VCARD"
    )
    #expect(cards[0].displayName == "A Very Long Display Name")
  }

  @Test("handles every line ending")
  func lineEndings() {
    for separator in ["\r\n", "\n", "\r"] {
      let text = ["BEGIN:VCARD", "FN:Test", "TEL:+15555550103", "END:VCARD"]
        .joined(separator: separator)
      let cards = VCard.parse(text)
      #expect(cards.count == 1, "separator \(separator.debugDescription)")
      #expect(cards[0].phoneNumbers == ["+15555550103"])
    }
  }

  /// vCard 2.1 exports from older phones still use this, and an accented name comes
  /// through as mojibake without it.
  @Test("decodes quoted-printable")
  func quotedPrintable() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      VERSION:2.1
      N;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Fran=C3=A7ois;Jean
      TEL:+15555550104
      END:VCARD
      """)
    #expect(cards[0].lastName == "François")
  }

  @Test("unescapes separators inside values")
  func escaping() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      FN:Smith\\, John
      TEL:+15555550105
      END:VCARD
      """)
    #expect(cards[0].displayName == "Smith, John")
  }

  @Test("reads parameters in any case")
  func parameterCase() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      fn:Lower Case
      tel;type=cell,voice:+15555550106
      email;TYPE=work:lower@example.com
      END:VCARD
      """)
    #expect(cards[0].displayName == "Lower Case")
    #expect(cards[0].phoneNumbers == ["+15555550106"])
    #expect(cards[0].emailAddresses == ["lower@example.com"])
  }

  @Test("collects repeated properties")
  func repeated() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      FN:Many Numbers
      TEL;TYPE=CELL:+15555550107
      TEL;TYPE=HOME:+15555550108
      EMAIL:a@example.com
      EMAIL:b@example.com
      END:VCARD
      """)
    #expect(cards[0].phoneNumbers.count == 2)
    #expect(cards[0].emailAddresses.count == 2)
  }

  /// One bad card must not cost the user the rest of the file.
  @Test("skips cards with no way to reach anyone")
  func skipsUnusable() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      FN:No Contact Details
      END:VCARD
      BEGIN:VCARD
      FN:Reachable
      TEL:+15555550109
      END:VCARD
      """)
    #expect(cards.count == 1)
    #expect(cards[0].displayName == "Reachable")
  }

  @Test("survives truncated input")
  func truncated() {
    #expect(VCard.parse("").isEmpty)
    #expect(VCard.parse("BEGIN:VCARD\nFN:Unterminated\nTEL:+15555550110").isEmpty)
    #expect(VCard.parse("garbage with no card at all").isEmpty)
  }

  @Test("keeps the UID as an external identifier")
  func uid() {
    let cards = VCard.parse(
      """
      BEGIN:VCARD
      FN:Identified
      UID:urn:uuid:11111111-2222-3333-4444-555555555555
      TEL:+15555550111
      END:VCARD
      """)
    #expect(cards[0].externalID == "urn:uuid:11111111-2222-3333-4444-555555555555")
  }
}

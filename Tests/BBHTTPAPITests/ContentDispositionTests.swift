//  ContentDispositionTests
//  The download filename is the SENDER's, and it was being pasted into a quoted string.
//
//  `transfer_name` comes out of `chat.db`; for an incoming attachment the name was chosen on
//  somebody else's device. A `"` in it closed the quoted-string early, so
//  `My "quoted" clip.mov` reached a client as `My `. Not a response split — `swift-http-types`
//  legalizes a field value, so CR and LF never reach a socket — but a silently truncated
//  filename is enough to fix.
//
//  A non-ASCII name gets an ASCII fallback in the quoted half and its real bytes,
//  percent-encoded, in `filename*`, so no header byte is above 0x7E.
//
//  The ASCII case must stay byte-identical to what the reference sends, which is the property
//  most of these assert: a header that grew a parameter for an ordinary attachment would be a
//  wire change on the one route clients download through.
//
//  NO REAL ADDRESSES OR MESSAGE CONTENT; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBHTTPAPI

@Suite("Content-Disposition")
struct ContentDispositionTests {

  @Test("An ordinary name is exactly what the reference sends")
  func plainNameIsUnchanged() {
    #expect(
      ContentDisposition.header(filename: "IMG_0001.jpg")
        == "attachment; filename=\"IMG_0001.jpg\"")
  }

  /// Spaces are ordinary in a filename and are why the value is quoted at all. No extended
  /// parameter: a space is ASCII, so the quoted form carries it perfectly well.
  @Test("Spaces do not earn an extended parameter")
  func spacesStayInTheQuotedForm() {
    #expect(
      ContentDisposition.header(filename: "my holiday clip.mov")
        == "attachment; filename=\"my holiday clip.mov\"")
  }

  /// The defect. Escaped as a quoted-pair, so a parser reading to the closing quote gets the
  /// whole name rather than the part before the sender's quote.
  @Test("A quote in the name is escaped rather than closing the string")
  func quoteIsEscaped() {
    #expect(
      ContentDisposition.header(filename: "my \"quoted\" clip.mov")
        == "attachment; filename=\"my \\\"quoted\\\" clip.mov\"")
  }

  @Test("A backslash is escaped too, or it would escape the character after it")
  func backslashIsEscaped() {
    #expect(
      ContentDisposition.header(filename: "a\\b.jpg") == "attachment; filename=\"a\\\\b.jpg\"")
  }

  /// Dropped, not escaped: there is no quoted-pair spelling of a newline that a client
  /// renders usefully, and a filename never legitimately holds one.
  @Test("Control characters are dropped")
  func controlCharactersAreDropped() {
    #expect(
      ContentDisposition.header(filename: "clip\r\n\u{7F}.mov")
        == "attachment; filename=\"clip.mov\"")
  }

  /// The one case that grows a parameter. The quoted half is folded to ASCII rather than
  /// carrying raw UTF-8, which a recipient may read as Latin-1, refuse, or pass through.
  @Test("A non-ASCII name carries RFC 5987 bytes alongside an ASCII fallback")
  func nonASCIIGetsAnExtendedParameter() {
    #expect(
      ContentDisposition.header(filename: "Ünicöde.jpg")
        == "attachment; filename=\"Unicode.jpg\"; filename*=UTF-8''%C3%9Cnic%C3%B6de.jpg")
  }

  /// The case that was reported: macOS writes U+202F NARROW NO-BREAK SPACE before AM/PM in a
  /// screenshot's name, and ICU's `Latin-ASCII` has no rule for it.
  @Test("A narrow no-break space falls back to a plain space")
  func narrowNoBreakSpace() {
    #expect(
      ContentDisposition.header(filename: "Screenshot 6.20.00\u{202F}PM.png")
        == "attachment; filename=\"Screenshot 6.20.00 PM.png\"; "
        + "filename*=UTF-8''Screenshot%206.20.00%E2%80%AFPM.png")
  }

  @Test("What ASCII cannot spell falls back to an underscore")
  func unspellableBecomesUnderscore() {
    #expect(ContentDisposition.asciiFallback(for: "clip 🎉.mov") == "clip _.mov")
  }

  /// A curly quote folds to `"`, which must then be escaped like any other, or the fallback
  /// reopens the bug this type was written for.
  @Test("A curly quote folds to a quote that is still escaped")
  func curlyQuoteIsEscapedAfterFolding() {
    #expect(
      ContentDisposition.header(filename: "a “b”.txt")
        .hasPrefix("attachment; filename=\"a \\\"b\\\".txt\"; filename*="))
  }

  /// Dropped from BOTH parameters, so a recipient preferring `filename*` does not decode a
  /// newline the quoted form left out.
  @Test("Control characters are dropped from both halves of a non-ASCII name")
  func controlCharactersLeaveTheExtendedFormToo() {
    #expect(
      ContentDisposition.header(filename: "ü\r\n.jpg")
        == "attachment; filename=\"u.jpg\"; filename*=UTF-8''%C3%BC.jpg")
  }

  /// The invariant the two halves exist for: whatever the sender named the file, the header is
  /// printable ASCII and a single line, so no recipient has a byte it must guess at.
  @Test(
    "Every header is printable ASCII",
    arguments: [
      "IMG_0001.jpg", "Ünicöde 日本語.jpg", "Screenshot\u{202F}PM.png", "clip 🎉\r\n.mov",
      "e\u{301}.jpg", "a\\\"b\u{0}.txt", "\u{202E}gpj.exe",
    ])
  func headerIsPrintableASCII(name: String) {
    let header = ContentDisposition.header(filename: name)
    #expect(header.utf8.allSatisfy { (0x20...0x7E).contains($0) }, "\(header)")
  }

  /// `;` and `=` are `attr-char`-illegal and must be encoded, or the sender picks where our
  /// parameters end. `urlQueryAllowed` passes all three, which is why this is hand-rolled.
  @Test("Parameter delimiters are percent-encoded in the extended form")
  func delimitersAreEncoded() {
    let encoded = ContentDisposition.extendedForm(of: "a;b=c&d e.jpg")
    #expect(encoded == "a%3Bb%3Dc&d%20e.jpg")
    #expect(!encoded.contains(";"))
    #expect(!encoded.contains("="))
  }

  /// Every byte of a non-ASCII name survives the round trip, which is the point of carrying
  /// the extended form at all.
  @Test("The extended form decodes back to the original name")
  func extendedFormRoundTrips() throws {
    let name = "Ünicöde 日本語.jpg"
    let decoded = try #require(ContentDisposition.extendedForm(of: name).removingPercentEncoding)
    #expect(decoded == name)
  }
}

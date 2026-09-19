//  ContentDispositionTests
//  The download filename is the SENDER's, and it was being pasted into a quoted string.
//
//  `transfer_name` comes out of `chat.db`; for an incoming attachment the name was chosen on
//  somebody else's device. A `"` in it closed the quoted-string early, so
//  `My "quoted" clip.mov` reached a client as `My `. Not a response split — `swift-http-types`
//  legalizes a field value, so CR and LF never reach a socket — but a silently truncated
//  filename is enough to fix.
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

  /// The one case that grows a parameter, and it is already broken without it: `HTTPField.Value`
  /// transcodes through Latin-1, so these bytes reach a client as mojibake whatever we do.
  @Test("A non-ASCII name carries RFC 5987 bytes alongside the quoted fallback")
  func nonASCIIGetsAnExtendedParameter() {
    let header = ContentDisposition.header(filename: "Ünicöde.jpg")
    #expect(header.hasPrefix("attachment; filename=\"Ünicöde.jpg\""))
    #expect(header.hasSuffix("; filename*=UTF-8''%C3%9Cnic%C3%B6de.jpg"))
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

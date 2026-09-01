//  ComplexPasswordTests
//  A password is arbitrary text a person chose, and it has to survive the journey.
//
//  This is the area with the worst history in this project. Three separate ways a correct
//  password was rejected, all of which present to the user as "the server won't accept my
//  password" with nothing in any log to explain it:
//
//    1. **Double decoding.** The socket handshake query is percent-decoded by engine.io and
//       then `decodeURI`'d again by the server, so a password containing a literal `%`
//       followed by two hex digits is decoded twice and corrupted.
//    2. **The two surfaces disagreed.** HTTP went through Koa's query parser (`+` becomes a
//       space) and the socket went through `decodeURI` (it does not), so the same password
//       could work over one and fail over the other.
//    3. **`decodeURI` throws.** A bare `%` is a legal password character and raises a
//       `URIError`.
//
//  Every password below is checked through BOTH surfaces, and the assertion is that they
//  agree — because agreeing is the property, not any particular encoding.

import BBSettings
import Foundation
import Testing

@testable import BBAuth

@Suite("Complex passwords")
struct ComplexPasswordTests {

  /// Deliberately awkward, and every one of them is a password somebody could reasonably
  /// choose. The generated default is 20 alphanumerics, but users type their own.
  static let awkward: [String] = [
    "p@ssw0rd",
    "correct horse battery staple",
    "a+b",
    "100%sure",
    "a%20b",
    "50%",
    "you&me",
    "what?now",
    "hash#tag",
    "slash/es",
    "semi;colon",
    "equals=sign",
    "plus+and space",
    "quote\"and'apostrophe",
    "back\\slash",
    "🔒emoji🔑",
    "ünïcödé",
    "tab\tseparated",
    "<script>alert(1)</script>",
    "'; DROP TABLE message; --",
  ]

  /// Percent-encodes the way a correct client does: everything outside the unreserved set.
  private func encode(_ value: String) -> String {
    value.addingPercentEncoding(
      withAllowedCharacters: CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
      )
    ) ?? value
  }

  // MARK: - Decoding

  @Test("A correctly encoded password round-trips exactly")
  func encodedPasswordsRoundTrip() {
    for password in Self.awkward {
      let query = "password=\(encode(password))"
      let parsed = QueryStringDecoder.parse(query)
      #expect(
        parsed["password"] == password,
        "\(password.debugDescription) came back as \(parsed["password"].debugDescription)"
      )
    }
  }

  @Test("Decoding happens exactly once")
  func decodingIsNotRepeated() {
    // The historical bug. The password is literally `a%20b`; the client encodes it as
    // `a%2520b`. Decoding twice yields `a b` and the user is locked out of their own
    // server with a password they can see is correct.
    let parsed = QueryStringDecoder.parse("password=a%2520b")
    #expect(parsed["password"] == "a%20b")

    // And the layer above must not decode again.
    let normalized = SocketHandshakeScheme.normalize(query: parsed)
    #expect(normalized["password"] == "a%20b")
  }

  @Test("A malformed percent sequence is left alone rather than throwing")
  func malformedSequencesDoNotThrow() {
    // `decodeURI("50%")` raises a URIError. A bare `%` is a perfectly ordinary password
    // character and must not take the request down.
    #expect(QueryStringDecoder.decode("50%") == "50%")
    #expect(QueryStringDecoder.decode("%") == "%")
    #expect(QueryStringDecoder.decode("%zz") == "%zz")
    #expect(QueryStringDecoder.decode("100%sure") == "100%sure")
  }

  @Test("A plus is a space, and an encoded plus is a plus")
  func plusHandlingMatchesKoa() {
    // Koa's query parser turns `+` into a space, so a client that encoded a space that
    // way authenticated against the Node server. A password containing a literal `+` is
    // sent as `%2B`, which is what percent encoding is for.
    #expect(QueryStringDecoder.decode("a+b") == "a b")
    #expect(QueryStringDecoder.decode("a%2Bb") == "a+b")
    // Order matters: converting `+` after percent-decoding would turn a correctly
    // encoded `%2B` into a space and corrupt the password.
    #expect(QueryStringDecoder.decode("a%2B+b") == "a+ b")
  }

  // MARK: - Both surfaces agree

  @Test("HTTP and the socket resolve every password identically")
  func surfacesAgree() async {
    // The property that matters. Not "each uses the right encoding" — that is an
    // implementation detail — but that a password working on one works on the other.
    for password in Self.awkward {
      let query = QueryStringDecoder.parse("password=\(encode(password))")

      let http = PasswordQueryScheme(
        passwordProvider: { PasswordDigest(password) }
      )
      let httpResult = try? await http.authenticate(
        CredentialPresentation(queryParameters: query, path: "/api/v1/ping")
      )

      let socket = SocketHandshakeScheme(
        passwordProvider: { PasswordDigest(password) }
      )
      let socketResult = try? await socket.authenticate(
        CredentialPresentation(queryParameters: query, path: "/socket.io/")
      )

      #expect(httpResult != nil, "HTTP rejected \(password.debugDescription)")
      #expect(socketResult != nil, "the socket rejected \(password.debugDescription)")
    }
  }

  @Test("Every awkward password is accepted through the guid parameter too")
  func guidParameterAlsoWorks() async {
    // `guid` predates there being a password at all and is still what some clients send.
    for password in Self.awkward {
      let query = QueryStringDecoder.parse("guid=\(encode(password))")
      let scheme = SocketHandshakeScheme(
        passwordProvider: { PasswordDigest(password) }
      )
      let result = try? await scheme.authenticate(
        CredentialPresentation(queryParameters: query, path: "/socket.io/")
      )
      #expect(result != nil, "guid rejected \(password.debugDescription)")
    }
  }

  @Test("A password can be sent in a header instead of a URL")
  func headerAvoidsTheURLEntirely() async {
    // The recommendation for anything awkward: a header is not parsed as a URL, so none
    // of the encoding questions arise — and the password stops appearing in tunnel and
    // proxy access logs.
    for password in Self.awkward {
      let encoded = Data(":\(password)".utf8).base64EncodedString()
      let scheme = PasswordQueryScheme(
        passwordProvider: { PasswordDigest(password) }
      )

      let bearer = try? await scheme.authenticate(
        CredentialPresentation(authorizationHeader: "Bearer \(password)")
      )
      #expect(bearer != nil, "Bearer rejected \(password.debugDescription)")

      let basic = try? await scheme.authenticate(
        CredentialPresentation(authorizationHeader: "Basic \(encoded)")
      )
      #expect(basic != nil, "Basic rejected \(password.debugDescription)")
    }
  }

  @Test("A wrong password is still rejected, however awkward")
  func wrongPasswordsAreStillRejected() async {
    // The decoding work must not have made anything permissive.
    let scheme = PasswordQueryScheme(
      passwordProvider: { PasswordDigest("100%sure") }
    )
    // Note what is NOT in this list: `100%25sure`, which is the CORRECT encoding of the
    // password and must succeed. Getting that backwards is how a decoder ends up
    // "fixed" into rejecting valid credentials.
    for candidate in ["100sure", "100% sure", "", "100%SURE", "100%%sure"] {
      let query = QueryStringDecoder.parse("password=\(candidate)")
      let result = try? await scheme.authenticate(
        CredentialPresentation(queryParameters: query)
      )
      #expect(result == nil, "\(candidate.debugDescription) was accepted")
    }
  }

  @Test("Trailing whitespace is tolerated on the supplied value")
  func trailingWhitespaceIsTolerated() async {
    // Clients have shipped trailing whitespace, matching `safeTrim`. Tightening this
    // would lock them out.
    let scheme = PasswordQueryScheme(
      passwordProvider: { PasswordDigest("hunter2hunter2") }
    )
    let result = try? await scheme.authenticate(
      CredentialPresentation(queryParameters: ["password": "  hunter2hunter2 \n"])
    )
    #expect(result != nil)
  }
}

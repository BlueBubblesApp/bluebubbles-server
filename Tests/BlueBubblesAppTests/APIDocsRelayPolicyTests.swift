//  APIDocsRelayPolicyTests
//  The rules the API reference's request relay is held to.
//
//  The relay is the one place in this app that performs an HTTP request on behalf of a web
//  page, so every one of these is a boundary rather than a formatting preference. Asserted
//  against strings, because the alternative is a `WKWebView`, a run loop and a live server.

import BBHTTPAPI
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("API docs relay policy")
struct APIDocsRelayPolicyTests {

  // MARK: Origins

  @Test("The default port is made explicit, so the two spellings of one origin compare equal")
  func defaultPortsAreExplicit() {
    #expect(
      APIDocsRelayPolicy.origin(of: URL(string: "http://example.com")!) == "http://example.com:80")
    #expect(
      APIDocsRelayPolicy.origin(of: URL(string: "http://example.com:80/a/b")!)
        == "http://example.com:80")
    #expect(
      APIDocsRelayPolicy.origin(of: URL(string: "https://example.com")!)
        == "https://example.com:443")
  }

  @Test("Host and scheme are compared case-insensitively")
  func hostAndSchemeAreLowercased() {
    #expect(
      APIDocsRelayPolicy.origin(of: URL(string: "HTTP://LocalHost:1234/")!)
        == "http://localhost:1234")
  }

  @Test("Anything that is not an absolute http(s) URL has no origin, so it cannot be allowed")
  func nonHTTPHasNoOrigin() {
    for spelling in [
      "file:///etc/passwd", "data:text/html,x", "ws://localhost:1234", "/api/v1/ping",
    ] {
      let url = URL(string: spelling)!
      #expect(APIDocsRelayPolicy.origin(of: url) == nil, "\(spelling) should have no origin")
      #expect(!APIDocsRelayPolicy.isAllowed(url, origins: ["http://localhost:1234"]))
    }
  }

  @Test("Loopback is allowed at the listening port even when the server advertises a tunnel")
  func loopbackIsAlwaysAllowed() {
    let origins = APIDocsRelayPolicy.allowedOrigins(
      serverURL: "https://tunnel.example.com", loopbackPort: 1234)

    #expect(origins.contains("https://tunnel.example.com:443"))
    #expect(origins.contains("http://localhost:1234"))
    #expect(origins.contains("http://127.0.0.1:1234"))
    // `URL.host` drops the brackets, which is why both sides are normalized by the same
    // function rather than built by interpolation.
    #expect(origins.contains("http://::1:1234"))
  }

  @Test("A port the server does not listen on is a different origin")
  func portIsPartOfTheOrigin() {
    let origins = APIDocsRelayPolicy.allowedOrigins(
      serverURL: "http://localhost:1234", loopbackPort: 1234)

    #expect(
      APIDocsRelayPolicy.isAllowed(
        URL(string: "http://localhost:1234/api/v1/ping")!, origins: origins))
    #expect(
      !APIDocsRelayPolicy.isAllowed(
        URL(string: "http://localhost:9999/api/v1/ping")!, origins: origins))
    #expect(
      !APIDocsRelayPolicy.isAllowed(
        URL(string: "https://localhost:1234/api/v1/ping")!, origins: origins))
    #expect(
      !APIDocsRelayPolicy.isAllowed(
        URL(string: "http://evil.example.com/api/v1/ping")!, origins: origins))
  }

  @Test("A server URL that does not parse leaves loopback and nothing else")
  func unparseableServerURLIsDropped() {
    let origins = APIDocsRelayPolicy.allowedOrigins(serverURL: "", loopbackPort: 1234)
    #expect(
      origins == APIDocsRelayPolicy.allowedOrigins(serverURL: "not a url", loopbackPort: 1234))
    #expect(origins.contains("http://localhost:1234"))
  }

  // MARK: Headers

  @Test("The forwarding headers the CORS middleware refuses are refused here too")
  func forbiddenHeadersTrackTheMiddleware() {
    // The drift check: a native relay is not behind a browser or behind `CORSMiddleware`, so
    // an entry added to one list and not the other is a header a page could assert. The
    // entry that matters is `x-forwarded-for`, which loopback is trusted to have set.
    #expect(APIDocsRelayPolicy.forbiddenRequestHeaders.isSuperset(of: CORSHeaderPolicy.forbidden))
    #expect(APIDocsRelayPolicy.forbiddenRequestHeaders.contains("x-forwarded-for"))
  }

  @Test("Forwarding headers are stripped whatever their case; real credentials are not")
  func requestHeadersAreSanitized() {
    let sanitized = APIDocsRelayPolicy.sanitized(requestHeaders: [
      ("Authorization", "Bearer hunter2"),
      ("content-type", "application/json"),
      ("X-Forwarded-For", "10.0.0.1"),
      ("X-REAL-IP", "10.0.0.1"),
      ("Host", "elsewhere.example.com"),
      ("Content-Length", "12"),
    ])

    #expect(sanitized.map(\.name) == ["Authorization", "content-type"])
  }

  @Test("Response headers describing bytes the page never sees are dropped")
  func responseHeadersAreSanitized() {
    // URLSession undoes content encoding on its own, so forwarding the pair would have the
    // console print a length and an encoding for a body that has neither.
    let sanitized = APIDocsRelayPolicy.sanitized(responseHeaders: [
      ("Content-Type", "application/json"),
      ("Content-Encoding", "gzip"),
      ("content-length", "204"),
      ("X-Request-Id", "abc"),
    ])

    #expect(sanitized.map(\.name) == ["Content-Type", "X-Request-Id"])
  }

  // MARK: Prefill

  @Test("The prefill is the shape Scalar reads")
  func prefillShape() throws {
    let json = APIDocsPagePrefill.authentication(password: "hunter2")
    let decoded =
      try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

    #expect(decoded["preferredSecurityScheme"] as? String == "passwordQuery")
    let schemes = try #require(decoded["securitySchemes"] as? [String: Any])
    let query = try #require(schemes["passwordQuery"] as? [String: Any])
    #expect(query["value"] as? String == "hunter2")
  }

  @Test("A password containing quotes cannot end the statement it is injected into")
  func prefillEscapesQuotes() throws {
    let json = APIDocsPagePrefill.authentication(password: "a\"b\\c\nd")
    // Injected as `window.__BB_PREFILL_AUTH__ = <this>;`, so an unescaped quote would be a
    // syntax error at best and an injection at worst.
    let decoded =
      try #require(
        JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let schemes = try #require(decoded["securitySchemes"] as? [String: Any])
    let query = try #require(schemes["passwordQuery"] as? [String: Any])
    #expect(query["value"] as? String == "a\"b\\c\nd")
  }

  @Test("No password prefills nothing, rather than an empty credential that reads as broken")
  func prefillIsNullWithoutAPassword() {
    #expect(APIDocsPagePrefill.authentication(password: "") == "null")
  }
}

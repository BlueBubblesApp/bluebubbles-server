//  SocketCORSPolicyTests
//  The socket is on the HTTP listener's port, so it answers to the HTTP listener's CORS policy.
//
//  Two things this holds, and both were separately wrong.
//
//  **The origin.** `SocketIOTransport` sent a hardcoded `Access-Control-Allow-Origin: *` on
//  every response and every preflight. An operator who narrowed `cors_allowed_origin` would
//  have restricted the REST API and left the event stream — the half a browser client actually
//  streams from — answering every page on the internet.
//
//  **The headers.** It also sent `Access-Control-Allow-Headers: *`, which tells a browser a
//  cross-origin request may carry ANY header, `X-Forwarded-For` included. Loopback is a trusted
//  proxy by default, so a page in the operator's browser could have chosen which address its
//  failed logins were counted against. The REST side closed exactly this and the socket, same
//  listener and same port, went on reflecting the wildcard.

import BBHTTPAPI
import Foundation
import Testing

@testable import BBSocketIO
@testable import BlueBubblesServerCore

@Suite("Socket CORS policy")
struct SocketCORSPolicyTests {

  /// The socket transcribes the forbidden set rather than importing it, so that BBSocketIO
  /// keeps its dependency list. This is what keeps the transcription honest: a header added to
  /// `CORSHeaderPolicy` and not here fails, rather than being quietly assertable on one
  /// transport and not the other.
  @Test("Both transports refuse the same headers")
  func forbiddenSetsAgree() {
    let requested = CORSHeaderPolicy.forbidden.sorted().joined(separator: ", ")
    // Every forbidden header, asked for at once: both must reflect none of them.
    #expect(SocketIOTransport.allowedRequestHeaders(requested: requested) == "")
    #expect(CORSHeaderPolicy.allowedHeaders(requested: requested) == "")

    // And both let an ordinary one through, so the assertion above is not passing because
    // everything is refused.
    let mixed = "Authorization, X-Forwarded-For, Content-Type"
    #expect(
      SocketIOTransport.allowedRequestHeaders(requested: mixed) == "Authorization, Content-Type")
    #expect(
      SocketIOTransport.allowedRequestHeaders(requested: mixed)
        == CORSHeaderPolicy.allowedHeaders(requested: mixed))
  }

  /// The default: what this transport has always sent, on a server nobody has configured.
  @Test("An unconfigured server answers the socket with a wildcard")
  func defaultIsWildcard() {
    let headers = HTTPService.socketCORSHeaders(policy: CORSPolicy(configured: "*"))(
      "https://anywhere.example.com")
    #expect(headers[.accessControlAllowOrigin] == "*")
    #expect(headers[.vary] == nil)
    // The methods line is unchanged either way; it is not part of the origin decision.
    #expect(headers[.accessControlAllowMethods] == "GET, POST, OPTIONS")
  }

  @Test("A narrowed origin reaches the socket too")
  func narrowedOriginReachesTheSocket() {
    let headers = HTTPService.socketCORSHeaders(
      policy: CORSPolicy(configured: "https://app.example.com"))

    let allowed = headers("https://app.example.com")
    #expect(allowed[.accessControlAllowOrigin] == "https://app.example.com")
    #expect(allowed[.vary]?.contains("Origin") == true)

    // The wildcard `defaultCORSHeaders` carries must not survive into a narrowed answer.
    let refused = headers("https://evil.example.com")
    #expect(refused[.accessControlAllowOrigin] == nil)
    #expect(refused[.vary]?.contains("Origin") == true)
  }

  /// A non-browser client, which is every client that is not a web page: it sends no `Origin`
  /// and nothing about its request changes.
  @Test("A socket client that sends no Origin gets no allow header and is otherwise unaffected")
  func nonBrowserSocketClient() {
    let headers = HTTPService.socketCORSHeaders(
      policy: CORSPolicy(configured: "https://app.example.com"))(nil)
    #expect(headers[.accessControlAllowOrigin] == nil)
    #expect(headers[.accessControlAllowMethods] == "GET, POST, OPTIONS")
  }
}

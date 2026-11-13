//  CORSPolicyTests
//  Which browser origins may read a response, and the two properties that must not move.
//
//  The default has to stay byte-identical to what the reference sends, because it is what
//  every shipped client has seen and what the recorded fixtures hold. And a narrowed policy has
//  to say `Vary: Origin`, or a cache in front of this server hands one origin's allowance to
//  another — which is the failure that turns an allowlist into no allowlist at all.
//
//  Worth restating, because the tests below look like they are refusing clients and are not:
//  CORS is enforced by browsers and by nothing else. Nothing here can refuse the app, `curl`,
//  or another server, because none of them sends `Origin` or reads the answer.

import Testing

@testable import BBHTTPAPI

@Suite("CORS policy")
struct CORSPolicyTests {

  // MARK: - The default

  @Test("The default allows every origin, exactly as the reference does")
  func wildcardIsTheDefault() {
    let policy = CORSPolicy(configured: "*")
    #expect(policy.isWildcard)
    #expect(policy.allowOriginHeader(for: "https://anything.example.com") == "*")
    // No Origin at all: a native client, which gets the same header it always got.
    #expect(policy.allowOriginHeader(for: nil) == "*")
    // And no `Vary`, so the response is cacheable exactly as it is today.
    #expect(!policy.variesByOrigin)
  }

  /// A field someone cleared by selecting and deleting must not lock every browser out of a
  /// server they can no longer reach to fix it.
  @Test("An empty or separator-only value is the wildcard, not a lockout")
  func emptyIsWildcard() {
    for configured in ["", "   ", "\n", ",", " , "] {
      #expect(
        CORSPolicy(configured: configured).isWildcard,
        "\(configured.debugDescription) should be the wildcard")
    }
  }

  // MARK: - An allowlist

  @Test("A listed origin is echoed back and an unlisted one gets no header")
  func allowlistEchoes() {
    let policy = CORSPolicy(configured: "https://app.example.com, http://localhost:3000")
    #expect(policy.allowOriginHeader(for: "https://app.example.com") == "https://app.example.com")
    #expect(policy.allowOriginHeader(for: "http://localhost:3000") == "http://localhost:3000")
    #expect(policy.allowOriginHeader(for: "https://evil.example.com") == nil)
    // A request with no Origin is not a browser request; there is nothing to allow.
    #expect(policy.allowOriginHeader(for: nil) == nil)
  }

  /// The header may carry ONE origin or `*`, never a list — so an allowlist can only work by
  /// echoing, and echoing can only be cached per origin.
  @Test("An allowlist varies by origin")
  func allowlistVaries() {
    #expect(CORSPolicy(configured: "https://app.example.com").variesByOrigin)
    #expect(!CORSPolicy(configured: "*").variesByOrigin)
  }

  /// An operator types what they have in front of them; a browser sends the canonical form.
  @Test("Case and a trailing slash do not make a different origin")
  func matchingIsForgiving() {
    let policy = CORSPolicy(configured: "https://App.Example.com/")
    #expect(policy.allowOriginHeader(for: "https://app.example.com") == "https://app.example.com")
  }

  /// The CLIENT's spelling is echoed, never our normalized one: a browser compares the header
  /// against the origin it sent, on a comparison we do not control.
  @Test("The echo is the origin the client sent")
  func echoesTheClientsSpelling() {
    let policy = CORSPolicy(configured: "https://app.example.com")
    #expect(policy.allowOriginHeader(for: "https://APP.example.com") == "https://APP.example.com")
  }

  // MARK: - Headers

  /// Unchanged by the origin work, and pinned here because the two policies are now read
  /// together: a browser may never assert a forwarding header, whatever origin it is on.
  @Test("Forwarding headers are never reflected, whatever the origin policy")
  func forwardingHeadersRefused() {
    let reflected = CORSHeaderPolicy.allowedHeaders(
      requested: "Authorization, X-Forwarded-For, Content-Type, x-real-ip")
    #expect(reflected == "Authorization, Content-Type")
  }
}

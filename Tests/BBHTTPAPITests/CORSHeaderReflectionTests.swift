//  CORSHeaderReflectionTests
//  A browser may not assert a header this server believes.
//
//  The origin policy is deliberately `*`, matching the reference, and that is recorded as a
//  decision. `Access-Control-Allow-Headers: *` looked like the same decision and was not: it
//  tells a browser that a cross-origin request may carry ANY header, and one of the headers
//  this server reads is `X-Forwarded-For`.
//
//  That matters because loopback is a trusted proxy by default — the bundled tunnels all run
//  on this machine and connect over it — so a page open in the operator's browser could send
//  a failed login carrying a forwarding header of its choosing, and have the failure
//  attributed to an address it picked. The consequences are blocking arbitrary third parties
//  and growing a map whose keys the attacker then supplies.
//
//  The fix is not to narrow the origin, which would lock real clients out. It is to reflect
//  the headers actually asked for and refuse the handful that a reverse proxy sets and a
//  caller must not.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Testing

@testable import BBHTTPAPI

@Suite("CORS header reflection")
struct CORSHeaderReflectionTests {

  private typealias CORS = CORSHeaderPolicy

  @Test("A forwarding header is never allowed, however it is spelled")
  func forwardingHeadersAreRefused() {
    for header in ["X-Forwarded-For", "x-forwarded-for", "X-Real-IP", "Forwarded"] {
      let allowed = CORS.allowedHeaders(requested: header)
      #expect(
        allowed.isEmpty,
        Comment(rawValue: "`\(header)` was allowed, so a browser can choose its own address"))
    }
  }

  @Test("The headers a real client sends are reflected untouched")
  func ordinaryHeadersSurvive() {
    let allowed = CORS.allowedHeaders(requested: "Authorization, Content-Type, Accept")
    #expect(allowed == "Authorization, Content-Type, Accept")
  }

  @Test("A forwarding header mixed in with real ones is the only one dropped")
  func mixedRequestKeepsTheRest() {
    let allowed = CORS.allowedHeaders(requested: "Authorization, X-Forwarded-For, Accept")
    #expect(allowed == "Authorization, Accept")
  }

  @Test("Asking for nothing is answered with nothing, not with everything")
  func emptyMeansEmpty() {
    let nothing: String? = nil
    #expect(CORS.allowedHeaders(requested: nothing).isEmpty)
    #expect(CORS.allowedHeaders(requested: "").isEmpty)
    #expect(CORS.allowedHeaders(requested: "   ").isEmpty)
  }
}

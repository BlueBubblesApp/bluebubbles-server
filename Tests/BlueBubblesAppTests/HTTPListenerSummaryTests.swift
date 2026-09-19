//  HTTPListenerSummaryTests
//  The sentence describing where the server listens.
//
//  Someone reading this line is deciding whether their server is reachable from the network,
//  so the two groupings are the whole point: four spellings mean "everything" and two mean
//  "this Mac only". The empty one is the trap — an unset bind address is not "nowhere".

import Testing

@testable import BlueBubblesApp

@Suite("HTTP listener summary")
struct HTTPListenerSummaryTests {

  /// The default install has NO stored bind address, and that means every network, not an
  /// address of "". Read as a literal it would have printed "Listening on ,".
  @Test(
    "Every wildcard spelling, the empty one included, reads as every network",
    arguments: ["", "0.0.0.0", "::"])
  func wildcards(address: String) {
    let line = HTTPListenerSummary.summary(bindAddress: address, servesHTTPS: false)
    #expect(line.hasPrefix("Listening on every network on this Mac"))
  }

  @Test("Both loopback spellings read as loopback only", arguments: ["127.0.0.1", "::1"])
  func loopback(address: String) {
    #expect(
      HTTPListenerSummary.summary(bindAddress: address, servesHTTPS: false)
        .hasPrefix("Listening on loopback only"))
  }

  @Test("Any other address is named as itself")
  func specificAddress() {
    #expect(
      HTTPListenerSummary.summary(bindAddress: "192.168.1.50", servesHTTPS: false)
        .hasPrefix("Listening on 192.168.1.50"))
  }

  @Test("The scheme is stated either way, and the sentence is a sentence")
  func scheme() {
    #expect(
      HTTPListenerSummary.summary(bindAddress: "", servesHTTPS: true).hasSuffix("over HTTPS."))
    #expect(
      HTTPListenerSummary.summary(bindAddress: "", servesHTTPS: false)
        .hasSuffix("over plain HTTP."))
  }
}

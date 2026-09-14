//  UpdaterPolicyTests
//  A build without a signing key never starts Sparkle.
//
//  The dev bundle blanks `SUPublicEDKey` and a release build substitutes it; the decision
//  between "run the updater" and "say why not" is the one that matters, because getting it
//  wrong is either an alert on every dev launch or an updater that trusts an unsigned feed.

import Testing

@testable import BlueBubblesApp

@Suite("Updater policy")
struct UpdaterPolicyTests {

  @Test("A blank, whitespace or missing key means no updater, with a reason")
  func blankKeyIsUnavailable() {
    for key in [nil, "", "   ", "\n"] {
      let availability = UpdaterPolicy.availability(publicKey: key)
      guard case .unavailable(let reason) = availability else {
        Issue.record("expected unavailable for \(String(describing: key))")
        continue
      }
      #expect(reason.contains("cannot verify"))
    }
  }

  @Test("A substituted key means the updater runs")
  func presentKeyIsAvailable() {
    // Any 32 bytes are a valid Ed25519 public key; what is asserted is presence, not
    // validity, because Sparkle checks validity itself when it starts.
    let key = "pTHMr7hzTzvcRXxU2kZTPhrMFqWUE8Yqt6yKfXt5ZwM="
    #expect(UpdaterPolicy.availability(publicKey: key) == .available)
  }
}

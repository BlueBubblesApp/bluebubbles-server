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

  /// A scheduled relaunch starts the server, so it waits only while the server runs: armed
  /// after a stop, it undid the stop at the install hour. And turning the switch off disarms
  /// the update already waiting, which used to fire anyway at its hour, unless a client
  /// asked for a window: that request is consent of its own.
  @Test("The scheduled relaunch is armed only with a download, a running server and a reason")
  func scheduledInstallArming() {
    func arms(
      downloaded: Bool = true, running: Bool = true, automatic: Bool = false,
      requested: Bool = false
    ) -> Bool {
      UpdaterPolicy.armsScheduledInstall(
        hasDownloadedUpdate: downloaded, isServerRunning: running,
        installsAutomatically: automatic, hasRequestedWindow: requested)
    }
    #expect(arms(automatic: true))
    #expect(arms(requested: true))
    #expect(arms(automatic: true, requested: true))
    // Nothing to keep: the update installs on quit, as Sparkle does by default.
    #expect(!arms())
    // A stopped server is never relaunched into, whoever asked.
    #expect(!arms(running: false, automatic: true))
    #expect(!arms(running: false, requested: true))
    // Nothing downloaded, nothing to relaunch into.
    #expect(!arms(downloaded: false, automatic: true, requested: true))
  }
}

//  OnboardingPasswordTests
//  Onboarding cannot finish without a usable server password.
//
//  This is a gate rather than a nag for a specific reason: an unset password does not leave
//  the server open, it leaves it BROKEN. `PasswordScheme.authenticate` throws
//  `serverMisconfigured("No server password is configured")` for every authenticated
//  request, so a user who walked past the connection step got an app that looked installed,
//  showed no error on any screen, and rejected every client with a message about the
//  Keychain. Nothing downstream can recover from that; only the step that skipped it can.
//
//  What is asserted here is the PROPERTY the onboarding gate depends on, not the SwiftUI
//  view: the policy onboarding checks against and the policy the store enforces on write
//  must accept exactly the same passwords. If they drift, onboarding either dead-ends —
//  refusing to advance on something the store would have taken — or waves through something
//  the store then rejects, leaving the user in the failure this gate exists to prevent.

import BBSettings
import Foundation
import Testing

@Suite("Onboarding requires a usable password")
struct OnboardingPasswordTests {

  /// What `OnboardingView.passwordRejection` does, expressed where a test can reach it.
  private func onboardingAccepts(_ candidate: String) -> Bool {
    guard !candidate.isEmpty else { return false }
    do {
      try PasswordPolicy().validate(candidate)
      return true
    } catch {
      return false
    }
  }

  private func storeAccepts(_ candidate: String) -> Bool {
    do {
      try Settings.password.validate?(candidate)
      return true
    } catch {
      return false
    }
  }

  @Test("An empty password is refused")
  func emptyIsRefused() {
    // The store EXEMPTS empty — it is the shipped default, and rejecting it would make a
    // fresh install unconfigurable. Onboarding must not inherit that exemption: "the
    // default is allowed to be empty" and "you may finish setup with it empty" are
    // different claims, and conflating them is the bug.
    #expect(!onboardingAccepts(""))
    #expect(storeAccepts(""), "the store still exempts the shipped default")
  }

  @Test("A weak password is refused", arguments: ["1", "short", "password", "12345678"])
  func weakIsRefused(candidate: String) {
    #expect(!onboardingAccepts(candidate))
  }

  @Test("A generated password is accepted")
  func generatedIsAccepted() {
    // The step offers Generate as the fastest way past a rejection. If the generator
    // produced something the policy refused, that button would be a trap.
    for _ in 0..<32 {
      let generated = PasswordPolicy.generate()
      #expect(onboardingAccepts(generated), "generator produced a rejected password")
    }
  }

  @Test("Onboarding and the store agree on every candidate that is not empty")
  func gatesAgree() {
    // The drift check. Empty is the one deliberate disagreement and is excluded.
    let candidates = [
      "short", "password", "12345678", "aaaaaaaaaaaaaaaa",
      "correct-horse-battery-staple", PasswordPolicy.generate(),
      "Tr0ub4dor&3", "a-reasonably-long-and-varied-passphrase-42",
    ]
    for candidate in candidates {
      let onboarding = onboardingAccepts(candidate)
      let store = storeAccepts(candidate)
      #expect(onboarding == store, "disagreement on \(candidate)")
    }
  }

  @Test("A rejection reads as a sentence, however it is caught")
  func rejectionsAreReadableThroughAGenericCatch() {
    // The failure this pins: `validate` throws `PasswordPolicy.Rejection` and NOT a
    // `SettingsError`, so every generic `catch` fell through to `String(describing:)` and
    // rendered the associated values. What reached the settings screen was
    // `tooPredictable(bits: 34.2, minimum: 60.0)` — the number the check measures, which is
    // not a thing the reader can do anything about.
    let rejections: [PasswordPolicy.Rejection] = [
      .tooShort(minimum: 8), .tooPredictable(bits: 34.2, minimum: 60), .forbidden,
    ]
    for rejection in rejections {
      let throughGenericCatch = (rejection as any Error).localizedDescription
      #expect(throughGenericCatch == rejection.userMessage)

      // No internals, in either form.
      for message in [throughGenericCatch, rejection.userMessage] {
        #expect(!message.contains("bits"), "leaks entropy internals: \(message)")
        #expect(!message.contains("minimum:"), "leaks a label: \(message)")
        #expect(!message.contains("tooPredictable"), "leaks the case name: \(message)")
        #expect(!message.contains("34.2"), "leaks a measured value: \(message)")
        #expect(message.hasSuffix("."), "not a sentence: \(message)")
      }
    }
  }

  @Test("Every rejection says what to do next")
  func rejectionsAreActionable() {
    // A message that only says "no" leaves the user guessing which of length, variety or
    // commonness was the problem.
    #expect(PasswordPolicy.Rejection.tooShort(minimum: 8).userMessage.contains("8"))
    #expect(
      PasswordPolicy.Rejection.tooPredictable(bits: 1, minimum: 60).userMessage
        .localizedCaseInsensitiveContains("generate"))
    #expect(
      PasswordPolicy.Rejection.forbidden.userMessage
        .localizedCaseInsensitiveContains("pick something else"))
  }
}

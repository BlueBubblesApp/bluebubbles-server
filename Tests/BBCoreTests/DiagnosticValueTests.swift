//  DiagnosticValueTests
//  Redaction is structural, and this is the test that says so.
//
//  `DiagnosticValue.secret` carries NO payload; there is no associated value to print. That
//  is the whole design: redaction cannot be defeated by a `switch` that forgets to handle the
//  secret case, because there is nothing for the default branch to render. A `secret` that
//  wrapped its value and relied on every renderer remembering to mask it would be one
//  forgotten branch away from writing a password into a diagnostics bundle.
//
//  So the assertion is that the mask IS the value, next to a non-secret that renders in full.
//  Sibling rules live in `DiagnosticTextTests` (what an error says to a person) and
//  `SeverityTests` (what gets badged).

import Testing

@testable import BBCore

@Suite("DiagnosticValue redaction")
struct DiagnosticValueTests {
  /// Redaction is structural: a secret cannot be printed by forgetting to handle it,
  /// because there is no payload to print.
  @Test("Secrets never render their value")
  func secretsAreRedacted() {
    #expect(DiagnosticValue.secret.redactedDescription == "••••")
    #expect(DiagnosticValue.string("hunter2").redactedDescription == "hunter2")
  }
}

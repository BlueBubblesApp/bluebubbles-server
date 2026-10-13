//  SettingsWritePolicyTests
//  A settings write is never `try?`.
//
//  A write that fails silently leaves the server believing something it did not store. The
//  case that prompted this: adopting a TLS certificate recorded its origin and expiry with
//  `try?`, and a refusal there left a self-signed certificate that nothing would ever renew,
//  with nothing in any log to say so. A write whose failure is genuinely not the caller's
//  problem goes through `trySet`, which logs the refusal; anything else propagates or is
//  caught and said.
//
//  The two exceptions are rollbacks: restoring a secret's previous value inside the handler
//  that is already reporting the failure that made the rollback necessary.

import BBTestSupport
import Foundation
import Testing

@Suite("Settings writes")
struct SettingsWritePolicyTests {

  private static let allowed: [String: String] = [
    "Sources/BBSettings/SettingsStore.swift":
      "`rollBackSecrets` undoes a failed batch the caller is already reporting",
    "Sources/BBSettings/LegacyConfigMigration.swift":
      "`rollBackSecrets` undoes a failed import the caller is already reporting",
  ]

  @Test("No settings or secret write is discarded with try?")
  func writesAreNotDiscarded() throws {
    let files = try SourceScanner.swiftFiles(under: "Sources", minimum: 100)
      .filter { Self.allowed[$0.path] == nil }
    let discarded = try Regex(
      #"try\?\s*(await\s+)?[A-Za-z_][A-Za-z0-9_.()]*\.(set|remove|setSecret)\("#)
    let offences = SourceScanner.offences(in: files) { _, line in
      line.code.contains(discarded)
    }
    #expect(
      offences.isEmpty,
      Comment(
        rawValue: "a settings write discarded with try?; propagate it, catch and say it, or "
          + "use `trySet`, which logs the refusal:\n" + offences.report))
  }
}

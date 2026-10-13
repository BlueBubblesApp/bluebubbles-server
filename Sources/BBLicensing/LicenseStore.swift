//  LicenseStore
//  The only thing that touches persisted license state.
//
//  Takes the settings store DIRECTLY rather than a `ScopedSettings`, and that is deliberate
//  rather than a shortcut: `license_key` is a secret, and a secret is not declarable by any
//  service — `ManifestValidator` refuses a manifest naming one and `checkRead` refuses it
//  before it consults entitlements at all. So this type is built by the composition root,
//  which has unrestricted access, and the SERVICE never holds it. What the service gets is
//  `LicenseRuntime`, which exposes whether a key exists and can exchange one, and never hands
//  the key over.
//
//  Reads are cheap and there is no cache here on purpose. The hot path — a gated request
//  asking for the current status — reads `LicenseRuntime`'s in-memory value and never reaches
//  this type at all.

import BBLicense
import BBSettings
import Foundation

public struct LicenseStore: Sendable {

  private let settings: SettingsStore

  public init(settings: SettingsStore) {
    self.settings = settings
  }

  /// Whether a key has been entered. The only question about the key this type answers to
  /// anyone outside the composition root.
  public func hasKey() async -> Bool {
    await !settings.get(Settings.licenseKey).isEmpty
  }

  /// The key itself. Used for exactly one thing — handing it to the issuer — and never
  /// returned past `LicenseRuntime`.
  func key() async -> String {
    await settings.get(Settings.licenseKey)
  }

  /// The persisted state, decoded. A token that no longer verifies is treated as absent
  /// rather than as an error: it is a cache, the next refresh will replace it, and refusing
  /// to start over a corrupt cache would be worse than re-fetching.
  public func load(verifier: @Sendable (String) throws -> EntitlementToken) async -> LicenseState {
    let raw = await settings.get(Settings.licenseToken)
    let lastCheck = await settings.get(Settings.licenseLastCheck)
    let revoked = await settings.get(Settings.licenseRevoked)

    let token = raw.isEmpty ? nil : try? verifier(raw)
    return LicenseState(
      token: token,
      lastRefresh: lastCheck > 0 ? Date(timeIntervalSince1970: TimeInterval(lastCheck)) : nil,
      isRevoked: revoked,
      // Whether one EXISTS, never the key itself. It is what lets the evaluator tell "no
      // subscription" from "a subscription we have not managed to confirm".
      hasKey: await hasKey()
    )
  }

  /// Records a successful exchange. One batch, so a crash between the token and its timestamp
  /// cannot leave a fresh token that looks stale.
  public func store(token: String, checkedAt: Date) async throws {
    _ = try await settings.write { batch in
      try batch.set(Settings.licenseToken, to: token)
      try batch.set(Settings.licenseLastCheck, to: Int(checkedAt.timeIntervalSince1970))
      try batch.set(Settings.licenseRevoked, to: false)
    }
  }

  /// Records that the issuer says this license is disabled.
  ///
  /// The token is KEPT. It is still the evidence of what was bought, `isRevoked` is what
  /// decides access, and keeping it means the app can still say which license was revoked
  /// rather than showing an empty page.
  public func markRevoked() async throws {
    _ = try await settings.write { batch in
      try batch.set(Settings.licenseRevoked, to: true)
    }
  }

  /// Forgets everything. For a user removing their license from this Mac.
  public func clear() async throws {
    _ = try await settings.write { batch in
      try batch.set(Settings.licenseKey, to: "")
      try batch.set(Settings.licenseToken, to: "")
      try batch.set(Settings.licenseLastCheck, to: 0)
      try batch.set(Settings.licenseRevoked, to: false)
    }
  }
}

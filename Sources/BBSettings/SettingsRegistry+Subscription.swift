//  SettingsRegistry+Subscription
//  The licence key, the token exchanged for it, and the bookkeeping of the daily check.
//
//  Its own file so the one secret no service may declare a read of is read beside the rows
//  that depend on it. The lists that make a setting exist (`Settings.renderable`,
//  `Settings.hidden`) stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  // MARK: - Subscription

  /// The license key, as bought.
  ///
  /// SECRET, so it goes to the Keychain, renders as `••••` in diagnostics, and — this is the
  /// part that shapes the design — **no service may declare a read of it**.
  /// `ManifestValidator` refuses a manifest naming a secret, and `ScopedSettings.checkRead`
  /// refuses it before it looks at entitlements at all. So the licensing service never holds
  /// the key: it asks the host whether one is present and asks the host to exchange it, which
  /// is the same shape `authenticateRequests` exists for.
  ///
  /// Not in `renderable`: there is no generated settings-form row for it. The Subscription
  /// page writes it, and the command line can with `--set license_key=…`.
  public static let licenseKey = Setting<String>(
    "license_key", default: "", isSecret: true)

  /// The signed entitlement token last received.
  ///
  /// Deliberately NOT secret, and that is not an oversight. The token is *signed*: it proves
  /// what was bought and is useless on another machine because of the `machine` claim.
  /// Marking it secret would push it into the Keychain and make it unreadable by the
  /// evaluator without a prompt, for no gain.
  ///
  /// Confidential all the same, because its claims name the licence's subject (the vendor's
  /// customer identifier) and this Mac's fingerprint, and the daily refresh rewrites it: an
  /// audit record of that write would carry both off the machine once a day. The record says
  /// the token changed and withholds the value.
  public static let licenseToken = Setting<String>(
    "license_token", default: "", isConfidential: true)

  /// Epoch seconds of the last SUCCESSFUL refresh. Drives the warning alerts, and the
  /// `since` a lapsed status reports. Zero means "never".
  public static let licenseLastCheck = Setting<Int>("license_last_check", default: 0)

  /// Set when the issuer reports the license disabled — refund, chargeback, revocation.
  ///
  /// Stored rather than derived because nothing about a token can imply it: it is a fact from
  /// outside, and it has to survive a restart that happens before the next refresh.
  /// Spelled `license_disabled` rather than `license_revoked` because the latter is the WIRE
  /// value of `LicenseRefusal.revoked`, and a settings key that reads identically to a
  /// client-facing reason string is two different things wearing one name.
  public static let licenseRevoked = Setting<Bool>("license_disabled", default: false)

  /// Where a license key is exchanged for a token.
  ///
  /// A setting so a test, or someone running their own issuer, can point it elsewhere.
  /// `.composition` because the client is built once when the service starts.
  public static let licenseEndpoint = Setting<String>(
    "license_endpoint", default: "https://bluebubbles-license.zlshames.workers.dev",
    application: .composition,
    // Internal, so it never renders — but it still needs a LABEL, because a
    // composition-time setting that changes raises the "restart to apply" notice and that
    // notice names the settings that moved. Without one it would name the raw storage key.
    presentation: .init(
      label: "License Service",
      help: "Where a license key is exchanged for an entitlement.",
      section: .advanced, control: .textField, isInternal: true))
}

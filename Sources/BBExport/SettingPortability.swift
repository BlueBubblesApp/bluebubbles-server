//  SettingPortability
//  Which settings may cross from one server to another, and which describe the server they
//  came from and must not.
//
//  **The failing case is not "a setting is missing", it is "a server lies about itself".**
//  `server_address` is an OUTPUT: the connection method writes it on every reconnect, and a
//  value imported from somewhere else is an address clients are told to use and nothing is
//  listening on — until the next publish overwrites it, which on a LAN install may be never
//  if the method is not running. `tls_certificate_expires_at` describes material that may
//  not be in the archive at all. The `migration_*` keys record this MAC's adoption of an
//  Electron install, so importing them tells a server it has already adopted something it
//  has never seen — and the adoption is what would have brought the settings across.
//
//  **Stated as a classification with a test, not as a filter written once.** Every setting
//  is either portable or named here with a reason; `SettingPortabilityTests` fails when a
//  new one is neither. A filter would silently start exporting the next `server_address`
//  somebody adds, and the failure would be invisible until somebody restored a backup onto
//  a second Mac and could not reach it.

import BBSettings
import Foundation

public enum SettingPortability {

  /// Keys that describe THIS server's relationship to its machine, its history or its
  /// network, and are therefore meaningless — or harmful — on another one.
  ///
  /// Each entry is here for a stated reason. An entry with no reason is a filter again.
  ///
  /// Keyed through the DECLARATIONS rather than by spelling the storage keys, which is the
  /// rule `SettingKeyLiteralTests` enforces and is worth more here than most places:
  /// renaming a setting must not quietly drop it out of this list and start exporting it.
  public static let nonPortable: [String: String] = [
    Settings.serverAddress.key:
      "An output. The connection method republishes it; an imported one points clients at "
      + "an address nothing is serving.",
    Settings.tlsCertificateOrigin.key:
      "Describes where this server's TLS material came from, which the archive may not "
      + "carry.",
    Settings.tlsCertificateExpiresAt.key:
      "Belongs to a specific certificate, not to a configuration.",
    Settings.lastRunVersion.key:
      "Bookkeeping for this install's upgrade path.",
    Settings.lastFcmRestart.key:
      "Bookkeeping for this install's push service.",
    Settings.migrationSettingsState.key:
      "Records that THIS Mac adopted an Electron install. Importing it tells a server it "
      + "has already done something it has not.",
    Settings.migrationPushState.key: "Part of this Mac's record of adopting an Electron install.",
    Settings.migrationCertificatesState.key:
      "Part of this Mac's record of adopting an Electron install.",
    Settings.migrationPlaintextSecretsState.key:
      "Part of this Mac's record of adopting an Electron install.",
    Settings.migrationSavedRecordsState.key:
      "Part of this Mac's record of adopting an Electron install.",
    Settings.legacyConfigImported.key:
      "Part of this Mac's record of adopting an Electron install.",
    Settings.onboardingComplete.key:
      "Whether somebody walked through setup on this server. A restored configuration is "
      + "not a walkthrough, and the questions it asks are about this Mac's permissions.",
    Settings.onboardingSelections.key:
      "The answers to a walkthrough that happened on another machine.",
  ]

  /// Service bookkeeping written by `ServiceMigrator`, matched by shape rather than listed.
  ///
  /// One entry per service per install, all of the form
  /// `app.bluebubbles.<kind>.<name>.__version`. Listing them would mean this file gaining a
  /// line every time a service is added, which is the kind of list that goes stale quietly;
  /// the suffix is the thing that actually identifies them.
  static let serviceVersionSuffix = ".__version"

  /// Whether a key may be written into an export.
  public static func isPortable(_ key: String) -> Bool {
    if nonPortable[key] != nil { return false }
    if key.hasSuffix(serviceVersionSuffix) { return false }
    return true
  }

  /// Why a key is not portable, for a preview that has to explain what it is leaving out.
  public static func reason(_ key: String) -> String? {
    if let stated = nonPortable[key] { return stated }
    if key.hasSuffix(serviceVersionSuffix) {
      return "Service bookkeeping, written when a service first runs on a machine."
    }
    return nil
  }

  /// Secrets never travel as settings.
  ///
  /// They are not merely non-portable: they are a separate, encrypted section with its own
  /// gate (`SecretsEnvelope`). A secret reaching the settings file would be a credential in
  /// the clear inside an archive whose whole design says otherwise, so this is asked
  /// SEPARATELY from `isPortable` and at the point of writing, rather than folded into the
  /// list above where it would read as one more exclusion among thirteen.
  public static func isExportableSetting(_ key: String, secretKeys: Set<String>) -> Bool {
    !secretKeys.contains(key) && isPortable(key)
  }
}

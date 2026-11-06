//  SettingPortability
//  Which settings may cross from one server to another, which describe the server they
//  came from and must not, and which part of an archive carries the ones that do.
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
//  **A setting a person configures is portable unless it is named here; one with no row of
//  its own must be classified either way.** A setting with a presentation is something a
//  person chose on a screen, and carrying it is what a restore is for. A setting with none
//  is the shape bookkeeping takes, and bookkeeping is where the next `server_address` would
//  come from, so `SettingPortabilityTests` fails on one that is in neither `nonPortable`
//  nor `portableWithoutPresentation`. A filter written once would silently start exporting
//  it, and the failure would be invisible until somebody restored a backup onto a second
//  Mac and could not reach it.
//
//  **Where a portable value travels is decided by what it is, not by which list it is in.**
//  A secret, and a confidential value (one that says how to reach this server, or whose it
//  is), travel only inside the sealed `secrets.enc`; everything else is in `settings.json`,
//  which anybody holding the archive can read. A connection method's hostname is both
//  portable and confidential: without it a restore loses the tunnel, and in the clear it is
//  the server's address in a file people email themselves. `Route` is that decision, and
//  the exporter and the importer both ask it.

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
      + "carry. A restored certificate records its own, as the TLS section writes it.",
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
    Settings.licenseToken.key:
      "Bound to this Mac by its `machine` claim, so it is refused anywhere else; the key "
      + "travels with the secrets and the new server exchanges it for its own token.",
    Settings.licenseLastCheck.key:
      "When THIS install last reached the licence issuer. The new server's own refresh "
      + "sets it.",
    Settings.licenseRevoked.key:
      "What the issuer last told this install. The new server asks for itself, and a "
      + "carried answer would be one it never received.",
  ].merging(
    // Through the registry's set rather than by name: only the registry and the migration
    // may spell the Electron declarations (`LegacySettingsKeyTests`).
    Settings.electronOnlyKeys.map {
      (
        $0,
        "An Electron server's row, kept only so adopting one can read it. It configures "
          + "nothing here."
      )
    },
    uniquingKeysWith: { stated, _ in stated })

  /// Settings with no presentation that DO travel, each with why.
  ///
  /// The other half of the classification `SettingPortabilityTests` holds every hidden
  /// setting to. Being on this list is a decision somebody made about a value no screen
  /// shows, which is the only kind of setting a restore could carry without anybody having
  /// chosen it.
  public static let portableWithoutPresentation: [String: String] = [
    Settings.remoteRestartEnabled.key:
      "A switch the person set on the Firebase page, which draws it itself.",
    Settings.rateLimitBlockSeconds.key:
      "Part of the access-control policy the person chose; nothing about it is this Mac's.",
    Settings.homeDetail.key:
      "How much of Home the person likes to see, which is a preference rather than a fact "
      + "about this Mac.",
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

  /// Which part of an archive a value travels in.
  public enum Route: Sendable, Equatable {
    /// `settings.json`, readable by whoever holds the archive.
    case settingsFile
    /// `secrets.enc`, sealed under the server password (`SecretsEnvelope`).
    case sealed
    /// Not at all.
    case nowhere
  }

  /// Where a value with these properties travels.
  ///
  /// A secret is sealed whatever else is true of it: it has its own gate, and a credential
  /// reaching `settings.json` would be in the clear inside an archive whose whole design
  /// says otherwise. A confidential value is sealed for the reason `Setting.isConfidential`
  /// gives: it must not leave this Mac in anything somebody else can read. Asked SEPARATELY
  /// from `isPortable`, at the point of writing and again at the point of reading, rather
  /// than folded into the list above where it would read as one more exclusion.
  public static func route(_ key: String, isSecret: Bool, isConfidential: Bool) -> Route {
    if isSecret { return .sealed }
    guard isPortable(key) else { return .nowhere }
    return isConfidential ? .sealed : .settingsFile
  }
}

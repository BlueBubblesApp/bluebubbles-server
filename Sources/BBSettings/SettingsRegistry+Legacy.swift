//  SettingsRegistry+Legacy
//  The settings the Electron server had and this one does not read.
//
//  Its own file so the reserved keys are read as what they are: rows `LegacyConfigMigration`
//  brings across so a later setting cannot reuse a name whose stored value means something
//  else. Nothing outside the migration reads any of them, which `LegacySettingsKeyTests`
//  enforces. The lists that make a setting exist stay in `SettingsRegistry.swift`.

import Foundation

extension Settings {

  /// Settings the Electron server had and this one does not read.
  ///
  /// Declared so `LegacyConfigMigration` can bring the row across and so the key stays
  /// reserved: a future setting must not reuse a name whose stored value means something
  /// else on an upgraded install. Nothing outside the migration reads any of these, and
  /// `LegacySettingsKeyTests` asserts exactly that.
  public enum Legacy {
    public static let startViaTerminal = Setting<Bool>("start_via_terminal", default: false)
    /// The CLI's `--headless` flag is the real switch; this row is the Electron one.
    public static let headless = Setting<Bool>("headless", default: false)
    public static let disableGPU = Setting<Bool>("disable_gpu", default: false)
    public static let tutorialIsDone = Setting<Bool>("tutorial_is_done", default: false)
    /// Force-disabled at startup by the Electron server; the sealed-v2 codec supersedes it.
    public static let encryptComs = Setting<Bool>("encrypt_coms", default: false)
    /// The Electron server's choice of injection mechanism. There is one here.
    public static let privateAPIMode = Setting<String>(
      "private_api_mode", default: "process-dylib")

    /// Every legacy row, for the coverage checks.
    public static let all: [AnySetting] = [
      startViaTerminal.erased, headless.erased, disableGPU.erased,
      tutorialIsDone.erased, encryptComs.erased, privateAPIMode.erased,
    ]
  }

  /// The Electron-only keys, for a caller that has to RECOGNISE one without reading it: an
  /// export leaves them out (`SettingPortability`). Spelled here because only this file and
  /// the migration may name `Legacy`, which `LegacySettingsKeyTests` enforces.
  public static let electronOnlyKeys: Set<String> = Set(Legacy.all.map(\.key))
}

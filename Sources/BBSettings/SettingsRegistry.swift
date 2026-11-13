//  SettingsRegistry
//  Every setting, declared once with its type, default, secrecy and presentation.
//
//  Keys are UNCHANGED from the Electron server, and renaming one is a breaking change: it
//  orphans the row a user's value already lives in, and it breaks both the config-file name
//  and the mapping `LegacyConfigMigration` reads the Electron `config.db` with. They are not
//  wire names: nothing serves the settings map to a client. See `Setting.key`.
//
//  Two things declaring here buys:
//    - Every value has a declared type, so `start_delay` is a real Double. (The Electron
//      server stores it as the STRING "0.0" so its type inference does not read it as a
//      boolean; see `LegacyConfigMigration`.)
//    - Secrets are declared as such, so they route to the Keychain and are redacted in
//      diagnostics automatically rather than at each call site.
//
//  The declarations are by section: `SettingsRegistry+Connection.swift`,
//  `SettingsRegistry+PrivateAPI.swift`, `SettingsRegistry+Behaviour.swift`,
//  `SettingsRegistry+UpdatesAndSetup.swift`, `SettingsRegistry+Legacy.swift`,
//  `SettingsRegistry+SwiftOnly.swift` and `SettingsRegistry+Subscription.swift`. This file
//  holds the small enums, the lists that make a setting exist, and the lookups over them.
//
//  See `.claude/docs/database.md`.

import Foundation
import Logging

public enum AutoStartMethod: String, SettingValue, CaseIterable, Sendable {
  case none, unset
  case loginItem = "login-item"
  public static var typeTag: String { "string" }

  /// What a user should see. The raw values are storage, and two of them (`none` and
  /// `unset`) are the same answer to a person.
  public var label: String {
    switch self {
    case .none, .unset: "Don't start automatically"
    case .loginItem: "When I log in"
    }
  }

  /// `launch-agent` is the Electron server's per-user launch agent,
  /// `~/Library/LaunchAgents/com.bluebubbles.server.plist`, which its `FileSystem.createLaunchAgent`
  /// wrote and bootstrapped. Nothing here removes that plist; see `TODO.md`.
  ///
  /// It maps to `.loginItem` rather than to `.none`, which is a deliberate choice about
  /// INTENT. Someone holding this row asked for the server to start at login; the difference
  /// between the two options was supervision, which the launcher provides for the login
  /// item anyway. Defaulting them to "off" would answer a question they already answered.
  /// Registration still surfaces: macOS puts a new login item in `requiresApproval` and the
  /// service alerts, so this is not a silent enrolment.
  public static func parse(loose raw: String) -> AutoStartMethod? {
    if raw == "launch-agent" { return .loginItem }
    return AutoStartMethod(rawValue: raw)
  }

  /// The options a picker offers.
  ///
  /// `unset` is deliberately absent: it is a legacy sentinel meaning "never decided", and
  /// offering it would let someone choose a value that means nothing. Existing rows holding
  /// it still parse and read as off.
  public static var choices: [AutoStartMethod] { [.none, .loginItem] }
}

/// Authentication mode. `password` is the default and, per the compatibility contract, the
/// only active mechanism unless deliberately changed.
public enum AuthMode: String, SettingValue, CaseIterable, Sendable {
  case password, token, both
  public static var typeTag: String { "string" }
}

/// Event payload format. `legacyV1` is byte-identical to today's output.
public enum PayloadCodecID: String, SettingValue, CaseIterable, Sendable {
  case legacyV1 = "legacy-v1"
  case referenceV2 = "reference-v2"
  case sealedV2 = "sealed-v2"
  public static var typeTag: String { "string" }
}

public enum Settings {

  /// Every setting, for migration and for the coverage checks.
  ///
  /// DERIVED from the declarations rather than listed a second time as strings: `renderable`
  /// is every setting with a presentation, `hidden` is the bookkeeping the UI never shows,
  /// and a key that is in neither list does not exist. Uniqueness is asserted by
  /// `SettingsStoreTests`.
  public static var allKeys: [String] { all.map(\.key) }

  /// Every declared setting, renderable or not.
  public static let all: [AnySetting] = renderable + hidden

  /// Settings with no presentation: read by the server, never shown.
  ///
  /// Several exist only so `LegacyConfigMigration` can read the Electron server's row and
  /// so the key stays reserved; they are read by nothing else. See `Legacy` in
  /// `SettingsRegistry+Legacy.swift`.
  static let hidden: [AnySetting] =
    [
      licenseKey.erased,
      licenseToken.erased,
      licenseLastCheck.erased,
      licenseRevoked.erased,
      remoteRestartEnabled.erased,
      rateLimitBlockSeconds.erased,
      lastFcmRestart.erased,
      lastRunVersion.erased,
      legacyConfigImported.erased,
      migrationSettingsState.erased,
      migrationPushState.erased,
      migrationSavedRecordsState.erased,
      onboardingComplete.erased,
      onboardingSelections.erased,
      homeDetail.erased,
      migrationCertificatesState.erased,
      migrationPlaintextSecretsState.erased,
      tlsCertificateOrigin.erased,
      tlsCertificateExpiresAt.erased,
    ] + Legacy.all

  /// Keys whose values must never appear in a log, an alert, or an exported diagnostic.
  ///
  /// DERIVED from `isSecret` rather than listed a second time. A literal set could miss a
  /// setting declared secret later, silently and in the worst direction: the value would go
  /// to the Keychain, but `SettingsScope` and the redaction both consult this set, so a
  /// service could read it and nothing would redact it.
  public static let secretKeys: Set<String> = Set(all.filter(\.isSecret).map(\.key))

  /// Keys whose values are withheld from anything built to leave this Mac. Derived from
  /// `isConfidential` for the reason `secretKeys` is derived from `isSecret`.
  public static let confidentialKeys: Set<String> = Set(all.filter(\.isConfidential).map(\.key))
}

/// The default update feed.
///
/// Declared here rather than imported from BBUpdates so BBSettings does not depend on it:
/// settings sit below everything, and a dependency in that direction would pull the update
/// machinery into every module that reads a setting. `UpdateChecker.defaultFeedURL` carries
/// the same value, and `UpdateFeedTests` asserts they agree.
public enum UpdateFeed {
  public static let defaultURL =
    "https://raw.githubusercontent.com/BlueBubblesApp/bluebubbles-server/master/appcast.xml"
}

// MARK: - The renderable list

extension Settings {

  /// Every setting the generated UI renders, in presentation order.
  ///
  /// Declared here rather than derived by reflection: Swift has no way to enumerate a
  /// type's static members, and a macro to do it would be a lot of machinery to avoid one
  /// list. The `SettingsRegistryTests` coverage check is what keeps this honest: it fails
  /// when a setting declares a presentation and is missing here, which is the mistake this
  /// list invites.
  public static let renderable: [AnySetting] =
    [
      socketPort.erased,
      chatDatabaseReaders.erased,
      serverAddress.erased,
      password.erased,
      connectionMethod.erased,
      bindAddress.erased,
      useCustomCertificate.erased,
      corsAllowedOrigin.erased,
      enablePrivateAPI.erased,
      privateAPIHelperPath.erased,
      privateAPIFaceTimeHelperPath.erased,
      enableFaceTimePrivateAPI.erased,
      faceTimeIncomingHandoff.erased,
      faceTimeOutgoingCalls.erased,
      faceTimeIdleCameraOff.erased,
      faceTimeLinkTTLHours.erased,
      searchIndexEnabled.erased,
      startDelay.erased,
      dbPollInterval.erased,
      autoCaffeinate.erased,
      autoStartMethod.erased,
      startMinimized.erased,
      hideDockIcon.erased,
      dockBadge.erased,
      autoLockMac.erased,
      openFindMyOnStartup.erased,
      landingPagePath.erased,
      checkForUpdates.erased,
      autoInstallUpdates.erased,
      autoInstallHour.erased,
      receiveBetaUpdates.erased,
      authMode.erased,
      updateFeedURL.erased,
      eventPayloadCodec.erased,
      logLevel.erased,
      rateLimitEnabled.erased,
      rateLimitFailureThreshold.erased,
      trustLocalNetwork.erased,
      trustedProxies.erased,
      ntfyTopic.erased,
      ntfyServer.erased,
      ntfyToken.erased,
      licenseEndpoint.erased,
      ntfyEvents.erased,
      // Appended rather than listed one by one: `Features.all` is already the single
      // declaration, and transcribing it here is the mistake the coverage check exists to
      // catch. A new flag reaches the settings screen by being declared, and by nothing else.
    ] + Features.all.map(\.setting.erased)

  /// The stored `log_level` as a swift-log level.
  ///
  /// Here rather than at the call site because the picker's option values and the parse have
  /// to agree, and they are two lines apart when they live together.
  public static func logLevel(from raw: String) -> Logger.Level {
    Logger.Level(rawValue: raw.lowercased()) ?? .info
  }

  /// The label the settings screen uses for a key, or the key itself.
  ///
  /// For a sentence about a setting the person has JUST EDITED: the restart notice, which
  /// says "Local Port is saved, but the server reads it while starting up". They chose that
  /// value on a row with that heading a moment ago, so the heading is what they recognise.
  ///
  /// NOT for the permissions list. That named settings this way and no longer does; see
  /// `Entitlement.userFacingDescription` for why a list about capability wants the storage
  /// key instead.
  ///
  /// Falls back to the key rather than to nothing, which is why the restart notice carries a
  /// test that every structural key resolves to something other than itself: the fallback is
  /// right in general, and a silent one there would be a notice naming a column.
  public static func label(forKey key: String) -> String {
    renderable.first { $0.key == key }?.presentation.label ?? key
  }

  /// The declared setting a key names, or nil.
  ///
  /// Over `all` rather than `renderable`, so a caller resolving a `requires` key gets the
  /// same answer whether or not the parent happens to have a screen.
  public static func setting(forKey key: String) -> AnySetting? {
    all.first { $0.key == key }
  }

  /// The switches a setting hangs off, nearest first.
  ///
  /// Usually one, and `auto_install_hour` is why this is a walk rather than a lookup: it
  /// depends on the automatic install, which depends in turn on the daily check. A screen
  /// that read only the immediate parent would draw that row live while the switch above
  /// it was greyed out, which says the opposite of the truth.
  ///
  /// Cycle-guarded by construction. `SettingDependencyTests` proves the declarations
  /// contain no cycle, and this still refuses to loop on one: a settings screen that hangs
  /// is a worse failure than a row that is wrong, and the test is the thing that has to be
  /// true, not the only thing.
  public static func requirementChain(for setting: AnySetting) -> [AnySetting] {
    var chain: [AnySetting] = []
    var seen: Set<String> = [setting.key]
    var next = setting.presentation.requires
    while let key = next, !seen.contains(key), let parent = self.setting(forKey: key) {
      chain.append(parent)
      seen.insert(key)
      next = parent.presentation.requires
    }
    return chain
  }

  /// The switch to tell somebody to turn on, or nil when the setting is live.
  ///
  /// **The OUTERMOST one that is off, not the nearest**, and that is the whole reason this
  /// is a function rather than a comparison at the call site. With Check for Updates off and
  /// Install Updates Automatically stored on, the nearest unmet switch for the install hour
  /// is Check for Updates and both answers happen to agree. With BOTH off, the nearest is
  /// Install Updates Automatically, which is itself greyed out: the row would name a control
  /// the person cannot click. The outermost is always the one that can be.
  ///
  /// - Parameter isOn: the current value of a switch, by storage key. A key the caller
  ///   could not read answers `true`, so an unreadable parent leaves the row usable rather
  ///   than locking it on a failed read.
  public static func blockingRequirement(
    for setting: AnySetting, isOn: (String) -> Bool
  ) -> AnySetting? {
    requirementChain(for: setting).last { !isOn($0.key) }
  }

  /// Renderable settings grouped into their sections, ready for a `Form`.
  public static var renderableSections: [(section: SettingSection, settings: [AnySetting])] {
    let visible = renderable.filter { !$0.presentation.isInternal }
    var order: [SettingSection] = []
    var grouped: [SettingSection: [AnySetting]] = [:]
    for setting in visible {
      let section = setting.presentation.section
      if grouped[section] == nil { order.append(section) }
      grouped[section, default: []].append(setting)
    }
    return order.map { ($0, grouped[$0] ?? []) }
  }
}

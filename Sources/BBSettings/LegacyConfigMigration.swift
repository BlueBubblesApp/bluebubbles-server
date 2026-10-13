//  LegacyConfigMigration
//  Imports the Electron server's config.db into the typed store, once.
//
//  The old table is (name TEXT, value TEXT) with types inferred on read:
//
//      if (input === "1" || input === "0") return Boolean(Number(input));
//      if (/^-{0,1}\d+$/.test(input)) return Number(input);
//      return input;
//
//  So the migration cannot ask the old store what type a value is: it has to consult the
//  DECLARED type for each key and coerce from the raw string. That is the whole point: this
//  is the moment the guessing stops.
//
//  The old file is left untouched by `run`, so downgrading to the Electron server during a
//  beta still works.
//
//  That includes the secrets. Both connections are opened `readonly = true`; the only write
//  to the old database is `removePlaintextSecrets` below, a SEPARATE and consented step the
//  migration wizard offers after the copy into the Keychain has succeeded. Separate because
//  it is the one irreversible thing here, and because deleting those rows is exactly what
//  breaks the downgrade path promised above. Nobody should get that as a side effect of
//  importing their settings.
//
//  See `.claude/docs/database.md` and § Security.

import BBCore
import Foundation
import GRDB
import Logging

public struct LegacyConfigMigration: Sendable {

  public struct Result: Sendable {
    /// A legacy key that was recognised and could not be carried over, and why. The reason is
    /// a sentence for a person; the value is deliberately not kept, since the row may hold a
    /// credential.
    public struct NotCarriedOver: Sendable, Equatable {
      public let key: String
      public let reason: String
    }

    public var imported: [String] = []
    public var secretsMoved: [String] = []
    public var skippedUnknown: [String] = []
    /// Known keys whose value did not land. Not a failure of the import, which commits the
    /// rest, but never silent either: the migration step names each one.
    public var notCarriedOver: [NotCarriedOver] = []
  }

  private let logger = Logger(label: "bluebubbles.settings.migration")

  public init() {}

  /// Default location of the Electron server's config database.
  public static var legacyDatabaseURL: URL { ApplicationSupport.electronConfigDatabase }

  /// Whether there is a legacy database here worth reading.
  ///
  /// Checks for the `config` TABLE, not just the file. The Swift server's own
  /// `Application Support` directory sits at the same path, so a `config.db` can exist
  /// without ever having belonged to the Electron server, and then the import throws
  /// `no such table: config`, logs a warning, and (because the failure path never records
  /// the marker) does it again on every single launch, forever. Measured on a real machine.
  public func hasLegacyDatabase(at url: URL = legacyDatabaseURL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }

    var configuration = Configuration()
    configuration.readonly = true
    guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration)
    else { return false }

    return (try? queue.read { db in try db.tableExists("config") }) ?? false
  }

  /// Reads the legacy config table and writes it into `store` as typed values.
  ///
  /// Opened READ-ONLY. `run` never modifies the Electron server's database, including the
  /// plaintext secrets, which survive the copy into the Keychain. Removing them is
  /// `removePlaintextSecrets`, a separate step the user accepts.
  ///
  /// - Parameter recording: Written into the SAME batch as the import.
  ///
  ///   Not a convenience. The caller's "this step is done" marker has to commit in the same
  ///   transaction as the values it describes, or there is a window between the two writes
  ///   where the import has landed and nothing records it, and a process that dies in that
  ///   window re-runs the import on the next launch. Re-running is not harmless: every key
  ///   is written with no comparison to the current value, so it reverts whatever the user
  ///   changed in between. `SettingsStore.write` validates everything and then commits once,
  ///   so passing the marker in here is what makes the pair atomic.
  public func run(
    from url: URL = legacyDatabaseURL,
    into store: SettingsStore,
    secrets: any SecretStore,
    recording: (@Sendable (inout SettingsBatch) throws -> Void)? = nil
  ) async throws -> Result {
    var result = Result()
    guard hasLegacyDatabase(at: url) else { return result }

    var configuration = Configuration()
    configuration.readonly = true
    let legacy = try DatabaseQueue(path: url.path, configuration: configuration)

    // Mapped INSIDE the closure so the result is Sendable, which selects GRDB's async
    // overload. Returning `Row` values would resolve to the synchronous one and block
    // while looking asynchronous.
    let raw = try await legacy.read { db in
      var values: [String: String] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT name, value FROM config") {
        let name: String = row["name"]
        let value: String? = row["value"]
        values[name] = value ?? ""
      }
      return values
    }

    // Secrets first, so a failure part-way leaves them in the Keychain rather than
    // half-migrated in plaintext — and REVERSIBLY, because the batch below can still throw.
    //
    // Without the undo, a failed batch left the secrets written and the completion marker
    // unrecorded, so the migration re-ran on the next launch. This method's own doc explains
    // why re-running is bad ("reverts whatever the user changed in between"), and the secret
    // writes are the case where that matters most: a password the user had already changed
    // in this server would be silently reverted to the Electron one. `SettingsStore.write`
    // does the same thing for the same reason.
    var undoSecrets: [(key: String, previous: String?)] = []
    func setSecret(_ key: String, to value: String) throws {
      undoSecrets.append((key, try? secrets.get(key)))
      try secrets.set(key, value: value)
    }
    func rollBackSecrets() {
      for entry in undoSecrets.reversed() {
        if let previous = entry.previous {
          try? secrets.set(entry.key, value: previous)
        } else {
          try? secrets.delete(entry.key)
        }
      }
    }

    for key in Settings.secretKeys {
      guard let value = raw[key], !value.isEmpty else { continue }
      try setSecret(key, to: value)
      result.secretsMoved.append(key)
    }

    // Secrets that now belong to a service, stored under their NEW name.
    //
    // The destination matters more than it looks. Writing an ngrok auth token under
    // `ngrok_key` would leave it sitting in the Keychain looking perfectly migrated while
    // the ngrok service (which reads its own namespace) finds nothing and reports itself
    // unconfigured. A credential in the wrong place is worse than one that failed to
    // migrate, because nothing about it looks wrong.
    for (legacyKey, destination) in Legacy.secretDestinations {
      guard let value = raw[legacyKey], !value.isEmpty else { continue }
      try setSecret(destination, to: value)
      result.secretsMoved.append(destination)
    }

    do {
      try await store.write { batch in
        for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
          guard let rule = Legacy.rules[key] else {
            // A key the registry declares and no rule reads is reported, never dropped as
            // unknown and never counted as imported. None can appear while every declared
            // key without a rule is a Swift-only setting that no Electron `config.db` holds;
            // this is what says so the day that stops being true.
            if Settings.allKeys.contains(key) {
              result.notCarriedOver.append(
                Result.NotCarriedOver(
                  key: key,
                  reason: DiagnosticText.sentence(for: LegacyMigrationError.noRuleForKey(key))))
            } else {
              result.skippedUnknown.append(key)
            }
            continue
          }
          do {
            try rule.apply(value, &batch)
            result.imported.append(key)
          } catch {
            result.notCarriedOver.append(
              Result.NotCarriedOver(key: key, reason: DiagnosticText.sentence(for: error)))
          }
        }
        // Last, inside the same transaction. See `recording` above.
        try recording?(&batch)
      }
    } catch {
      rollBackSecrets()
      throw error
    }

    logger.info(
      "Imported legacy configuration",
      metadata: [
        "imported": .stringConvertible(result.imported.count),
        "secretsMovedCount": .stringConvertible(result.secretsMoved.count),
        "skipped": .stringConvertible(result.skippedUnknown.count),
        "notCarriedOver": .stringConvertible(result.notCarriedOver.count),
      ])
    if !result.notCarriedOver.isEmpty {
      // Setting KEYS only, which name a setting and never a person; the values stay out.
      logger.warning(
        "Some legacy settings were not carried over",
        metadata: ["keys": .string(result.notCarriedOver.map(\.key).joined(separator: ", "))])
    }

    return result
  }

  /// Deletes the plaintext credential rows from the Electron `config.db`.
  ///
  /// **The only thing in this file that writes to the old database, and the only
  /// irreversible step in the whole migration.** Without it, moving a secret to the
  /// Keychain leaves the readable copy behind.
  ///
  /// Two things it deliberately does NOT do:
  ///
  ///   - It does not check that the Keychain copy exists. That is the CALLER's job, and the
  ///     migration wizard enforces it by refusing to offer this step until the settings step
  ///     has completed. Deleting first would destroy the only copy of a password.
  ///   - It does not remove the file, or any non-secret row. A downgrade to the Electron
  ///     server still finds its configuration; what it will not find is the credentials,
  ///     which is the point and is why the user is asked first.
  ///
  /// - Returns: the keys actually removed, so the caller can say what happened.
  @discardableResult
  public func removePlaintextSecrets(at url: URL = legacyDatabaseURL) throws -> [String] {
    guard hasLegacyDatabase(at: url) else { return [] }

    // Read-WRITE, uniquely. Everything else here opens `readonly = true`.
    let legacy = try DatabaseQueue(path: url.path)
    let keys = Legacy.plaintextSecretKeys

    return try legacy.write { db in
      var removed: [String] = []
      for key in keys.sorted() {
        // `changes` rather than a prior SELECT: one statement, and it reports whether the
        // row was actually there so an empty result is distinguishable from a no-op.
        try db.execute(sql: "DELETE FROM config WHERE name = ?", arguments: [key])
        if db.changesCount > 0 { removed.append(key) }
      }
      return removed
    }
  }

  /// Whether any credential is still sitting in the clear.
  public func hasPlaintextSecrets(at url: URL = legacyDatabaseURL) -> Bool {
    guard hasLegacyDatabase(at: url) else { return false }
    var configuration = Configuration()
    configuration.readonly = true
    guard let legacy = try? DatabaseQueue(path: url.path, configuration: configuration) else {
      return false
    }
    let keys = Legacy.plaintextSecretKeys
    return
      (try? legacy.read { db in
        for key in keys {
          let value = try String.fetchOne(
            db, sql: "SELECT value FROM config WHERE name = ?", arguments: [key])
          if let value, !value.isEmpty { return true }
        }
        return false
      }) ?? false
  }
}

/// A legacy key this migration recognises but has no rule for. See `LegacyConfigMigration.run`.
///
/// Reported in `Result.notCarriedOver`, which the migration step puts in front of the person
/// through `MigrationRunner`'s detail line.
enum LegacyMigrationError: BBError, CustomStringConvertible {
  case noRuleForKey(String)

  var code: String { "settings.legacy_key_without_rule" }
  var domain: String { "Migration" }
  var title: String { "A setting could not be carried over" }
  var description: String { body }
  var context: [String: DiagnosticValue] {
    switch self {
    case .noRuleForKey(let key): ["key": .string(key)]
    }
  }

  var body: String {
    switch self {
    case .noRuleForKey:
      "It is a known setting with no migration rule, so its value was not carried over"
    }
  }
}

/// What one Electron `config` row becomes.
///
/// A rule rather than a case in a switch, so the whole mapping is one table that can be read,
/// reviewed and tested as a unit, and so every destination is a typed `Setting` or a service
/// field named in `Legacy`, never a key spelled as a string at the point of use.
struct LegacyRule: Sendable {
  let apply: @Sendable (_ raw: String, _ batch: inout SettingsBatch) throws -> Void

  /// The declared type wins. The Electron coercion returns `"0"` and `"1"` as booleans, so a
  /// numeric setting whose value happens to be 0 or 1 has to be read by its declaration.
  static func int(_ setting: Setting<Int>, fallback: Int) -> LegacyRule {
    LegacyRule { raw, batch in try batch.set(setting, to: Int(raw) ?? fallback) }
  }

  static func double(_ setting: Setting<Double>, fallback: Double) -> LegacyRule {
    LegacyRule { raw, batch in try batch.set(setting, to: Double(raw) ?? fallback) }
  }

  /// `ifEmpty` replaces an empty row, which the Electron store wrote for "never chosen".
  static func string(_ setting: Setting<String>, ifEmpty: String? = nil) -> LegacyRule {
    LegacyRule { raw, batch in
      try batch.set(setting, to: raw.isEmpty ? (ifEmpty ?? raw) : raw)
    }
  }

  static func bool(_ setting: Setting<Bool>) -> LegacyRule {
    LegacyRule { raw, batch in try batch.set(setting, to: legacyBool(raw)) }
  }

  /// An enum, tolerating a value this version does not know by falling back to `fallback`.
  static func choice<Value: SettingValue & RawRepresentable>(
    _ setting: Setting<Value>, fallback: Value
  ) -> LegacyRule where Value.RawValue == String {
    LegacyRule { raw, batch in try batch.set(setting, to: Value(rawValue: raw) ?? fallback) }
  }

  /// A setting that now belongs to a connection-method service. Written with `setDynamic`
  /// because the destination is a manifest field rather than a compiled-in descriptor:
  /// `zrok_reserved_name` becomes `app.bluebubbles.proxy.zrok.reserved_name`, which no
  /// `Setting<Value>` declares.
  static func serviceField(_ key: String, ifEmpty: String? = nil) -> LegacyRule {
    LegacyRule { raw, batch in
      batch.setDynamic(raw.isEmpty ? (ifEmpty ?? raw) : raw, forKey: key, isSecret: false)
    }
  }

  /// A service-owned switch, stored as the `"true"`/`"false"` a manifest form reads.
  static func serviceSwitch(_ key: String) -> LegacyRule {
    LegacyRule { raw, batch in
      batch.setDynamic(legacyBool(raw) ? "true" : "false", forKey: key, isSecret: false)
    }
  }

  /// Recognised, so it is not reported as unknown, and deliberately written nowhere: a secret
  /// already moved to the Keychain, or a retired setting.
  static let writtenElsewhere = LegacyRule { _, _ in }

  private static func legacyBool(_ raw: String) -> Bool { Bool(loose: raw) ?? false }
}

/// Where the Electron server's keys land now.
///
/// A table rather than logic scattered through the migration, because this is the ONE thing
/// in the whole settings layer that has to keep working forever: the Swift server's own
/// configuration can be reset at will, but an Electron install's cannot. These are values a
/// user typed once (an ngrok token from years ago, a reserved zrok share whose name they no
/// longer remember) and landing them in the wrong place produces a tunnel that silently
/// stops working after an upgrade, with nothing to tell them what it used to be.
///
/// Kept in one place so the mapping can be read, reviewed and tested as a unit. Adding a
/// service means adding rows here, not editing a switch in three places.
public enum Legacy {

  // MARK: - Destinations
  //
  // Fully qualified, matching each service's manifest. Written out literally rather than
  // assembled from `BuiltInManifests`, because this module cannot see that one, and
  // because a constant is what a migration should be: if an identifier ever changes, this
  // file must be updated deliberately rather than following along silently.
  public static let ngrokAuthToken = "app.bluebubbles.proxy.ngrok.auth_token"
  public static let ngrokRegion = "app.bluebubbles.proxy.ngrok.region"
  public static let ngrokCustomDomain = "app.bluebubbles.proxy.ngrok.custom_domain"
  /// Retained even though the manifest declares no field for it: `ngrok_protocol` is
  /// meaningful to an existing install and dropping it silently would lose a choice the
  /// user made. It is migrated and simply unread until the field exists.
  public static let ngrokProtocol = "app.bluebubbles.proxy.ngrok.protocol"

  public static let zrokAccountToken = "app.bluebubbles.proxy.zrok.account_token"
  public static let zrokReserveTunnel = "app.bluebubbles.proxy.zrok.reserve_tunnel"
  public static let zrokReservedName = "app.bluebubbles.proxy.zrok.reserved_name"
  public static let zrokReservedToken = "app.bluebubbles.proxy.zrok.reserved_token"

  // MARK: - Rules

  /// Every Electron `config` key this migration carries over, and what each becomes.
  ///
  /// The KEYS are Electron spellings, and literals for that reason: they name rows in the old
  /// database. The destinations are typed settings or the service fields above and never a
  /// literal, because a destination spelled as a string is a setting that silently stops being
  /// written the day it is renamed. `SettingKeyLiteralTests` holds this file to that: a declared
  /// key may appear here only as a table key.
  static let rules: [String: LegacyRule] = [
    "socket_port": .int(Settings.socketPort, fallback: 1234),
    // The Electron poll period becomes the backup-check period, which has a 30-second floor.
    // A user who set it HIGHER keeps their value; everyone else is raised to it.
    "db_poll_interval": LegacyRule { raw, batch in
      try batch.set(Settings.dbPollInterval, to: max(30_000, Int(raw) ?? 30_000))
    },
    "last_fcm_restart": .int(Settings.lastFcmRestart, fallback: 0),
    // Stored by the Electron server as the STRING "0.0" so its coercion would not read it as a
    // boolean. A Double here.
    "start_delay": .double(Settings.startDelay, fallback: 0),

    // Secrets: the real value already went to the Keychain, and must not be written back into
    // the database. Deliberately NOT run through `batch.set`, and that is the point for the
    // password: one carried over from the Electron server predates any entropy policy, and
    // applying the policy to it would fail the migration and lock the install out of every
    // client it has. An existing password is adopted as-is; the UI reports on its strength.
    "password": .writtenElsewhere,
    "ngrok_key": .writtenElsewhere,
    "zrok_token": .writtenElsewhere,
    "zrok_reserved_token": .writtenElsewhere,

    "server_address": .string(Settings.serverAddress),
    "landing_page_path": .string(Settings.landingPagePath),
    "private_api_mode": .string(Settings.Legacy.privateAPIMode, ifEmpty: "process-dylib"),
    "log_level": .string(Settings.logLevel, ifEmpty: "info"),

    // Settings that now belong to a connection-method service rather than to the core. THIS is
    // the part that has to be right: these are values a user typed once and has not thought
    // about since, and landing them in the wrong place means a tunnel that silently stops
    // working after an upgrade with no way to know what it used to be.
    "ngrok_protocol": .serviceField(ngrokProtocol, ifEmpty: "http"),
    "ngrok_region": .serviceField(ngrokRegion, ifEmpty: "us"),
    "ngrok_custom_domain": .serviceField(ngrokCustomDomain),
    "zrok_reserved_name": .serviceField(zrokReservedName),
    "zrok_reserve_tunnel": .serviceSwitch(zrokReserveTunnel),
    // Renamed as well as translated: `proxy_service` is `connection_method` here, and its VALUE
    // is a service identifier rather than an enum case. Without this rule an upgrading install
    // would come back on the default connection method: the one setting most likely to make
    // the server unreachable.
    "proxy_service": LegacyRule { raw, batch in
      try batch.set(Settings.connectionMethod, to: connectionMethod(forLegacyProxyService: raw))
    },

    "auto_start_method": .choice(Settings.autoStartMethod, fallback: .none),
    "auth_mode": .choice(Settings.authMode, fallback: .password),
    "event_payload_codec": .choice(Settings.eventPayloadCodec, fallback: .legacyV1),

    "use_custom_certificate": .bool(Settings.useCustomCertificate),
    "enable_private_api": .bool(Settings.enablePrivateAPI),
    "enable_ft_private_api": .bool(Settings.enableFaceTimePrivateAPI),
    "auto_caffeinate": .bool(Settings.autoCaffeinate),
    "start_minimized": .bool(Settings.startMinimized),
    "hide_dock_icon": .bool(Settings.hideDockIcon),
    "dock_badge": .bool(Settings.dockBadge),
    "auto_lock_mac": .bool(Settings.autoLockMac),
    "open_findmy_on_startup": .bool(Settings.openFindMyOnStartup),
    "start_via_terminal": .bool(Settings.Legacy.startViaTerminal),
    "headless": .bool(Settings.Legacy.headless),
    "disable_gpu": .bool(Settings.Legacy.disableGPU),
    "check_for_updates": .bool(Settings.checkForUpdates),
    "auto_install_updates": .bool(Settings.autoInstallUpdates),
    "tutorial_is_done": .bool(Settings.Legacy.tutorialIsDone),
    "rate_limit_enabled": .bool(Settings.rateLimitEnabled),
    "trust_local_network": .bool(Settings.trustLocalNetwork),

    // Retired: force-disabled at startup and superseded by the sealed-v2 codec.
    "encrypt_coms": .writtenElsewhere,
    // Retired: the Electron UI painted its own chrome and needed telling to go pure black.
    // This app uses the system appearance, so the flag would control nothing.
    "use_oled_dark_mode": .writtenElsewhere,
  ]

  /// Legacy secret key -> namespaced destination.
  ///
  /// Separate from the plain values because secrets are moved into the Keychain first, and
  /// under their NEW name: writing them under the old one would leave the service unable to
  /// find its own credential while the value sat there looking migrated.
  public static let secretDestinations: [String: String] = [
    "ngrok_key": ngrokAuthToken,
    "zrok_token": zrokAccountToken,
    "zrok_reserved_token": zrokReservedToken,
  ]

  /// Every row in the Electron `config.db` that holds a credential in the clear.
  ///
  /// Exposed as a list because callers outside this file may not name legacy keys: a test
  /// scans `Sources/` and fails on any other file that does, so that a legacy spelling
  /// cannot quietly become a second name for a live setting.
  public static var plaintextSecretKeys: Set<String> {
    Set(secretDestinations.keys).union(Settings.secretKeys)
  }

  /// The Electron `proxy_service` value -> the service that replaces it.
  public static func connectionMethod(forLegacyProxyService value: String) -> String {
    switch value.lowercased() {
    case "ngrok": "app.bluebubbles.proxy.ngrok"
    case "zrok": "app.bluebubbles.proxy.zrok"
    case "lan-url", "lan url", "lanurl": "app.bluebubbles.proxy.lan"
    case "dynamic-dns", "dynamic dns", "dns": "app.bluebubbles.proxy.dynamic-dns"
    case "cloudflare": "app.bluebubbles.proxy.cloudflare"
    // Unknown values land on Cloudflare, which needs no account and no configuration:
    // the safest place for someone whose old choice no longer exists.
    default: "app.bluebubbles.proxy.cloudflare"
    }
  }
}

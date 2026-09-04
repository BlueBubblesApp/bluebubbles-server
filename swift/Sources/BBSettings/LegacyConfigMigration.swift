//  LegacyConfigMigration
//  Imports the Electron server's config.db into the typed store, once.
//
//  The old table is (name TEXT, value TEXT) with types inferred on read:
//
//      if (input === "1" || input === "0") return Boolean(Number(input));
//      if (/^-{0,1}\d+$/.test(input)) return Number(input);
//      return input;
//
//  So the migration cannot ask the old store what type a value is — it has to consult the
//  DECLARED type for each key and coerce from the raw string. That is the whole point: this
//  is the moment the guessing stops.
//
//  The old file is left untouched, so downgrading to the Electron server during a beta still
//  works. Secrets are the exception: they move to the Keychain and the plaintext row is
//  deleted, because leaving them readable is the vulnerability being fixed.
//
//  See `.claude/docs/database.md` and § Security.

import Foundation
import GRDB
import Logging

public struct LegacyConfigMigration: Sendable {

  public struct Result: Sendable {
    public var imported: [String] = []
    public var secretsMoved: [String] = []
    public var skippedUnknown: [String] = []
    public var coercionFailures: [(key: String, raw: String, expected: String)] = []
  }

  private let logger = Logger(label: "bluebubbles.settings.migration")

  public init() {}

  /// Default location of the Electron server's config database.
  public static var legacyDatabaseURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/bluebubbles-server/config.db")
  }

  /// Whether there is a legacy database here worth reading.
  ///
  /// Checks for the `config` TABLE, not just the file. The Swift server's own
  /// `Application Support` directory sits at the same path, so a `config.db` can exist
  /// without ever having belonged to the Electron server — and then the import throws
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
  /// Opened READ-ONLY. We never modify the Electron server's database — the only deletion
  /// is of the plaintext secret, and that happens after the Keychain write succeeds.
  public func run(
    from url: URL = legacyDatabaseURL,
    into store: SettingsStore,
    secrets: any SecretStore
  ) async throws -> Result {
    var result = Result()
    guard hasLegacyDatabase(at: url) else { return result }

    var configuration = Configuration()
    configuration.readonly = true
    let legacy = try DatabaseQueue(path: url.path, configuration: configuration)

    // Mapped INSIDE the closure so the result is Sendable, which is what selects GRDB's
    // async overload. Returning `Row` values left the synchronous one as the only
    // candidate, so this blocked while looking asynchronous.
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
    // half-migrated in plaintext.
    for key in Settings.secretKeys {
      guard let value = raw[key], !value.isEmpty else { continue }
      try secrets.set(key, value: value)
      result.secretsMoved.append(key)
    }

    // Secrets that now belong to a service, stored under their NEW name.
    //
    // The destination matters more than it looks. Writing an ngrok auth token under
    // `ngrok_key` would leave it sitting in the Keychain looking perfectly migrated while
    // the ngrok service — which reads its own namespace — finds nothing and reports itself
    // unconfigured. A credential in the wrong place is worse than one that failed to
    // migrate, because nothing about it looks wrong.
    for (legacyKey, destination) in Legacy.secretDestinations {
      guard let value = raw[legacyKey], !value.isEmpty else { continue }
      try secrets.set(destination, value: value)
      result.secretsMoved.append(destination)
    }

    try await store.write { batch in
      for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
        // A key that belongs to a service is not "unknown" — it has a destination,
        // it is just not in the core registry any more. Checking both is what keeps
        // the migration from silently discarding half of an ngrok configuration.
        guard Settings.allKeys.contains(key) || Legacy.handles(key) else {
          result.skippedUnknown.append(key)
          continue
        }
        do {
          try Self.apply(key: key, raw: value, to: &batch)
          result.imported.append(key)
        } catch {
          result.coercionFailures.append((key: key, raw: value, expected: "declared type"))
        }
      }
    }

    logger.info(
      "Imported legacy configuration",
      metadata: [
        "imported": .stringConvertible(result.imported.count),
        "secretsMoved": .stringConvertible(result.secretsMoved.count),
        "skipped": .stringConvertible(result.skippedUnknown.count),
        "failures": .stringConvertible(result.coercionFailures.count),
      ])

    return result
  }

  /// Coerces one raw string to the key's declared type.
  ///
  /// Every case here is a place the old inference could have produced the wrong type. The
  /// interesting ones are called out.
  static func apply(key: String, raw: String, to batch: inout SettingsBatch) throws {
    func bool() -> Bool {
      switch raw.lowercased() {
      case "1", "true", "yes": true
      default: false
      }
    }

    switch key {
    // Ints. Under the old rules a value of 0 or 1 came back as a Bool, so any caller
    // doing arithmetic on it got a surprise.
    case "socket_port": try batch.set(Settings.socketPort, to: Int(raw) ?? 1234)
    // The Electron poll period becomes the backup-check period, which has a 30-second
    // floor. A user who set it HIGHER keeps their value; everyone else is raised to it.
    case "db_poll_interval":
      try batch.set(Settings.dbPollInterval, to: max(30_000, Int(raw) ?? 30_000))
    case "last_fcm_restart": try batch.set(Settings.lastFcmRestart, to: Int(raw) ?? 0)

    // The headline case: stored as the STRING "0.0" specifically so the old coercion
    // would not read it as a boolean. It is a Double now.
    case "start_delay": try batch.set(Settings.startDelay, to: Double(raw) ?? 0)

    // Secrets: the real value already went to the Keychain above and must not be
    // written back into the database.
    //
    // Deliberately NOT run through `batch.set`, and that is the whole point. A password
    // carried over from the Electron server predates any entropy policy, and applying
    // the policy to it would fail the migration and lock the install out of every client
    // it has. An existing password is adopted as-is; the UI reports on its strength
    // instead. See PasswordPolicy — the gate is on new values only.
    case "password", "ngrok_key", "zrok_token", "zrok_reserved_token":
      break

    // Strings.
    case "server_address": try batch.set(Settings.serverAddress, to: raw)
    case "landing_page_path": try batch.set(Settings.landingPagePath, to: raw)
    case "private_api_mode":
      try batch.set(Settings.Legacy.privateAPIMode, to: raw.isEmpty ? "process-dylib" : raw)
    case "log_level": try batch.set(Settings.logLevel, to: raw.isEmpty ? "info" : raw)

    // Settings that now belong to a connection-method service rather than to the core.
    //
    // THIS is the part of the migration that has to be right. The Swift server's own
    // settings can be reset at will, but an Electron install's cannot: these are the
    // values a user typed once and has not thought about since — an ngrok auth token from
    // two years ago, a reserved zrok share whose name they no longer remember. Landing
    // them in the wrong place means a tunnel that silently stops working after an upgrade,
    // and the user has no way to know what it used to be.
    //
    // Written with `setDynamic` because the destination is a manifest field rather than a
    // compiled-in descriptor: `zrok_token` becomes
    // `app.bluebubbles.proxy.zrok.account_token`, which no `Setting<Value>` declares.
    case "ngrok_protocol":
      batch.setDynamic(raw.isEmpty ? "http" : raw, forKey: Legacy.ngrokProtocol, isSecret: false)
    case "ngrok_region":
      batch.setDynamic(raw.isEmpty ? "us" : raw, forKey: Legacy.ngrokRegion, isSecret: false)
    case "ngrok_custom_domain":
      batch.setDynamic(raw, forKey: Legacy.ngrokCustomDomain, isSecret: false)
    case "zrok_reserved_name":
      batch.setDynamic(raw, forKey: Legacy.zrokReservedName, isSecret: false)
    case "zrok_reserve_tunnel":
      batch.setDynamic(bool() ? "true" : "false", forKey: Legacy.zrokReserveTunnel, isSecret: false)

    // Enums, tolerating an unknown value by falling back to the default.
    // The connection method is a SERVICE IDENTIFIER now, not an enum case, so the
    // legacy value has to be translated rather than decoded. An unrecognised one falls
    // back to Cloudflare, which needs no account and no configuration — the safest place
    // to land someone whose old choice no longer exists.
    case "proxy_service":
      batch.setDynamic(
        Legacy.connectionMethod(forLegacyProxyService: raw),
        forKey: "connection_method",
        isSecret: false
      )
    case "auto_start_method":
      try batch.set(Settings.autoStartMethod, to: AutoStartMethod(rawValue: raw) ?? .none)
    case "auth_mode":
      try batch.set(Settings.authMode, to: AuthMode(rawValue: raw) ?? .password)
    case "event_payload_codec":
      try batch.set(Settings.eventPayloadCodec, to: PayloadCodecID(rawValue: raw) ?? .legacyV1)

    // Bools.
    case "use_custom_certificate": try batch.set(Settings.useCustomCertificate, to: bool())
    case "enable_private_api": try batch.set(Settings.enablePrivateAPI, to: bool())
    case "enable_ft_private_api": try batch.set(Settings.enableFaceTimePrivateAPI, to: bool())
    case "auto_caffeinate": try batch.set(Settings.autoCaffeinate, to: bool())
    case "start_minimized": try batch.set(Settings.startMinimized, to: bool())
    case "hide_dock_icon": try batch.set(Settings.hideDockIcon, to: bool())
    case "dock_badge": try batch.set(Settings.dockBadge, to: bool())
    case "auto_lock_mac": try batch.set(Settings.autoLockMac, to: bool())
    case "open_findmy_on_startup": try batch.set(Settings.openFindMyOnStartup, to: bool())
    case "start_via_terminal": try batch.set(Settings.Legacy.startViaTerminal, to: bool())
    case "headless": try batch.set(Settings.Legacy.headless, to: bool())
    case "disable_gpu": try batch.set(Settings.Legacy.disableGPU, to: bool())
    case "facetime_calling": try batch.set(Settings.Legacy.facetimeCalling, to: bool())
    case "check_for_updates": try batch.set(Settings.checkForUpdates, to: bool())
    case "auto_install_updates": try batch.set(Settings.Legacy.autoInstallUpdates, to: bool())
    case "tutorial_is_done": try batch.set(Settings.Legacy.tutorialIsDone, to: bool())
    case "rate_limit_enabled": try batch.set(Settings.rateLimitEnabled, to: bool())
    case "trust_local_network": try batch.set(Settings.trustLocalNetwork, to: bool())

    // Retired: force-disabled at startup today and superseded by the sealed-v2 codec.
    // Read so it does not show up as unknown, then dropped.
    case "encrypt_coms":
      break

    // Retired: the Electron UI painted its own chrome and needed to be told to go pure
    // black. This app uses the system appearance, so there is nothing for the flag to do
    // — carrying it forward would preserve a preference that controls nothing. Matched
    // here so an upgrading install does not log it as an unknown key.
    case "use_oled_dark_mode":
      break

    default:
      break
    }
  }
}

/// Where the Electron server's keys land now.
///
/// A table rather than logic scattered through the migration, because this is the ONE thing
/// in the whole settings layer that has to keep working forever: the Swift server's own
/// configuration can be reset at will, but an Electron install's cannot. These are values a
/// user typed once — an ngrok token from years ago, a reserved zrok share whose name they no
/// longer remember — and landing them in the wrong place produces a tunnel that silently
/// stops working after an upgrade, with nothing to tell them what it used to be.
///
/// Kept in one place so the mapping can be read, reviewed and tested as a unit. Adding a
/// service means adding rows here, not editing a switch in three places.
public enum Legacy {

  // MARK: - Destinations
  //
  // Fully qualified, matching each service's manifest. Written out literally rather than
  // assembled from `BuiltInManifests`, because this module cannot see that one — and
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

  public static let dynamicDNSAddress = "app.bluebubbles.proxy.dynamic-dns.address"

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

  /// Whether this legacy key has a destination in a service namespace.
  static func handles(_ key: String) -> Bool {
    secretDestinations[key] != nil
      || [
        "ngrok_protocol", "ngrok_region", "ngrok_custom_domain",
        "zrok_reserved_name", "zrok_reserve_tunnel",
        // Renamed rather than moved: `proxy_service` became `connection_method` and its
        // VALUE changed from an enum case to a service identifier. It is no longer in
        // `Settings.allKeys` under the old name, so without this the migration skipped it
        // as unknown and every upgrading install came back on the default connection
        // method — losing the one setting most likely to make the server unreachable.
        "proxy_service",
      ].contains(key)
  }

  /// The Electron `proxy_service` value -> the service that replaces it.
  public static func connectionMethod(forLegacyProxyService value: String) -> String {
    switch value.lowercased() {
    case "ngrok": "app.bluebubbles.proxy.ngrok"
    case "zrok": "app.bluebubbles.proxy.zrok"
    case "lan-url", "lan url", "lanurl": "app.bluebubbles.proxy.lan"
    case "dynamic-dns", "dynamic dns", "dns": "app.bluebubbles.proxy.dynamic-dns"
    case "cloudflare": "app.bluebubbles.proxy.cloudflare"
    // Unknown values land on Cloudflare, which needs no account and no configuration —
    // the safest place for someone whose old choice no longer exists.
    default: "app.bluebubbles.proxy.cloudflare"
    }
  }
}

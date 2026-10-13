//  ServerComposition+Storage
//  The long-lived storage every other object is built from, opened without a server.
//
//  Separate from the build because two callers need storage and nothing else: the
//  migration command, which exits once it has run, and the app, which has to know whether
//  a migration is pending before it starts anything. One `Storage` value is opened once and
//  handed on, because a second settings store would cache a table the first one writes.

import BBCore
import BBDiagnostics
import BBPersistence
import BBSettings
import Foundation
import Logging

extension ServerComposition {

  /// The long-lived storage every other object is built from.
  ///
  /// Split out of `build` so it can be opened WITHOUT building a server. Two callers need
  /// that: `bluebubbles-server --migrate`, which runs a migration and exits, and the app,
  /// which has to know whether a migration is pending before it decides to start anything.
  ///
  /// Opening it twice is not an option, which is why this is a value passed in rather than
  /// a second `AppDatabase.open`. The reason is the CACHE, not the lock: `SettingsStore`
  /// keeps the whole table in memory, so two
  /// stores would silently disagree after either one wrote.
  ///
  /// The lock is not a reason: `AppDatabase.open` sets `busyMode = .timeout(5)`, so a second
  /// connection would wait out a contended write rather than throw `SQLITE_BUSY`.
  public struct Storage: Sendable {
    public let logSink: FileSink
    public let logger: Logger
    public let appDatabase: AppDatabase
    /// The Keychain in production; a test passes what it likes.
    public let secrets: any SecretStore
    public let settings: SettingsStore
  }

  /// Opens storage and nothing else. Safe to call before deciding whether to start.
  ///
  /// `LoggingSystemBootstrap.bootstrap` is idempotent, so this sitting in front of a later
  /// `build(storage:options:)` costs nothing.
  public static func prepareStorage(options: Options = Options()) async throws -> Storage {
    // Bootstrapped before anything else logs, and to the SAME path the Electron server
    // uses: an operator debugging a migrated install should find one log file where
    // they expect it, not two. Held so `GET /server/logs` can tail it: without the sink,
    // that route has nothing to read and a client's log viewer goes blank.
    let logSink = LoggingSystemBootstrap.bootstrap(level: options.logLevel)
    let logger = Logger(label: "bluebubbles")

    // Before the first file in it is opened. `AppDatabase.open` creates the directory with
    // no attributes, which is how it came to be 0755 on every install — holding the push
    // tokens, the blocklist and the Firebase credentials.
    try ApplicationSupport.prepareOwnDirectory()
    for (item, error) in ApplicationSupport.adoptLegacyState() {
      logger.warning(
        "Could not move state a pre-release build left outside the support directory",
        metadata: ["item": .string(item), "error": .string(String(describing: error))])
    }

    let appDatabase = try AppDatabase.open(contributors: AppSchema.contributors)
    // Service name from `ApplicationSupport`, NOT the default, so a run redirected by
    // `BB_SUPPORT_DIRECTORY` cannot reach the real installation's credentials. See the
    // comment on `keychainService`.
    let secrets = KeychainSecretStore(service: ApplicationSupport.keychainService)
    for entry in options.malformedOverrides {
      // The key only, never the entry: an entry with no `=` may be a bare password.
      logger.warning(
        "A --set entry was not applied: it is not key=value",
        metadata: ["length": .stringConvertible(entry.count)])
    }
    let configFile = ConfigFile.read(at: options.configPath)
    // Logged, not fatal: the server starts even when its configuration is wrong, and the
    // log is what says which part of it was not applied.
    for problem in configFile.problems {
      logger.warning("Part of the configuration file was not applied: \(problem)")
    }
    let settings = try await SettingsStore(
      database: appDatabase,
      secrets: secrets,
      configFileValues: configFile.values,
      commandLineValues: options.overrides
    )

    // Raised to whatever the user asked for, as soon as the store can answer.
    //
    // After the store rather than at bootstrap, because the level LIVES in the store: the
    // handful of lines logged before this point are start-up chatter at the default level.
    // Without this the setting is read by nothing, so turning on debug logging does nothing
    // and gives no hint why.
    LoggingSystemBootstrap.setLevel(
      Settings.logLevel(from: await settings.get(Settings.logLevel))
    )

    return Storage(
      logSink: logSink, logger: logger, appDatabase: appDatabase,
      secrets: secrets, settings: settings
    )
  }
}

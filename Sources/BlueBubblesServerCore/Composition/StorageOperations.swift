//  StorageOperations
//  The things a front end does with storage before, or instead of, building a server.
//
//  Adopting an Electron install, exporting this server and importing an archive all run on
//  `ServerComposition.Storage` and nothing else, from both the app and the CLI. They are
//  built here, once, from the storage itself: built at each call site by copying fields out,
//  a collaborator added to one has to be remembered at every site, and the site that forgets
//  still compiles. `FrontEndPlumbingPolicyTests` refuses a hand-built one in either front end.
//
//  The recovery command's smaller storage is here for the same reason: it is the one other
//  way a front end opens `app.db`, and its differences from `prepareStorage` are decisions
//  that belong beside it rather than in the command.

import BBCore
import BBExport
import BBPersistence
import BBSettings
import Foundation

extension ServerComposition.Storage {

  /// An exporter over this server's own database and settings.
  ///
  /// The version it records is informational only (see `ExportManifest`): a CLI run from
  /// `.build` has no bundle to read one from and records the development marker rather than
  /// failing, because nothing branches on it.
  public func exporter() -> ServerExporter {
    ServerExporter(
      database: appDatabase, settings: settings, serverVersion: AppVersion.current,
      logger: logger)
  }

  /// An importer into this server's own database and settings.
  public func importer() -> ServerImporter {
    ServerImporter(database: appDatabase, settings: settings, logger: logger)
  }

  /// Runs one migration step against this storage and records its outcome. Whether it
  /// SHOULD run is the caller's decision; see `MigrationRunner.run`.
  public func runMigration(_ step: MigrationStep) async -> MigrationRunner.StepReport {
    await MigrationRunner.run(
      step, settings: settings, secrets: secrets, database: appDatabase, logger: logger)
  }
}

extension ServerComposition {

  /// The database and settings a recovery command needs, opened to run BESIDE a live
  /// server, and so less than `prepareStorage` opens.
  ///
  /// No log sink: bootstrapping one is a second writer appending to, and rotating, the file
  /// the running server is writing. And no Keychain: the store is opened only to read plain
  /// switches, and a recovery path that raised a Keychain access panel would stall the one
  /// command a locked-out person reaches for. Everything else is `prepareStorage`'s, so the
  /// command reads what a start would: the support directory prepared the same way, and
  /// the config file and `--set` layered over the database, so a switch set in either is
  /// honoured here as it is by the server.
  public static func prepareRecoveryStorage(
    options: Options = Options()
  ) async throws -> (database: AppDatabase, settings: SettingsStore) {
    try ApplicationSupport.prepareOwnDirectory()
    let database = try AppDatabase.open(contributors: AppSchema.contributors)
    let settings = try await SettingsStore(
      database: database,
      secrets: InMemorySecretStore(),
      configFileValues: ConfigFile.load(at: options.configPath),
      commandLineValues: options.overrides
    )
    return (database, settings)
  }
}

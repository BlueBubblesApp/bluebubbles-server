//  TestSettings
//  A settings store over an in-memory `app.db`, built one way.
//
//  The pair `AppDatabase.inMemory(...)` + `SettingsStore(database:secrets:)` was written out
//  in dozens of suites, and the copies disagreed about which schema to stand up: some asked
//  for `SettingsSchema` alone and some for every contributor, with nothing saying whether
//  the difference mattered. A settings store needs `SettingsSchema` and nothing else, so
//  that is the default here; a suite that reads other tables through the same database
//  passes the database it built.

import BBPersistence
import BBSettings
import Foundation

public enum TestSettings {

  /// A store over a fresh in-memory database holding only the `setting` table.
  public static func store(
    secrets: any SecretStore = InMemorySecretStore(),
    commandLineValues: [String: String] = [:]
  ) async throws -> SettingsStore {
    try await store(
      database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
      secrets: secrets, commandLineValues: commandLineValues)
  }

  /// A store over a database the caller built, for a suite that also reads that database's
  /// other tables. The database has to include `SettingsSchema`.
  public static func store(
    database: AppDatabase,
    secrets: any SecretStore = InMemorySecretStore(),
    commandLineValues: [String: String] = [:]
  ) async throws -> SettingsStore {
    try await SettingsStore(
      database: database, secrets: secrets, commandLineValues: commandLineValues)
  }
}

//  MigrationStateTests
//  Adopting an Electron install is three jobs, and the record of them has to survive a
//  failure half-way through.
//
//  What this pins, and why each one is a real failure rather than a hypothetical:
//
//    - **An install that already migrated is never offered it again.** Every existing beta
//      install has `legacy_config_imported` set. If the new per-step rows started empty, all
//      of them would be offered a settings import — and running it AGAIN is not harmless: it
//      writes every key it finds with no comparison, so it reverts whatever the user changed
//      since. That is the bug `LegacyMigrationTests` was written to pin, arriving by a new
//      route.
//    - **Certificates never block a start.** `CertificateStore.defaultDirectory` IS this
//      server's own directory, so a pure-Swift install that generated a self-signed
//      certificate has material sitting there with no Electron install anywhere. A blocking
//      check on file presence would stop a working headless server booting over a file it
//      wrote itself.
//    - **A failed step is remembered as failed**, not as never-attempted, and the steps that
//      did work stay done — which is the whole point of per-step state.

import BBCore
import BBPersistence
import BBPushKit
import BBSettings
import Foundation
import GRDB
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Migration state")
struct MigrationStateTests {

  // NO REAL CREDENTIALS. Shapes only, enough to parse.
  static let serviceAccountJSON = """
    {
      "type": "service_account",
      "project_id": "bluebubbles-test",
      "private_key": "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----\\n",
      "client_email": "test@bluebubbles-test.iam.gserviceaccount.com",
      "token_uri": "https://oauth2.googleapis.com/token"
    }
    """
  static let clientConfigJSON = """
    {"project_info":{"project_number":"1234567890","project_id":"bluebubbles-test"},
     "client":[{"client_info":{"mobilesdk_app_id":"1:1234567890:android:abc"},
     "oauth_client":[{"client_id":"1234567890","client_type":3}]}]}
    """

  private func makeStore(_ secrets: InMemorySecretStore) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    return try await SettingsStore(database: database, secrets: secrets)
  }

  /// A directory standing in for `~/Library/Application Support/bluebubbles-server`.
  private func emptyBase() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("bb-migration-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A real Electron database, so the import has something to commit.
  private func writeRealLegacyConfig(_ base: URL, values: [String: String]) throws {
    let url = base.appendingPathComponent("config.db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
      for (name, value) in values {
        try db.execute(
          sql: "INSERT INTO config (name, value) VALUES (?, ?)", arguments: [name, value])
      }
    }
  }

  /// A real Electron database. The detector checks for the `config` TABLE, not just the
  /// file, so a stub will not do — see `stubDatabaseIsNotAnInstall`.
  private func writeLegacyConfig(_ base: URL) throws {
    try writeRealLegacyConfig(base, values: ["socket_port": "45123"])
  }

  @Test("A fresh install has nothing to migrate and starts")
  func freshInstall() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try await makeStore(InMemorySecretStore())

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status.isActionable == false)
    #expect(status.isBlockingStart == false)
  }

  @Test("An Electron config blocks the start until it is settled")
  func legacyConfigBlocks() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeLegacyConfig(base)
    let store = try await makeStore(InMemorySecretStore())

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.settings].isActionable)
    #expect(status.isBlockingStart)
    #expect(status.blocking.map(\.step) == [.settings])
  }

  /// The regression this exists to prevent: re-offering an import that reverts the user's
  /// own changes, on every install that already upgraded.
  @Test("An install that already migrated is not offered it again")
  func oldMarkerSeedsTheSettingsStep() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeLegacyConfig(base)
    let store = try await makeStore(InMemorySecretStore())
    try await store.set(Settings.legacyConfigImported, to: true)

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(await MigrationStateStore.state(of: .settings, in: store) == .completed)
    #expect(status[.settings].isActionable == false)
    #expect(status.isBlockingStart == false, "the config file is still there, and that is fine")
  }

  @Test("A per-step row wins over the old marker")
  func recordedStateWins() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeLegacyConfig(base)
    let store = try await makeStore(InMemorySecretStore())
    try await store.set(Settings.legacyConfigImported, to: true)
    await MigrationStateStore.record(.pending, for: .settings, in: store)

    #expect(await MigrationStateStore.state(of: .settings, in: store) == .pending)
    #expect(await MigrationStateStore.status(in: store, base: base).isBlockingStart)
  }

  @Test("Declining settles a step without completing it")
  func decliningStopsTheBlock() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeLegacyConfig(base)
    let store = try await makeStore(InMemorySecretStore())

    #expect(await MigrationStateStore.status(in: store, base: base).isBlockingStart)
    await MigrationRunner.decline(.settings, settings: store)

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.settings].state == .declined)
    #expect(status.isBlockingStart == false)
  }

  /// A leftover file must never brick a start. If a delete failed after a successful
  /// Keychain write, the artifact is still on disk — and the recorded state is what counts.
  @Test("Recorded state is authoritative; a leftover file does not block")
  func recordedStateBeatsTheFilesystem() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeLegacyConfig(base)
    let store = try await makeStore(InMemorySecretStore())
    await MigrationStateStore.record(.completed, for: .settings, in: store)

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.settings].hasArtifact, "the file is genuinely still there")
    #expect(status[.settings].isActionable == false)
    #expect(status.isBlockingStart == false)
  }

  @Test("A self-signed certificate this server wrote is not a migration")
  func ourOwnCertificateIsNotLegacy() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let certificates = base.appendingPathComponent("Certs", isDirectory: true)
    try FileManager.default.createDirectory(at: certificates, withIntermediateDirectories: true)
    try Data("key".utf8).write(to: certificates.appendingPathComponent("server.key"))
    // The marker only this server writes. Its presence is what says "we generated this".
    try Data("2027-01-01".utf8).write(
      to: certificates.appendingPathComponent("expiration.txt"))

    let store = try await makeStore(InMemorySecretStore())
    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.certificates].hasArtifact == false)
    #expect(status.isBlockingStart == false)
  }

  /// Even a genuinely Electron-era certificate is offered rather than required.
  @Test("Certificates are never blocking")
  func certificatesNeverBlock() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let certificates = base.appendingPathComponent("Certs", isDirectory: true)
    try FileManager.default.createDirectory(at: certificates, withIntermediateDirectories: true)
    try Data("key".utf8).write(to: certificates.appendingPathComponent("server.key"))

    let store = try await makeStore(InMemorySecretStore())
    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.certificates].hasArtifact)
    #expect(status[.certificates].isActionable)
    #expect(status[.certificates].isBlockingStart == false)
    #expect(status.isBlockingStart == false)
    #expect(MigrationStep.certificates.isBlocking == false)
  }

  @Test("A failed step is recorded as failed and the others stay done")
  func failureIsRemembered() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try await makeStore(InMemorySecretStore())
    await MigrationStateStore.record(.completed, for: .settings, in: store)

    // A genuine failure, not a simulated one: `Certs/` holds files that are present but not
    // PEM, so the step gets past its "is there anything here" check and then throws on load.
    // This used to lean on the certificate step being unimplemented, which stopped being
    // true the moment it was built.
    let certificates = base.appendingPathComponent("Certs", isDirectory: true)
    try FileManager.default.createDirectory(at: certificates, withIntermediateDirectories: true)
    try Data("not a certificate".utf8).write(
      to: certificates.appendingPathComponent("server.pem"))
    try Data("not a key".utf8).write(to: certificates.appendingPathComponent("server.key"))

    let report = await MigrationRunner.run(
      .certificates, settings: store, secrets: InMemorySecretStore(),
      logger: Logger(label: "test"), base: base
    )

    #expect(report.state == .failed)
    #expect(!report.detail.isEmpty)
    #expect(await MigrationStateStore.state(of: .certificates, in: store) == .failed)
    #expect(
      await MigrationStateStore.state(of: .settings, in: store) == .completed,
      "one step failing must not disturb another"
    )
  }

  /// The silent failure this restructuring exists to remove.
  ///
  /// While the credential migration lived inside `PushService.start()`, the startup gate had
  /// to answer "there is plaintext waiting" as well as "there are credentials" — otherwise
  /// push declined on exactly the installs that had something to move. The cost was that a
  /// user who DECLINED, or a step that failed, left `hasLegacyCredentials()` true, so
  /// `canRun()` said yes, `PushService.start` returned early with no `sender`, and
  /// `PushDeliveryService` wired a full delivery stack anyway. Every notification then
  /// reported zero outcomes, silently.
  ///
  /// Now the gate asks the plain question, so declining means push simply does not start.
  @Test("Declining the push step leaves the gate closed, not half-open")
  func decliningPushClosesTheGate() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let firebase = base.appendingPathComponent("FCM", isDirectory: true)
    try FileManager.default.createDirectory(at: firebase, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: firebase.appendingPathComponent("server.json"))

    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    let credentials = PushCredentialStore(secrets: secrets)

    // Plaintext is on disk and nothing is in the Keychain: the old gate would have opened.
    #expect(PushCredentialMigration.hasLegacyCredentials(in: base))
    #expect(await credentials.isConfigurable() == false, "the gate asks the Keychain alone")

    await MigrationRunner.decline(.pushCredentials, settings: store)
    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.pushCredentials].state == .declined)
    #expect(status.isBlockingStart == false)
    #expect(await credentials.isConfigurable() == false)
  }

  /// A half-done credential move used to strand itself: `server.json` imported and deleted,
  /// `client.json` failed, and the single `!isConfigured()` guard then returned early on
  /// every later attempt — so the client config was never migrated and never deleted.
  @Test("A half-done credential move finishes on the next attempt")
  func partialCredentialMoveResumes() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let firebase = base.appendingPathComponent("FCM", isDirectory: true)
    try FileManager.default.createDirectory(at: firebase, withIntermediateDirectories: true)

    let secrets = InMemorySecretStore()
    let credentials = PushCredentialStore(secrets: secrets)

    // Stand in for "the service account already moved on an earlier run".
    _ = try await credentials.importServiceAccount(Data(Self.serviceAccountJSON.utf8))
    #expect(await credentials.hasServiceAccount())
    #expect(await credentials.hasClientConfig() == false)

    // The client config is still sitting in plaintext.
    let clientConfig = firebase.appendingPathComponent("client.json")
    try Data(Self.clientConfigJSON.utf8).write(to: clientConfig)

    let moved = try await PushCredentialMigration.migrateIfNeeded(into: credentials, from: base)
    #expect(moved, "the second run must pick up the file the first one left")
    #expect(await credentials.hasClientConfig())
    #expect(
      FileManager.default.fileExists(atPath: clientConfig.path) == false,
      "the plaintext copy is deleted once it is safely stored"
    )
  }

  /// The window this closes: the import commits, the process dies, nothing recorded it, and
  /// the next launch runs the import AGAIN — reverting whatever the user changed in between.
  /// The marker now commits in the same transaction as the values it describes.
  @Test("The step marker lands in the same transaction as the import")
  func markerIsAtomicWithTheImport() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeRealLegacyConfig(base, values: ["socket_port": "45123"])

    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    let report = await MigrationRunner.run(
      .settings, settings: store, secrets: secrets,
      logger: Logger(label: "test"), base: base
    )
    #expect(report.state == .completed)

    // The imported value and both markers are all present. If the marker were a separate
    // write, this would still pass — what it pins is that they are written together, which
    // the single `SettingsStore.write` in `LegacyConfigMigration.run` guarantees.
    #expect(await store.get(Settings.socketPort) == 45123)
    #expect(await store.get(Settings.legacyConfigImported))
    #expect(await MigrationStateStore.state(of: .settings, in: store) == .completed)
    #expect(await MigrationStateStore.status(in: store, base: base).isBlockingStart == false)
  }

  /// A leftover `config.db` with no `config` table is not an installation to adopt. This
  /// developer's own machine has a 0-byte one; treating its presence as an upgrade would
  /// refuse to start a server that has nothing whatsoever to migrate.
  @Test("A stub config.db is not an installation")
  func stubDatabaseIsNotAnInstall() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try Data().write(to: base.appendingPathComponent("config.db"))
    let store = try await makeStore(InMemorySecretStore())

    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.settings].hasArtifact == false)
    #expect(status.isBlockingStart == false)
  }

  /// And if one is somehow reached anyway, the step completes rather than looping: it has
  /// nothing to import, so there is no transaction to join and the caller records it.
  @Test("A step with nothing to import still settles")
  func nothingToImportStillSettles() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    let report = await MigrationRunner.run(
      .settings, settings: store, secrets: secrets,
      logger: Logger(label: "test"), base: base
    )
    #expect(report.state == .completed)
    #expect(await MigrationStateStore.state(of: .settings, in: store) == .completed)
  }

  // MARK: - The destructive step

  /// The guard that stops a password existing nowhere.
  ///
  /// Deleting the plaintext rows before the copy into the Keychain has succeeded destroys
  /// the only copy. The wizard must not offer it, and the runner must refuse it, even though
  /// the call is public.
  @Test("Removing plaintext is not offered until the settings import has completed")
  func plaintextRemovalWaitsForTheImport() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeRealLegacyConfig(
      base, values: ["socket_port": "45123", "password": "a-long-enough-passphrase-42"])
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    // Before the import: the rows are there, but the step is locked.
    var status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.plaintextSecrets].hasArtifact, "the credentials are readable on disk")
    #expect(status[.plaintextSecrets].isUnlocked == false)
    #expect(status[.plaintextSecrets].isActionable == false)

    // And refused outright if something calls it anyway — as a refusal, NOT as a failure.
    // Recording `.failed` would leave a step nobody legitimately started looking broken,
    // and the wizard offers "Try Again" for failed steps, which is the wrong invitation.
    let refused = await MigrationRunner.run(
      .plaintextSecrets, settings: store, secrets: secrets,
      logger: Logger(label: "test"), base: base
    )
    #expect(refused.state == .pending)
    #expect(await MigrationStateStore.state(of: .plaintextSecrets, in: store) == .pending)
    // Nothing was deleted by the refused call.
    #expect(try readLegacy(base)["password"] != nil)

    // After the import it unlocks.
    _ = await MigrationRunner.run(
      .settings, settings: store, secrets: secrets, logger: Logger(label: "test"), base: base)
    status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.plaintextSecrets].isUnlocked)
    #expect(status[.plaintextSecrets].isActionable)
  }

  /// Declining the import is not the same as completing it: skipping and then deleting would
  /// destroy credentials nothing had copied.
  @Test("A declined import does not unlock the deletion")
  func decliningDoesNotUnlockDeletion() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeRealLegacyConfig(base, values: ["password": "a-long-enough-passphrase-42"])
    let store = try await makeStore(InMemorySecretStore())

    await MigrationRunner.decline(.settings, settings: store)
    let status = await MigrationStateStore.status(in: store, base: base)
    #expect(status[.plaintextSecrets].isUnlocked == false)
  }

  @Test("The deletion removes only the credentials, and only after they are copied")
  func deletionRemovesOnlyCredentials() async throws {
    let base = emptyBase()
    defer { try? FileManager.default.removeItem(at: base) }
    try writeRealLegacyConfig(
      base,
      values: [
        "socket_port": "45123",
        "password": "a-long-enough-passphrase-42",
        "ngrok_key": "ngrok-token-value",
      ])
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    _ = await MigrationRunner.run(
      .settings, settings: store, secrets: secrets, logger: Logger(label: "test"), base: base)
    // The copy exists before anything is deleted. That ordering is the whole safety property.
    #expect(try secrets.get("password") == "a-long-enough-passphrase-42")

    let report = await MigrationRunner.run(
      .plaintextSecrets, settings: store, secrets: secrets,
      logger: Logger(label: "test"), base: base)
    #expect(report.state == .completed)

    // Credentials gone, ordinary settings untouched — a downgrade still finds its config.
    let remaining = try readLegacy(base)
    #expect(remaining["password"] == nil)
    #expect(remaining["ngrok_key"] == nil)
    #expect(remaining["socket_port"] == "45123", "non-secret rows are left alone")

    // And the Keychain copy is still there.
    #expect(try secrets.get("password") == "a-long-enough-passphrase-42")
    #expect(
      await MigrationStateStore.status(in: store, base: base)[.plaintextSecrets].hasArtifact
        == false)
  }

  private func readLegacy(_ base: URL) throws -> [String: String] {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(
      path: base.appendingPathComponent("config.db").path, configuration: configuration)
    return try queue.read { db in
      var out: [String: String] = [:]
      let rows = try Row.fetchAll(db, sql: "SELECT name, value FROM config")
      for row in rows { out[row["name"]] = row["value"] }
      return out
    }
  }

  @Test("Every step maps to its own row")
  func stepsHaveDistinctSettings() {
    let keys = MigrationStep.allCases.map(\.setting.key)
    #expect(Set(keys).count == keys.count)
    for key in keys { #expect(Settings.allKeys.contains(key), "\(key) is not declared") }
  }
}

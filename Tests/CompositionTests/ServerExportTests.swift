//  ServerExportTests
//  Exporting a server and reading it back.
//
//  Two properties carry most of the weight here, and neither is "the round trip works".
//
//  **Secrets cannot leave without the password, and a server that has none cannot export
//  them at all.** An empty password is the shipped default, so allowing it would mean the
//  least configured servers produce the most dangerous files.
//
//  **A setting that describes the server it came from must not travel.** `server_address` is
//  written by the connection method and an imported one points clients at nothing; the
//  `migration_*` keys would tell a server it has already adopted an installation it has
//  never seen. Those are checked on the way out AND on the way in, because an archive is a
//  file from outside this server.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAppStore
import BBAuth
import BBBuiltIns
import BBPersistence
import BBServiceKit
import BBTestSupport
import BlueBubblesServerCore
import Foundation
import GRDB
import Logging
import Testing

// `@testable` for `SecretsEnvelope.seal(_:withServerPassword:randomBytes:)`, the seam that lets
// a test make the system's random generator refuse.
@testable import BBExport
// `@testable` for `Settings.hidden`, the settings with no row, which the portability
// classification is held to.
@testable import BBSettings

/// A Keychain that refuses to store the keys it is given, standing in for a locked login
/// keychain or a prompt the person dismissed.
private final class RefusingKeychain: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: String] = [:]
  private let refusing: Set<String>

  struct Refused: Error {}

  init(refusing: Set<String>) { self.refusing = refusing }

  func get(_ key: String) throws -> String? { lock.withLock { storage[key] } }

  func set(_ key: String, value: String) throws {
    try lock.withLock {
      if refusing.contains(key) { throw Refused() }
      storage[key] = value
    }
  }

  func delete(_ key: String) throws { lock.withLock { storage[key] = nil } }
}

@Suite("Server export", .serialized)
struct ServerExportTests {

  private let logger = Logger(label: "bluebubbles.test.export")

  private func harness() async throws -> (AppDatabase, SettingsStore, URL) {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await TestSettings.store(database: database)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-export-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (database, settings, root)
  }

  private func exporter(_ database: AppDatabase, _ settings: SettingsStore) -> ServerExporter {
    ServerExporter(
      database: database, settings: settings, services: BuiltInManifests.all,
      serverVersion: "test", logger: logger)
  }

  private func importer(_ database: AppDatabase, _ settings: SettingsStore) -> ServerImporter {
    ServerImporter(
      database: database, settings: settings, services: BuiltInManifests.all, logger: logger)
  }

  // MARK: The round trip

  @Test("Settings and webhooks survive an export and an import into a fresh server")
  func roundTrip() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }

    try await sourceSettings.set(Settings.socketPort, to: 8080)
    try await sourceSettings.set(Settings.connectionMethod, to: "app.bluebubbles.proxy.ngrok")
    _ = try await WebhookRepository(database: source).upsert(
      url: "https://hooks.example.com/a", events: ["new-message"])

    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings, .webhooks], to: root)
    #expect(FileManager.default.fileExists(atPath: report.url.path))
    #expect(report.url.lastPathComponent.hasPrefix("bluebubbles-export-"))
    #expect(report.url.pathExtension == "zip")

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(Set(inspection.sections) == [.settings, .webhooks])
    #expect(!inspection.hasSealedSections)

    _ = try await importer.apply(inspection, sections: [.settings, .webhooks])
    #expect(await targetSettings.get(Settings.socketPort) == 8080)
    #expect(
      await targetSettings.get(Settings.connectionMethod) == "app.bluebubbles.proxy.ngrok")
    let webhooks = try await WebhookRepository(database: target).all()
    #expect(webhooks.map(\.url) == ["https://hooks.example.com/a"])
  }

  /// Both sections read their tables generically, and the reader took every column as
  /// text: GRDB traps on an INTEGER column read that way, so exporting either one
  /// terminated the server. Contacts also left their addresses behind, and dropped every
  /// `id` on the way in, which is a contact's identity, so the import failed on every row.
  @Test("Contacts and access control survive an export and an import into a fresh server")
  func genericSectionsRoundTrip() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }

    try await source.write { db in
      try db.execute(
        sql: """
          INSERT INTO contact (id, source, first_name, last_name, updated_at)
          VALUES ('contact-1', 2, 'Test', 'Person', '2026-01-01 00:00:00.000')
          """)
      try db.execute(
        sql: """
          INSERT INTO contact_address (normalized, reversed, kind, contact_id)
          VALUES ('+12025550143', '34105520212+', 0, 'contact-1'),
                 ('someone@example.com', 'moc.elpmaxe@enoemos', 1, 'contact-1')
          """)
      try db.execute(
        sql: """
          INSERT INTO contact_disabled (contact_id, disabled_at)
          VALUES ('contact-1', '2026-01-02 00:00:00.000')
          """)
      try db.execute(
        sql: """
          INSERT INTO blocked_client (address, reason, failure_count, first_seen_at, last_seen_at,
            blocked_at, is_permanent)
          VALUES ('192.0.2.10', 'too many failures', 12, '2026-01-01 00:00:00.000',
            '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO allowed_client (cidr, note, created_at)
          VALUES ('198.51.100.0/24', NULL, '2026-01-01 00:00:00.000')
          """)
    }

    let report = try await exporter(source, sourceSettings).export(
      sections: [.contacts, .accessControl], to: root)
    #expect(report.counts[.contacts] == 1)
    #expect(report.counts[.accessControl] == 2)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.counts[.contacts] == 1, "addresses are not more contacts")
    _ = try await importer.apply(inspection, sections: [.contacts, .accessControl])

    try await target.read { db in
      let contact = try #require(try Row.fetchOne(db, sql: "SELECT * FROM contact"))
      #expect(contact["id"] as String? == "contact-1")
      #expect(contact["source"] as Int? == 2)
      #expect(
        try String.fetchAll(
          db,
          sql: "SELECT normalized FROM contact_address WHERE contact_id = 'contact-1' "
            + "ORDER BY normalized")
          == ["+12025550143", "someone@example.com"])
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM contact_disabled") == 1)

      let blocked = try #require(try Row.fetchOne(db, sql: "SELECT * FROM blocked_client"))
      #expect(blocked["address"] as String? == "192.0.2.10")
      #expect(blocked["failure_count"] as Int? == 12)
      #expect(blocked["is_permanent"] as Bool? == true)
      let allowed = try #require(try Row.fetchOne(db, sql: "SELECT * FROM allowed_client"))
      #expect(allowed["cidr"] as String? == "198.51.100.0/24")
      #expect((allowed["note"] as DatabaseValue).isNull)
    }
  }

  /// The access-control rows are decoded into records on the way in, which is what lets a
  /// running server take them. A value of the wrong kind has to refuse the section, with
  /// both lists as they were, rather than reach GRDB's trapping subscript.
  @Test("A hand-edited access-control row is refused and leaves both lists alone")
  func malformedAccessControlRowIsRefused() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceAccess = AccessControlService(persistence: AccessControlStore(database: source))
    await sourceAccess.blockPermanently(address: "192.0.2.20", reason: "in the archive")
    await sourceAccess.flushPersistedState()
    let report = try await exporter(source, sourceSettings).export(
      sections: [.accessControl], to: root)

    let (target, targetSettings, _) = try await harness()
    let targetAccess = AccessControlService(persistence: AccessControlStore(database: target))
    await targetAccess.blockPermanently(address: "192.0.2.10", reason: "this server's own")
    await targetAccess.flushPersistedState()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    let file = inspection.directory.appendingPathComponent(ExportSection.accessControl.fileName)
    var groups = try #require(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any])
    var blocked = try #require(groups["blocked"] as? [[String: Any]])
    blocked[0]["failure_count"] = "lots"
    groups["blocked"] = blocked
    try JSONSerialization.data(withJSONObject: groups).write(to: file)

    await #expect(throws: (any Error).self) {
      _ = try await importer.apply(inspection, sections: [.accessControl])
    }
    let stored = try await AccessControlStore(database: target).loadAccessControl()
    #expect(stored.blocked.map(\.address) == ["192.0.2.10"])
  }

  @Test("Only the ticked sections are written")
  func selectionIsHonoured() async throws {
    let (source, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await WebhookRepository(database: source).upsert(
      url: "https://hooks.example.com/a", events: ["*"])

    let report = try await exporter(source, settings).export(sections: [.settings], to: root)
    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.sections == [.settings])
  }

  // MARK: Secrets

  @Test("A server with no password cannot export secrets")
  func noPasswordNoSecrets() async throws {
    // The shipped default is an empty password, so this is the state a fresh install sits
    // in. Refused rather than exported in the clear, and refused rather than quietly
    // dropped: somebody who ticked the box must not end up believing they have a backup of
    // something they do not.
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SecretsEnvelope.Failure.noServerPassword) {
      _ = try await exporter(database, settings).export(
        sections: [.settings, .secrets], to: root, serverPassword: "")
    }
  }

  @Test("Exporting secrets needs THIS server's password, not just any password")
  func secretsNeedTheRealPassword() async throws {
    // "Is a password set" and "is this that password" are two questions, and only checking
    // the first would let anybody with a shell on this Mac encrypt the credentials under a
    // password of their choosing and walk away with a file they can open.
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await settings.set(Settings.password, to: "a-long-enough-passphrase-42")

    await #expect(throws: SecretsEnvelope.Failure.wrongPassword) {
      _ = try await exporter(database, settings).export(
        sections: [.secrets], to: root, serverPassword: "something-else-entirely-99")
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "a refused export still wrote a file")
  }

  @Test("Secrets travel encrypted and need the same password back")
  func secretsRoundTrip() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let password = "a-long-enough-passphrase-42"
    try await sourceSettings.set(Settings.password, to: password)

    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: password)

    // The archive must not carry the password anywhere a search would find it.
    let raw = try Data(contentsOf: report.url)
    #expect(
      raw.range(of: Data(password.utf8)) == nil,
      "the password appears in the archive in the clear")

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.hasSealedSections)

    _ = try await importer.apply(
      inspection, sections: [.secrets], serverPassword: password)
    #expect(await targetSettings.get(Settings.password) == password)
  }

  @Test("The wrong password does not open the secrets")
  func wrongPasswordIsRefused() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: "a-long-enough-passphrase-42")
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: "a-long-enough-passphrase-42")

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    await #expect(throws: SecretsEnvelope.Failure.wrongPasswordOrDamaged) {
      _ = try await importer.apply(
        inspection, sections: [.secrets], serverPassword: "not-the-right-one")
    }
    #expect(await targetSettings.get(Settings.password).isEmpty, "a failed open wrote anyway")
  }

  @Test("Importing secrets without a password is refused before anything is read")
  func secretsNeedAPassword() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: "a-long-enough-passphrase-42")
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: "a-long-enough-passphrase-42")

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    await #expect(throws: ServerImporter.Failure.passwordRequired) {
      _ = try await importer.apply(inspection, sections: [.secrets])
    }
  }

  // MARK: An envelope is a file from outside

  /// A real secrets export, inspected and ready to be tampered with, plus its password.
  private func secretsArchive() async throws -> (
    ServerImporter, ServerImporter.Inspection, SettingsStore, String, URL
  ) {
    let (source, sourceSettings, root) = try await harness()
    let password = "a-long-enough-passphrase-42"
    try await sourceSettings.set(Settings.password, to: password)
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: password)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    return (importer, inspection, targetSettings, password, root)
  }

  private func secretsFile(_ inspection: ServerImporter.Inspection) -> URL {
    inspection.directory.appendingPathComponent(ExportSection.secrets.fileName)
  }

  /// Rewrites the envelope's iteration count the way a hand-crafted archive would.
  private func setIterations(_ count: Int, in inspection: ServerImporter.Inspection) throws {
    let url = secretsFile(inspection)
    var object = try #require(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    object["iterations"] = count
    try JSONSerialization.data(withJSONObject: object).write(to: url)
  }

  @Test("The count this server writes is one it will read back")
  func writtenIterationsAreAccepted() {
    #expect(SecretsEnvelope.acceptedIterations.contains(SecretsEnvelope.iterations))
  }

  /// A single round would derive a key at the speed of one hash, and is no export's.
  @Test("An envelope asking for too few rounds is refused, not derived")
  func tooFewIterationsAreRefused() async throws {
    let (importer, inspection, settings, password, root) = try await secretsArchive()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: inspection.directory)
    }
    try setIterations(1, in: inspection)

    await #expect(throws: SecretsEnvelope.Failure.implausibleIterations(1)) {
      _ = try await importer.apply(inspection, sections: [.secrets], serverPassword: password)
    }
    #expect(await settings.get(Settings.password).isEmpty, "a refused envelope wrote anyway")
  }

  /// The count is the file's to state; without a ceiling, two billion rounds hold an import
  /// for hours. Just past the ceiling here, so a regression fails in seconds, not hours.
  @Test("An envelope asking for too many rounds is refused before deriving anything")
  func tooManyIterationsAreRefused() async throws {
    let (importer, inspection, _, password, root) = try await secretsArchive()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: inspection.directory)
    }
    let excessive = SecretsEnvelope.acceptedIterations.upperBound + 1
    try setIterations(excessive, in: inspection)

    await #expect(throws: SecretsEnvelope.Failure.implausibleIterations(excessive)) {
      _ = try await importer.apply(inspection, sections: [.secrets], serverPassword: password)
    }
  }

  /// A refused generator leaves the salt all zeroes, and sealing under it would produce a file
  /// that looks protected and shares its key with every other such file.
  @Test("Sealing refuses when the system cannot provide random bytes")
  func randomFailureIsAnError() {
    #expect(throws: SecretsEnvelope.Failure.randomUnavailable(-1)) {
      _ = try SecretsEnvelope.seal(
        Data("{}".utf8), withServerPassword: "a-long-enough-passphrase-42",
        randomBytes: { _ in -1 })
    }
  }

  /// The envelope proves who sealed the file, not what is in it. Its map is written key by
  /// key through each key's own writer, as the settings section is.
  @Test("Imported secrets are only keys an export seals, held to the rules a write applies")
  func forgedSecretsAreFiltered() async throws {
    let (importer, inspection, settings, password, root) = try await secretsArchive()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: inspection.directory)
    }
    try await settings.set(Settings.serverAddress, to: "http://10.0.0.5:1234")

    // Sealed under the right password, so only the CONTENT is wrong.
    let forged: [String: String] = [
      // Declared secret, refused by the password policy a person setting it would meet.
      Settings.password.key: "abc",
      // Declared secret, and empty: a request to clear it, which no export makes.
      Settings.licenseKey.key: "",
      // Confidential, but describes this server, so no section's to write.
      Settings.serverAddress.key: "https://attacker.example.com",
      // Not a setting.
      "made_up_key": "anything",
      // The one that is fine.
      Settings.ntfyToken.key: "tk_example_token",
    ]
    let envelope = try SecretsEnvelope.seal(
      try JSONEncoder().encode(forged), withServerPassword: password)
    try JSONEncoder().encode(envelope).write(to: secretsFile(inspection))

    let report = try await importer.apply(
      inspection, sections: [.secrets], serverPassword: password)

    #expect(report.counts[.secrets] == 1)
    #expect(report.failedSettings.isEmpty)
    let reasons = Dictionary(
      uniqueKeysWithValues: report.skippedSettings.map { ($0.key, $0.reason) })
    #expect(
      Set(reasons.keys) == [
        Settings.password.key, Settings.licenseKey.key, Settings.serverAddress.key,
        "made_up_key",
      ])
    // Each with WHY, because the four are different news to the person reading them.
    if case .refused(let sentence) = reasons[Settings.password.key] {
      #expect(!sentence.isEmpty)
    } else {
      Issue.record("a password the policy refused was not reported as refused")
    }
    #expect(reasons[Settings.licenseKey.key] == .malformed)
    #expect(reasons[Settings.serverAddress.key] == .describesAnotherServer)
    #expect(reasons["made_up_key"] == .notExported)
    #expect(await settings.get(Settings.ntfyToken) == "tk_example_token")
    #expect(await settings.get(Settings.password).isEmpty, "a refused password was stored")
    #expect(
      await settings.get(Settings.serverAddress) == "http://10.0.0.5:1234",
      "a non-secret setting was written through the secrets section")
  }

  // MARK: What must not travel

  @Test("A setting describing this server does not leave it")
  func nonPortableSettingsAreNotExported() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await settings.set(Settings.serverAddress, to: "https://old.example.com")
    try await settings.set(Settings.migrationSettingsState, to: "completed")

    let report = try await exporter(database, settings).export(sections: [.settings], to: root)
    let importer = importer(
      try AppDatabase.inMemory(contributors: AppSchema.contributors), settings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    let json = try Data(
      contentsOf: inspection.directory.appendingPathComponent("settings.json"))
    let values = try JSONDecoder().decode([String: SettingValueBox].self, from: json)
    #expect(values[Settings.serverAddress.key] == nil, "an output setting was exported")
    #expect(
      values[Settings.migrationSettingsState.key] == nil,
      "this Mac's migration state travelled")
    #expect(values[Settings.socketPort.key] != nil, "an ordinary setting was left out")
  }

  @Test("A hand-edited archive cannot smuggle a non-portable setting in")
  func nonPortableSettingsAreRefusedOnImport() async throws {
    // Checked again on the way IN. An archive is a file from outside this server: it may
    // have been written by a version with a shorter list, or edited by hand.
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings], to: root)

    let (target, targetSettings, _) = try await harness()
    try await targetSettings.set(Settings.serverAddress, to: "http://10.0.0.5:1234")
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    // Forge the file the way a person with a text editor would.
    let settingsFile = inspection.directory.appendingPathComponent("settings.json")
    var values = try JSONDecoder().decode(
      [String: SettingValueBox].self, from: try Data(contentsOf: settingsFile))
    values[Settings.serverAddress.key] = SettingValueBox(
      .string("https://attacker.example.com"))
    try JSONEncoder().encode(values).write(to: settingsFile)

    let applied = try await importer.apply(inspection, sections: [.settings])
    #expect(applied.skippedSettings.map(\.key).contains(Settings.serverAddress.key))
    #expect(
      await targetSettings.get(Settings.serverAddress) == "http://10.0.0.5:1234",
      "an imported archive overwrote this server's own address")
  }

  // MARK: A service's configuration

  private static let password = "a-long-enough-passphrase-42"

  private func key(_ manifest: ServiceManifest, _ field: String) -> String {
    manifest.storageKey(for: field)
  }

  /// The values one export reads, from the file a person can open.
  private func settingsFile(_ inspection: ServerImporter.Inspection) throws
    -> [String: SettingValueBox]
  {
    try JSONDecoder().decode(
      [String: SettingValueBox].self,
      from: try Data(
        contentsOf: inspection.directory.appendingPathComponent(
          ExportSection.settings.fileName)))
  }

  /// The export walked `Settings.all` and nothing else, so a restore came up selecting
  /// ngrok with no token, no domain and no region, and every integration the person had
  /// switched off running again.
  @Test("A service's fields and the switched-off list survive an export and an import")
  func serviceConfigurationRoundTrips() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let ngrok = BuiltInManifests.ngrok
    try await sourceSettings.set(Settings.password, to: Self.password)
    try await sourceSettings.set(Settings.connectionMethod, to: ngrok.id.rawValue)
    try await sourceSettings.set(
      "tk_example_token", forKey: key(ngrok, "auth_token"), isSecret: true)
    try await sourceSettings.set("messages.example.com", forKey: key(ngrok, "custom_domain"))
    try await sourceSettings.set("eu", forKey: key(ngrok, "region"))
    try await sourceSettings.set(
      BuiltInManifests.ntfy.id.rawValue, forKey: Settings.disabledServicesKey)

    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings, .secrets], to: root, serverPassword: Self.password)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    _ = try await importer.apply(
      inspection, sections: [.settings, .secrets], serverPassword: Self.password)

    #expect(await targetSettings.get(Settings.connectionMethod) == ngrok.id.rawValue)
    #expect(await targetSettings.string(forKey: key(ngrok, "auth_token")) == "tk_example_token")
    #expect(
      await targetSettings.string(forKey: key(ngrok, "custom_domain")) == "messages.example.com")
    #expect(await targetSettings.string(forKey: key(ngrok, "region")) == "eu")
    #expect(
      await targetSettings.string(forKey: Settings.disabledServicesKey)
        == BuiltInManifests.ntfy.id.rawValue)
    // Back in the Keychain, not in a row: the field decides, on the way in as on the way out.
    #expect(await targetSettings.persistedString(forKey: key(ngrok, "auth_token")) == nil)
  }

  /// `isConfidential` says a value must not leave this Mac in anything somebody else can
  /// read, and `confidentialKeys` was consulted by the audit log and not by the export, so
  /// `settings.json` carried the ntfy topic and the licence token in the clear.
  @Test("Tokens and confidential values never reach the readable settings file")
  func confidentialValuesAreSealed() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let ngrok = BuiltInManifests.ngrok
    try await sourceSettings.set(Settings.password, to: Self.password)
    try await sourceSettings.set(
      "tk_example_token", forKey: key(ngrok, "auth_token"), isSecret: true)
    try await sourceSettings.set("messages.example.com", forKey: key(ngrok, "custom_domain"))
    try await sourceSettings.set(Settings.ntfyTopic, to: "example-topic")
    try await sourceSettings.set(Settings.licenseToken, to: "example.licence.token")

    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings, .secrets], to: root, serverPassword: Self.password)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    // Every member but the sealed one, as extracted: the ZIP itself is compressed, so a
    // search of its bytes would pass whatever it held.
    for name in try FileManager.default.contentsOfDirectory(atPath: inspection.directory.path)
    where name != ExportSection.secrets.fileName {
      let member = try Data(contentsOf: inspection.directory.appendingPathComponent(name))
      for value in ["tk_example_token", "messages.example.com", "example-topic"] {
        #expect(member.range(of: Data(value.utf8)) == nil, "\(value) is readable in \(name)")
      }
    }
    let readable = try settingsFile(inspection)
    #expect(readable[key(ngrok, "custom_domain")] == nil)
    #expect(readable[Settings.ntfyTopic.key] == nil)
    #expect(readable[Settings.licenseToken.key] == nil)

    _ = try await importer.apply(
      inspection, sections: [.settings, .secrets], serverPassword: Self.password)
    // Sealed, so it still travels: a restore must not lose the tunnel's address.
    #expect(
      await targetSettings.string(forKey: key(ngrok, "custom_domain")) == "messages.example.com")
    #expect(await targetSettings.get(Settings.ntfyTopic) == "example-topic")
    // Bound to the Mac it was issued for, so it does not travel at all.
    #expect(await targetSettings.get(Settings.licenseToken).isEmpty)
  }

  /// The file a person can open is the file a person can edit.
  @Test("A hand-edited settings file cannot write a token, or a key no service declares")
  func forgedServiceKeysAreRefused() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings], to: root)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    let ngrok = BuiltInManifests.ngrok
    let forgedToken = key(ngrok, "auth_token")
    let forgedDomain = key(ngrok, "custom_domain")
    let unknown = "app.bluebubbles.proxy.nothing.field"
    var values = try settingsFile(inspection)
    values[forgedToken] = SettingValueBox(.string("tk_forged"))
    values[forgedDomain] = SettingValueBox(.string("attacker.example.com"))
    values[unknown] = SettingValueBox(.string("anything"))
    try JSONEncoder().encode(values).write(
      to: inspection.directory.appendingPathComponent(ExportSection.settings.fileName))

    let applied = try await importer.apply(inspection, sections: [.settings])
    #expect(
      Set([forgedToken, forgedDomain, unknown]).isSubset(of: applied.skippedSettings.map(\.key)))
    #expect(await targetSettings.string(forKey: forgedToken) == nil)
    #expect(await targetSettings.string(forKey: forgedDomain) == nil)
    #expect(await targetSettings.string(forKey: unknown) == nil)
  }

  // MARK: What an import reports

  /// The check filtered the ticks by the manifest and then asked the manifest, so it could
  /// never fire: a ticked section the archive did not hold was silently dropped and the
  /// rest applied, and the person was told their import had worked.
  @Test("Ticking a section the archive does not hold is refused before anything is written")
  func tickedSectionNotInArchiveIsRefused() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.socketPort, to: 8080)
    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings], to: root)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    await #expect(throws: ServerImporter.Failure.sectionNotInArchive(.webhooks)) {
      _ = try await importer.apply(inspection, sections: [.settings, .webhooks])
    }
    #expect(
      await targetSettings.get(Settings.socketPort) != 8080,
      "a refused import wrote the sections it did hold")
  }

  /// Found at apply, it would be found after every other ticked section had been written.
  @Test("An archive listing secrets with no sealed file is incomplete when it is opened")
  func listedSecretsWithNoFileAreMissing() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: Self.password)
    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings, .secrets], to: root, serverPassword: Self.password)

    let (target, targetSettings, _) = try await harness()
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    try FileManager.default.removeItem(
      at: inspection.directory.appendingPathComponent(ExportSection.secrets.fileName))
    let incomplete = root.appendingPathComponent("incomplete.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: incomplete)

    await #expect(throws: ServerImporter.Failure.sectionMissing(.secrets)) {
      _ = try await importer.inspect(incomplete)
    }
  }

  /// A Keychain that will not take a write is not a value this server refused: the archive
  /// was fine, and the key still holds whatever it held. Reporting both as "skipped" told
  /// the person their password had been left alone on purpose.
  @Test("A value the Keychain would not store is a failure, not a skip")
  func keychainFailureIsReportedAsAFailure() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: Self.password)
    try await sourceSettings.set(Settings.ntfyToken, to: "tk_example_token")
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: Self.password)

    let target = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let keychain = RefusingKeychain(refusing: [Settings.password.key])
    let targetSettings = try await TestSettings.store(database: target, secrets: keychain)
    let importer = importer(target, targetSettings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    let applied = try await importer.apply(
      inspection, sections: [.secrets], serverPassword: Self.password)
    #expect(applied.failedSettings.map(\.key) == [Settings.password.key])
    #expect(applied.failedSettings.allSatisfy { !$0.message.isEmpty })
    #expect(!applied.skippedSettings.map(\.key).contains(Settings.password.key))
    // The rest still lands: one refusal does not take the others with it.
    #expect(await targetSettings.get(Settings.ntfyToken) == "tk_example_token")
  }

  // MARK: The archive itself

  @Test("An archive from a newer format is refused rather than partly read")
  func newerSchemaIsRefused() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(database, settings).export(sections: [.settings], to: root)

    let importer = importer(database, settings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    // Rewrite the manifest as a future version would, then re-zip it.
    let manifestURL = inspection.directory.appendingPathComponent("export.json")
    var manifest =
      try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
      as! [String: Any]
    manifest["schemaVersion"] = ExportManifest.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let future = root.appendingPathComponent("future.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: future)

    await #expect(
      throws: ExportManifest.Failure.unsupportedSchema(ExportManifest.currentSchemaVersion + 1)
    ) {
      _ = try await importer.inspect(future)
    }
  }

  @Test("Something that is not an export says so")
  func notAnExport() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let junk = root.appendingPathComponent("junk")
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: junk.appendingPathComponent("readme.txt"))
    let archive = root.appendingPathComponent("junk.zip")
    try await ZipArchive.create(contentsOf: junk, into: archive)

    let importer = importer(database, settings)
    await #expect(throws: ExportManifest.Failure.notAnExport) {
      _ = try await importer.inspect(archive)
    }
  }

  /// The extractions an inspection leaves in the temporary directory, by name.
  private func leftoverExtractions() throws -> Set<String> {
    Set(
      try FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path
      ).filter { $0.hasPrefix("bb-import-") })
  }

  /// Every failure after extraction threw past the removal: an archive from a newer format,
  /// a manifest that would not decode, left the archive's contents in the clear in
  /// `$TMPDIR`, and nothing would ever remove them.
  @Test("An inspection that fails after extracting leaves nothing behind")
  func failedInspectionRemovesItsExtraction() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(database, settings).export(sections: [.settings], to: root)
    let importer = importer(database, settings)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    // A newer format, which is refused only after the manifest has been read out of the
    // extraction; and a manifest that is not JSON, which fails while decoding it.
    let manifestURL = inspection.directory.appendingPathComponent("export.json")
    var manifest = try #require(
      try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
        as? [String: Any])
    manifest["schemaVersion"] = ExportManifest.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let future = root.appendingPathComponent("future.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: future)

    try Data("not json".utf8).write(to: manifestURL)
    let garbled = root.appendingPathComponent("garbled.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: garbled)

    let before = try leftoverExtractions()
    for archive in [future, garbled] {
      await #expect(throws: (any Error).self) { _ = try await importer.inspect(archive) }
    }
    #expect(
      try leftoverExtractions().subtracting(before).isEmpty,
      "a failed inspection left the archive's contents in the temporary directory")
  }

  @Test("The file is named for when it was made, and is not world readable")
  func fileNameAndPermissions() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let moment = Date(timeIntervalSince1970: 1_790_000_000)
    let report = try await exporter(database, settings).export(
      sections: [.settings], to: root, at: moment)

    #expect(report.url.lastPathComponent == ExportManifest.fileName(at: moment))
    let mode =
      try FileManager.default.attributesOfItem(atPath: report.url.path)[.posixPermissions]
      as? NSNumber
    #expect((mode?.intValue ?? 0) & 0o077 == 0, "the export is readable by other accounts")
  }
}

/// Where each declared setting travels, and the classification that keeps it honest.
///
/// A setting a person configures on a screen is portable unless `nonPortable` names it. A
/// setting with NO presentation is the shape bookkeeping takes, and bookkeeping is where
/// the next `server_address` would come from, so each one must be classified on purpose:
/// adding one that is in neither list fails the build here.
@Suite("Setting portability")
struct SettingPortabilityTests {

  @Test("Every non-portable key is real, and says why")
  func exclusionsAreRealAndExplained() {
    let declared = Set(Settings.allKeys)
    for (key, reason) in SettingPortability.nonPortable {
      #expect(declared.contains(key), "\(key) is excluded from exports but is not a setting")
      #expect(
        reason.count > 20,
        "\(key) is excluded with a reason too short to be one: \"\(reason)\"")
    }
    for (key, reason) in SettingPortability.portableWithoutPresentation {
      #expect(declared.contains(key), "\(key) is classified portable but is not a setting")
      #expect(reason.count > 20, "\(key) is carried with a reason too short to be one")
      #expect(SettingPortability.nonPortable[key] == nil, "\(key) is classified both ways")
    }
  }

  @Test("Every setting with no row of its own is classified, one way or the other")
  func hiddenSettingsAreClassified() {
    for setting in Settings.hidden where !setting.isSecret {
      #expect(
        SettingPortability.nonPortable[setting.key] != nil
          || SettingPortability.portableWithoutPresentation[setting.key] != nil,
        """
        \(setting.key) has no presentation and no portability decision. Add it to \
        `SettingPortability.nonPortable` if it describes this Mac, or to \
        `portableWithoutPresentation` if a restore should carry it.
        """)
    }
  }

  @Test("The keys that describe a particular server do not travel")
  func theDangerousOnesAreExcluded() {
    // Named individually rather than asserted as a count, because a count passes when
    // somebody swaps one exclusion for another.
    for key in [
      Settings.serverAddress.key, Settings.tlsCertificateOrigin.key,
      Settings.tlsCertificateExpiresAt.key, Settings.migrationSettingsState.key,
      Settings.migrationPushState.key, Settings.migrationCertificatesState.key,
      Settings.migrationPlaintextSecretsState.key, Settings.migrationSavedRecordsState.key,
      Settings.legacyConfigImported.key, Settings.onboardingComplete.key,
      Settings.onboardingSelections.key, Settings.lastRunVersion.key,
      Settings.lastFcmRestart.key, Settings.licenseToken.key,
    ] {
      #expect(!SettingPortability.isPortable(key), "\(key) would be carried between servers")
    }
  }

  @Test("Service bookkeeping is matched by shape, not by a list that goes stale")
  func serviceVersionsAreExcluded() {
    for manifest in BuiltInManifests.all {
      #expect(!SettingPortability.isPortable("\(manifest.id.rawValue).__version"))
    }
  }

  @Test("A secret or a confidential value is never routed to the readable settings file")
  func secretsAndConfidentialValuesAreSealed() {
    // They travel in their own encrypted section with its own gate. One reaching
    // `settings.json` would be in the clear inside an archive whose design says otherwise.
    for setting in Settings.all where setting.isSecret || setting.isConfidential {
      #expect(
        SettingPortability.route(
          setting.key, isSecret: setting.isSecret, isConfidential: setting.isConfidential)
          != .settingsFile,
        "\(setting.key) would have been written into settings.json")
    }
    for manifest in BuiltInManifests.all {
      for field in manifest.fields where field.isSecret || field.isConfidential {
        let key = manifest.storageKey(for: field.key)
        #expect(
          SettingPortability.route(
            key, isSecret: field.isSecret, isConfidential: field.isConfidential) == .sealed,
          "\(key) would not travel sealed")
      }
    }
  }

  @Test("Ordinary configuration does travel")
  func ordinarySettingsArePortable() {
    // The other direction: an over-broad exclusion would make an export that restores
    // nothing, and would look exactly like a working one.
    for key in [
      Settings.socketPort.key, Settings.connectionMethod.key,
      Settings.enablePrivateAPI.key, Settings.startDelay.key, Settings.disabledServicesKey,
    ] {
      #expect(SettingPortability.isPortable(key), "\(key) would not survive an export")
    }
  }
}

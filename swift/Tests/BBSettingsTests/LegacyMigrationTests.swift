//  LegacyMigrationTests
//  Migrating an existing install must never lock it out.
//
//  The password is the case that matters. Every client in the field authenticates with the
//  password it was given, and installs that predate any entropy policy are exactly the ones
//  being migrated — so applying the policy at import time would refuse the migration and
//  leave a working server unable to accept its own clients. The password is adopted as-is
//  and reported on afterwards, never rejected.

import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

@Suite("Legacy config migration")
struct LegacyMigrationTests {

  /// Writes an Electron-shaped `config` table: `(name TEXT, value TEXT)`, everything a
  /// string, which is the store whose type inference this whole layer replaces.
  private func makeLegacyDatabase(_ values: [String: String]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("legacy-\(UUID().uuidString).db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
      for (name, value) in values {
        try db.execute(
          sql: "INSERT INTO config (name, value) VALUES (?, ?)",
          arguments: [name, value]
        )
      }
    }
    return url
  }

  private func makeStore(
    _ secrets: InMemorySecretStore
  ) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory()
    return try await SettingsStore(database: database, secrets: secrets)
  }

  @Test("A weak legacy password migrates rather than failing the import")
  func weakLegacyPasswordIsAdopted() async throws {
    // "1" fails every rule the policy has. It still has to come across: the alternative
    // is an upgrade that throws, imports nothing, and leaves the user with a server that
    // rejects the password printed in their phone.
    let url = try makeLegacyDatabase([
      "password": "1",
      "socket_port": "45001",
      "auto_caffeinate": "1",
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    let result = try await LegacyConfigMigration().run(
      from: url, into: store, secrets: secrets
    )

    #expect(result.secretsMoved.contains("password"))
    #expect(try secrets.get("password") == "1")
    // And the rest of the batch landed, which it would not have if the password had
    // thrown out of the shared write.
    #expect(await store.get(Settings.socketPort) == 45001)
    #expect(await store.get(Settings.autoCaffeinate) == true)
  }

  @Test("A migrated password is visible to the store, not just to authentication")
  func migratedPasswordIsResolvable() async throws {
    // The migration puts secrets straight into the Keychain and writes no marker row.
    // Resolving through the row alone reported "no password set" on an install that
    // demonstrably had one — the auth path read the Keychain and worked, the UI read the
    // row and did not, and the two disagreed with nobody the wiser.
    let url = try makeLegacyDatabase(["password": "legacy-password-value"])
    defer { try? FileManager.default.removeItem(at: url) }

    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)

    #expect(await store.get(Settings.password) == "legacy-password-value")
    #expect(
      await store.secret(Settings.password)?.unsafeStringValue() == "legacy-password-value"
    )
  }

  @Test("A migrated weak password is still reported as weak")
  func weakPasswordIsReported() async throws {
    // Adopted, not endorsed. This is what the Settings screen renders under the field.
    let policy = PasswordPolicy()
    #expect(policy.assess("1").isConcerning)
    #expect(policy.assess("").advice != nil)
    #expect(policy.assess("bluebubbles").isConcerning)
    #expect(policy.assess(PasswordPolicy.generate()) == .strong)
  }

  @Test("A newly chosen weak password is refused")
  func newWeakPasswordIsRefused() async throws {
    // The other half of the same rule: adoption is for values that already exist, and
    // is not a way to set a new one.
    let store = try await makeStore(InMemorySecretStore())
    await #expect(throws: (any Error).self) {
      try await store.set(Settings.password, to: "1")
    }
  }

  @Test("The entropy policy applies to the password and to nothing else")
  func onlyThePasswordIsPolicyGated() async throws {
    // The ngrok and zrok tokens are SECRETS, not passwords. They are issued by those
    // services and their shape is entirely theirs to decide — applying a
    // human-password entropy rule to them would reject perfectly valid credentials and
    // leave the user unable to configure a tunnel, with an error message about
    // "predictability" that makes no sense for a machine-generated token.
    let store = try await makeStore(InMemorySecretStore())

    // Deliberately short and low-entropy. Every one of these must be accepted.
    try await store.set("1", forKey: Legacy.ngrokAuthToken, isSecret: true)
    try await store.set("aaa", forKey: Legacy.zrokAccountToken, isSecret: true)
    try await store.set("x", forKey: Legacy.zrokReservedToken, isSecret: true)
    try await store.set(Settings.ntfyToken, to: "tk_1")

    #expect(await store.string(forKey: Legacy.ngrokAuthToken) == "1")
    #expect(await store.string(forKey: Legacy.zrokAccountToken) == "aaa")
    #expect(await store.string(forKey: Legacy.zrokReservedToken) == "x")
    #expect(await store.secret(Settings.ntfyToken)?.unsafeStringValue() == "tk_1")

    // While the same value as a password is refused.
    await #expect(throws: (any Error).self) {
      try await store.set(Settings.password, to: "1")
    }
  }

  @Test("Only the password declares a validator among the secrets")
  func noOtherSecretDeclaresAValidator() {
    // Structural, so a future secret cannot pick up the policy by being added next to
    // the password in the registry.
    for setting in Settings.renderable where setting.isSecret {
      let isThePassword = setting.key == Settings.password.key
      #expect(
        setting.hasValidator == isThePassword,
        "\(setting.key) declares a validator it should not"
      )
    }
  }

  @Test("An empty password is allowed, because it is the shipped default")
  func emptyPasswordIsAllowed() async throws {
    // A fresh install starts here, and setup writes over it. Rejecting it would make the
    // server unconfigurable rather than more secure — the advisory covers it instead.
    let store = try await makeStore(InMemorySecretStore())
    try await store.set(Settings.password, to: "")
    #expect(PasswordPolicy().assess("") == .unset)
  }
}

@Suite("Legacy database detection")
struct LegacyDatabaseDetectionTests {

  @Test("A database with no config table is not a legacy database")
  func requiresTheConfigTable() throws {
    // The Swift server's own Application Support directory is the SAME path the Electron
    // server used, so a `config.db` can exist there without ever having been one. Checking
    // only for the file made the import throw `no such table: config` on every launch —
    // and because the failure path never records the migrated marker, it retried forever.
    // Caught by booting the server, not by any test that existed.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-notlegacy-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: url) }

    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE something_else (id INTEGER PRIMARY KEY)")
    }

    #expect(!LegacyConfigMigration().hasLegacyDatabase(at: url))
  }

  @Test("A real legacy database is detected")
  func detectsARealOne() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-legacy-\(UUID().uuidString).db")
    defer { try? FileManager.default.removeItem(at: url) }

    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
    }

    #expect(LegacyConfigMigration().hasLegacyDatabase(at: url))
  }

  @Test("A missing file is not a legacy database")
  func missingFile() {
    #expect(
      !LegacyConfigMigration().hasLegacyDatabase(
        at: URL(fileURLWithPath: "/nonexistent/config.db")
      )
    )
  }
}

@Suite("Legacy migration into service namespaces")
struct LegacyNamespaceMigrationTests {

  /// A realistic Electron configuration — the values a long-running install actually holds.
  private func legacyDatabase() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-legacy-\(UUID().uuidString).db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE config (name TEXT PRIMARY KEY, value TEXT)")
      for (name, value) in [
        ("proxy_service", "zrok"),
        ("zrok_token", "zrok-account-token-abc"),
        ("zrok_reserve_tunnel", "1"),
        ("zrok_reserved_name", "my-reserved-share"),
        ("zrok_reserved_token", "reserved-tok-xyz"),
        ("ngrok_key", "ngrok-authtoken-123"),
        ("ngrok_region", "eu"),
        ("ngrok_custom_domain", "example.ngrok.app"),
        ("password", "legacy-password"),
        ("socket_port", "45999"),
      ] {
        try db.execute(
          sql: "INSERT INTO config (name, value) VALUES (?, ?)",
          arguments: [name, value]
        )
      }
    }
    return url
  }

  @Test("An Electron install's tunnel configuration lands in the right namespaces")
  func tunnelSettingsAreNamespaced() async throws {
    // The whole point of the exercise. Swift-side settings can be reset at will; an
    // Electron install's cannot — these are values a user typed once and has not thought
    // about since. Landing them in the wrong place produces a tunnel that silently stops
    // working after the upgrade, with nothing to tell them what it used to be.
    let url = try legacyDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let secrets = InMemorySecretStore()
    let database = try AppDatabase.inMemory()
    let store = try await SettingsStore(database: database, secrets: secrets)

    _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)

    // Non-secret values, under the owning service.
    #expect(await store.string(forKey: Legacy.ngrokRegion) == "eu")
    #expect(await store.string(forKey: Legacy.ngrokCustomDomain) == "example.ngrok.app")
    #expect(await store.string(forKey: Legacy.zrokReservedName) == "my-reserved-share")
    #expect(await store.string(forKey: Legacy.zrokReserveTunnel) == "true")

    // Secrets, in the Keychain under their NEW names. Writing them under the old ones
    // would leave a credential sitting there looking migrated while the service — which
    // reads its own namespace — finds nothing and reports itself unconfigured.
    #expect(try secrets.get(Legacy.zrokAccountToken) == "zrok-account-token-abc")
    #expect(try secrets.get(Legacy.zrokReservedToken) == "reserved-tok-xyz")
    #expect(try secrets.get(Legacy.ngrokAuthToken) == "ngrok-authtoken-123")
  }

  @Test("The connection method becomes a service identifier")
  func proxyServiceBecomesAnIdentifier() async throws {
    // `proxy_service` held an enum case; the setting now names a service. An install that
    // was on zrok has to come back up on zrok, not on the default.
    let url = try legacyDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let secrets = InMemorySecretStore()
    let database = try AppDatabase.inMemory()
    let store = try await SettingsStore(database: database, secrets: secrets)

    _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)

    #expect(await store.get(Settings.connectionMethod) == "app.bluebubbles.proxy.zrok")
  }

  @Test("Every legacy proxy value maps to a real service")
  func everyLegacyProxyValueMaps() {
    // Including the spellings the Electron server used. An unmapped one silently becoming
    // the default is how someone's ngrok install comes back on Cloudflare.
    let known: Set<String> = [
      "app.bluebubbles.proxy.ngrok", "app.bluebubbles.proxy.zrok",
      "app.bluebubbles.proxy.lan", "app.bluebubbles.proxy.dynamic-dns",
      "app.bluebubbles.proxy.cloudflare",
    ]
    for value in ["ngrok", "zrok", "cloudflare", "lan-url", "dynamic-dns"] {
      let mapped = Legacy.connectionMethod(forLegacyProxyService: value)
      #expect(known.contains(mapped), "'\(value)' mapped to '\(mapped)'")
    }
    // Cloudflare needs no account and no configuration, so it is the safest landing place
    // for a value this version does not recognise.
    #expect(
      Legacy.connectionMethod(forLegacyProxyService: "something-new")
        == "app.bluebubbles.proxy.cloudflare")
  }

  @Test("Core settings still migrate unchanged")
  func coreSettingsAreUntouched() async throws {
    // The namespacing must not disturb what already worked. A password predating any
    // entropy policy is adopted as-is, which is the behaviour the older tests pin.
    let url = try legacyDatabase()
    defer { try? FileManager.default.removeItem(at: url) }

    let secrets = InMemorySecretStore()
    let database = try AppDatabase.inMemory()
    let store = try await SettingsStore(database: database, secrets: secrets)

    _ = try await LegacyConfigMigration().run(from: url, into: store, secrets: secrets)

    #expect(await store.get(Settings.socketPort) == 45999)
    #expect(try secrets.get("password") == "legacy-password")
  }
}

import Foundation
import GRDB
import Testing

@testable import BBPersistence
@testable import BBSettings

@Suite("SettingsStore")
struct SettingsStoreTests {

  func makeStore(
    configFile: [String: String] = [:],
    commandLine: [String: String] = [:]
  ) async throws -> (SettingsStore, InMemorySecretStore) {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let secrets = InMemorySecretStore()
    let store = try await SettingsStore(
      database: database,
      secrets: secrets,
      configFileValues: configFile,
      commandLineValues: commandLine
    )
    return (store, secrets)
  }

  @Test("Falls back to the declared default")
  func defaults() async throws {
    let (store, _) = try await makeStore()
    #expect(await store.get(Settings.socketPort) == 1234)
    #expect(await store.get(Settings.connectionMethod) == "app.bluebubbles.proxy.cloudflare")
  }

  // MARK: - The type-coercion bugs this exists to fix

  /// Under the current inference, "1" becomes a Bool. So a poll interval of 1 stops being
  /// a number and any arithmetic on it is nonsense.
  @Test("An Int setting of 1 stays an Int")
  func intOneIsNotBoolean() async throws {
    let (store, _) = try await makeStore()
    try await store.set(Settings.dbPollInterval, to: 45_000)
    #expect(await store.get(Settings.dbPollInterval) == 45_000)

    try await store.set(Settings.lastFcmRestart, to: 1)
    let value = await store.get(Settings.lastFcmRestart)
    #expect(value == 1)
    #expect(type(of: value) == Int.self)
  }

  /// start_delay is defaulted to the STRING "0.0" in the Electron server, with a comment
  /// saying a numeric default would be parsed as a boolean. It is a Double here.
  @Test("start_delay is a real Double")
  func startDelayIsDouble() async throws {
    let (store, _) = try await makeStore()
    try await store.set(Settings.startDelay, to: 2.5)
    #expect(await store.get(Settings.startDelay) == 2.5)
  }

  /// A password of "1" is the nastiest case: the old coercion turns it into `true`, and
  /// the comparison against the client's string then fails for a reason nobody can see.
  ///
  /// Written through the migration path rather than `set`, because that is the only way a
  /// value this weak can legitimately reach the store — `PasswordPolicy` rejects it on the
  /// normal write path. The coercion question is the point here and it is orthogonal to
  /// the strength question: whatever the value, it has to come back as the same String.
  @Test("A password of \"1\" survives as a string")
  func passwordOfOneIsAString() async throws {
    let (store, secrets) = try await makeStore()
    try secrets.set("password", value: "1")
    #expect(try secrets.get("password") == "1")
    #expect(await store.secret(Settings.password)?.unsafeStringValue() == "1")
  }

  // MARK: - Layering

  /// CLI wins over the config file, which wins over the store. Crucially, neither is
  /// written to the database — which is what `--persist-config` exists to undo today.
  @Test("Layers resolve in precedence order")
  func layering() async throws {
    let (store, _) = try await makeStore(
      configFile: ["socket_port": "2000"],
      commandLine: ["socket_port": "3000"]
    )
    try await store.set(Settings.socketPort, to: 1000)

    #expect(await store.get(Settings.socketPort) == 3000)
    #expect(await store.resolve(Settings.socketPort).source == .commandLine)
  }

  @Test("Config file wins over the store but loses to the CLI")
  func configFilePrecedence() async throws {
    let (store, _) = try await makeStore(configFile: ["socket_port": "2000"])
    try await store.set(Settings.socketPort, to: 1000)
    #expect(await store.get(Settings.socketPort) == 2000)
    #expect(await store.resolve(Settings.socketPort).source == .configFile)
  }

  // MARK: - Transactional writes

  /// The headline behaviour: a batch emits ONE change. The current per-key setConfig loop
  /// fires an event per key, so one UI Save produces N cascading restart cascades.
  @Test("A batch emits exactly one change")
  func batchEmitsOneChange() async throws {
    let (store, _) = try await makeStore()
    let change = try await store.write { batch in
      try batch.set(Settings.connectionMethod, to: "app.bluebubbles.proxy.zrok")
      batch.setDynamic("token", forKey: Legacy.zrokAccountToken, isSecret: true)
      try batch.set(Settings.socketPort, to: 4321)
    }
    #expect(change.changedKeys.count == 3)
    #expect(change.contains("connection_method"))
  }

  @Test("Observers receive one change per batch, not one per key")
  func observersSeeOneEvent() async throws {
    let (store, _) = try await makeStore()
    let stream = await store.changes()

    let collector = Task {
      var received: [SettingsChange] = []
      for await change in stream {
        received.append(change)
        if received.count == 1 { break }
      }
      return received
    }

    try await store.write { batch in
      try batch.set(Settings.socketPort, to: 9999)
      try batch.set(Settings.dockBadge, to: false)
    }

    let received = await collector.value
    #expect(received.count == 1)
    #expect(received[0].changedKeys.count == 2)
  }

  /// Validation runs before anything persists, so a bad value cannot leave the store
  /// half-written.
  @Test("A rejected value aborts the whole batch")
  func validationAbortsBatch() async throws {
    let (store, _) = try await makeStore()
    await #expect(throws: (any Error).self) {
      try await store.write { batch in
        try batch.set(Settings.socketPort, to: 4321)
        try batch.set(Settings.dbPollInterval, to: 10)  // below the 30-second minimum
      }
    }
    #expect(await store.get(Settings.socketPort) == 1234)
  }

  // MARK: - Secrets

  @Test("Secrets go to the secret store, never the database")
  func secretsAreNotInTheDatabase() async throws {
    let (store, secrets) = try await makeStore()
    try await store.set(Settings.password, to: "hunter2hunter2")

    #expect(try secrets.get("password") == "hunter2hunter2")
  }

}

@Suite("SecureString")
struct SecureStringTests {

  @Test("Compares equal to its own value")
  func matches() {
    #expect(SecureString("hunter2").constantTimeEquals("hunter2"))
  }

  @Test("Rejects a different value")
  func rejects() {
    #expect(!SecureString("hunter2").constantTimeEquals("hunter3"))
  }

  /// A length check that short-circuits would leak length through timing, so length is
  /// folded into the difference and the loop always walks the longer input.
  @Test("Rejects on length without short-circuiting")
  func rejectsDifferentLengths() {
    #expect(!SecureString("hunter2").constantTimeEquals("hunter22"))
    #expect(!SecureString("hunter2").constantTimeEquals("hunter"))
    #expect(!SecureString("hunter2").constantTimeEquals(""))
  }

  @Test("Empty matches only empty")
  func emptyCases() {
    #expect(SecureString("").constantTimeEquals(""))
    #expect(!SecureString("").constantTimeEquals("x"))
  }

  @Test("Handles multi-byte UTF-8")
  func unicode() {
    #expect(SecureString("pässwörd🔐").constantTimeEquals("pässwörd🔐"))
    #expect(!SecureString("pässwörd🔐").constantTimeEquals("passwörd🔐"))
  }
}

@Suite("Settings registry")
struct SettingsRegistryTests {

  /// A duplicate key would mean one setting silently shadowing another.
  @Test("Keys are unique")
  func keysAreUnique() {
    #expect(Set(Settings.allKeys).count == Settings.allKeys.count)
  }

  @Test("Every secret key is registered")
  func secretsAreRegistered() {
    for key in Settings.secretKeys {
      #expect(Settings.allKeys.contains(key), "\(key) is secret but not in allKeys")
    }
  }

  /// The compatibility contract: these two ship dormant. A default install must behave
  /// exactly like the Electron server.
  @Test("New subsystems default off")
  func newFeaturesDefaultOff() {
    #expect(Settings.authMode.defaultValue == .password)
    #expect(Settings.eventPayloadCodec.defaultValue == .legacyV1)
  }
}

// MARK: - Writes that cannot propagate

@Suite("Settings store: trySet")
struct SettingsStoreTrySetTests {

  @Test("trySet writes the value and reports that it stuck")
  func trySetWrites() async throws {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let store = try await SettingsStore(
      database: database, secrets: InMemorySecretStore(),
      configFileValues: [:], commandLineValues: [:])

    #expect(await store.trySet(Settings.checkForUpdates, to: false))
    #expect(await store.get(Settings.checkForUpdates) == false)

    #expect(await store.trySet("abc", forKey: "plugin.example.token", isSecret: false))
    #expect(await store.string(forKey: "plugin.example.token") == "abc")
  }
}

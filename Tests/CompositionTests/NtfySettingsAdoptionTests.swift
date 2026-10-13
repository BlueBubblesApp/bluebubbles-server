//  NtfySettingsAdoptionTests
//  Moving an existing install's ntfy configuration into the ntfy integration.
//
//  This is the one part of making ntfy an integration that can lose somebody's data, and it
//  runs once, silently, on a Mac nobody is watching. It is also the part that could not be
//  written as a `FieldMigration`: `ServiceMigrator` assembles every key from the manifest's
//  own namespace so a migration cannot reach core settings, which is the boundary working
//  rather than a gap. Nor can the service do it, since the old token is a core secret no
//  manifest may declare, so the composition root runs it before any service starts, and the
//  last test here holds that call in place.
//
//  Four things have to hold. The values arrive. The token arrives AS A SECRET rather than as
//  a plain row. It does not run twice. And it never runs over a configuration the person has
//  since set themselves.
//
//  NO REAL TOKENS OR TOPICS; see CONTRIBUTING.md.

import BBBuiltIns
import BBPersistence
import BBServiceKit
import BBSettings
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// A Keychain that refuses one key until told otherwise, standing in for a Keychain prompt
/// the person dismissed.
private final class RefusingSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: String] = [:]
  private var refusing: Set<String> = []

  struct Refused: Error {}

  func refuse(_ key: String?) {
    lock.withLock { refusing = key.map { [$0] } ?? [] }
  }

  func get(_ key: String) throws -> String? { lock.withLock { storage[key] } }

  func set(_ key: String, value: String) throws {
    try lock.withLock {
      if refusing.contains(key) { throw Refused() }
      storage[key] = value
    }
  }

  func delete(_ key: String) throws { lock.withLock { storage[key] = nil } }
}

@Suite("ntfy settings adoption")
struct NtfySettingsAdoptionTests {

  private static let manifest = BuiltInManifests.ntfy

  private func makeStore(_ secrets: InMemorySecretStore) async throws -> SettingsStore {
    try await TestSettings.store(secrets: secrets)
  }

  private func key(_ field: String) -> String { Self.manifest.storageKey(for: field) }

  /// What an install configured before ntfy was an integration looks like.
  private func writeLegacyConfiguration(into store: SettingsStore) async throws {
    try await store.set(Settings.ntfyTopic, to: "test-topic-a7f3")
    try await store.set(Settings.ntfyServer, to: "https://ntfy.example.com")
    try await store.set(Settings.ntfyEvents, to: "new-message,updated-message")
    try await store.set(Settings.ntfyToken, to: "tk_test_0001")
  }

  @Test("An existing configuration is moved into the integration's namespace")
  func valuesAreAdopted() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    try await writeLegacyConfiguration(into: store)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)

    #expect(await store.string(forKey: key("topic")) == "test-topic-a7f3")
    #expect(await store.string(forKey: key("server")) == "https://ntfy.example.com")
    #expect(await store.string(forKey: key("events")) == "new-message,updated-message")
  }

  /// A credential carried across as a plain value would be a downgrade in storage nobody
  /// asked for: the same failure `LegacyConfigMigration` exists to avoid.
  @Test("The access token lands in the Keychain, not in the database")
  func tokenStaysASecret() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    try await writeLegacyConfiguration(into: store)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)

    #expect(await store.string(forKey: key("token")) == "tk_test_0001")
    // Present as a SECRET, which is what says it went to the Keychain rather than into a
    // settings row: `presence(ofSecretKey:)` answers `absent` for a key the secret store
    // has never heard of, whatever the database happens to hold.
    #expect(await store.presence(ofSecretKey: key("token")).source != nil)
    // And the Keychain is where it actually is.
    #expect(try secrets.contains(key("token")))
  }

  /// The old keys are cleared as part of the move, which is what makes the guard hold: the
  /// next start finds no legacy topic and does nothing.
  @Test("It runs once, and the second start changes nothing")
  func adoptionIsNotRepeated() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    try await writeLegacyConfiguration(into: store)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)
    // The person edits the topic afterwards, in the integration, the way they now would.
    try await store.set("edited-topic-b2e8", forKey: key("topic"), isSecret: false)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)

    #expect(await store.string(forKey: key("topic")) == "edited-topic-b2e8")
    #expect(await store.string(forKey: Settings.ntfyTopic.key) == "")
  }

  /// REGRESSION. The adoption wrote one field at a time, topic first, and its guard is "the
  /// integration has no topic yet". A failure on any later write therefore left the topic
  /// adopted and everything else stranded, and the next start saw a topic and did nothing:
  /// the retry the comment promised could never run. One batch is what makes it retryable.
  @Test("An adoption that fails part-way changes nothing, and the next start completes it")
  func failedAdoptionIsRetried() async throws {
    let secrets = RefusingSecretStore()
    let store = try await TestSettings.store(secrets: secrets)
    try await writeLegacyConfiguration(into: store)

    secrets.refuse(key("token"))
    await #expect(throws: (any Error).self) {
      try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)
    }
    #expect(
      await store.string(forKey: key("topic")) == nil,
      "a failed adoption left the topic behind, which stops every later attempt")
    #expect(await store.string(forKey: Settings.ntfyTopic.key) == "test-topic-a7f3")

    secrets.refuse(nil)
    #expect(try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest))
    #expect(await store.string(forKey: key("topic")) == "test-topic-a7f3")
    #expect(await store.string(forKey: key("server")) == "https://ntfy.example.com")
    #expect(await store.string(forKey: key("token")) == "tk_test_0001")
    #expect(await store.string(forKey: Settings.ntfyTopic.key) == "")
  }

  /// The guard that matters most: a topic already set in the new namespace is the person's,
  /// and an adoption that overwrote it would undo a decision rather than fill a gap.
  @Test("A configuration already in the new namespace is never overwritten")
  func neverOverwritesTheNewNamespace() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    try await writeLegacyConfiguration(into: store)
    try await store.set("mine-c4d9", forKey: key("topic"), isSecret: false)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)

    #expect(await store.string(forKey: key("topic")) == "mine-c4d9")
  }

  /// The common install: ntfy was never set up, so there is nothing to adopt and nothing
  /// should be written. An adoption that ran anyway would seed a blank configuration and
  /// make an unconfigured sink look half-configured.
  @Test("An install that never used ntfy is left alone")
  func nothingToAdopt() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)

    try await NtfySettingsAdoption.run(store: store, manifest: Self.manifest)

    #expect(await store.string(forKey: key("topic")) == nil)
    #expect(await store.string(forKey: key("server")) == nil)
  }

  /// The adoption is only real if something runs it. It used to run in the service's own
  /// `start`; it runs in the composition root's settings preparation now, and a call nothing
  /// makes is a migration that never happens.
  @Test("The composition root adopts the old settings before any service starts")
  func compositionRunsTheAdoption() async throws {
    let secrets = InMemorySecretStore()
    let store = try await makeStore(secrets)
    try await writeLegacyConfiguration(into: store)

    _ = await ServerComposition.prepareServiceSettings(
      settings: store, logger: Logger(label: "test"))

    #expect(await store.string(forKey: key("topic")) == "test-topic-a7f3")
    #expect(await store.string(forKey: Settings.ntfyTopic.key) == "")
  }
}

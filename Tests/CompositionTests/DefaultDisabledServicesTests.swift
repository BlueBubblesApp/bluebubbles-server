//  DefaultDisabledServicesTests
//  Which built-ins ship switched off, and the upgrade that must not switch anything off.
//
//  Being compiled in is not a reason to be running: ntfy publishes to a third-party service
//  most installs do not use. But a default is for somebody who has not decided, and an
//  install that had ntfy publishing before it was an integration HAS decided. Seeding that
//  one off during an upgrade stops a working setup silently — notifications simply stop —
//  which is the outcome every case here exists to rule out.

import BBBuiltIns
import BBPersistence
import BBServiceKit
import BBSettings
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Default disabled services")
struct DefaultDisabledServicesTests {

  private let logger = Logger(label: "test")

  private func makeStore() async throws -> SettingsStore {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    return try await SettingsStore(database: database, secrets: InMemorySecretStore())
  }

  private func stored(_ store: SettingsStore) async -> Set<String> {
    ServiceEnablement.disabledIdentifiers(
      in: await store.string(forKey: Settings.disabledServicesKey) ?? "")
  }

  // MARK: - The rule

  @Test("ntfy is the built-in that ships switched off")
  func ntfyShipsOff() {
    #expect(BuiltInManifests.disabledByDefault == [BuiltInManifests.ID.ntfy])
    // And it is genuinely a built-in, not something excluded from the shipped set: a
    // manifest that is not in `all` would never be started whatever this list said.
    #expect(BuiltInManifests.all.contains { $0.id == BuiltInManifests.ID.ntfy })
  }

  /// The webhook sink is the contrast that makes "disabled by default" a decision rather
  /// than a habit: it is the other half of what ntfy used to be, and it stays on.
  @Test("Nothing else is switched off by default")
  func onlyNtfy() {
    #expect(!BuiltInManifests.disabledByDefault.contains(BuiltInManifests.ID.webhooks))
    #expect(!BuiltInManifests.disabledByDefault.contains(BuiltInManifests.ID.push))
  }

  // MARK: - Seeding

  @Test("A fresh install starts with ntfy switched off")
  func freshInstallIsSeeded() async throws {
    let store = try await makeStore()
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    #expect(await stored(store) == [BuiltInManifests.ID.ntfy.rawValue])
  }

  /// The upgrade case. An install publishing to a topic under the old core setting keeps
  /// publishing; `NtfyDeliveryService.start` then moves the settings across.
  @Test("An install already using ntfy is not switched off by the upgrade")
  func existingNtfyInstallKeepsRunning() async throws {
    let store = try await makeStore()
    try await store.set(Settings.ntfyTopic, to: "test-topic-a7f3")

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store).isEmpty)
  }

  /// And the same install after the adoption has run, where the topic lives in the
  /// integration's namespace instead. A seed that only knew the old key would switch ntfy
  /// off on the SECOND start, which is worse than never seeding at all.
  @Test("An install whose topic has already moved is not switched off either")
  func adoptedNtfyInstallKeepsRunning() async throws {
    let store = try await makeStore()
    try await store.set(
      "test-topic-a7f3",
      forKey: BuiltInManifests.ntfy.storageKey(for: NtfySettingsAdoption.Field.topic),
      isSecret: false
    )

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store).isEmpty)
  }

  /// An empty list is a real answer — somebody switched everything on — so re-seeding over
  /// it would turn ntfy back off underneath them.
  @Test("An existing choice is never re-seeded, including an empty one")
  func existingChoiceIsKept() async throws {
    let store = try await makeStore()
    try await store.set("", forKey: Settings.disabledServicesKey, isSecret: false)

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store).isEmpty)
  }

  /// The seed has to RECORD that it ran, even when it decides to disable nothing, or the
  /// key stays absent and the next start seeds again — after the user has switched ntfy on.
  @Test("Seeding nothing still records that the seed ran")
  func seedingNothingIsStillRecorded() async throws {
    let store = try await makeStore()
    try await store.set(Settings.ntfyTopic, to: "test-topic-a7f3")

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    #expect(await store.string(forKey: Settings.disabledServicesKey) != nil)

    // The person now switches ntfy off themselves. A second start must leave that alone.
    try await store.set(
      BuiltInManifests.ID.ntfy.rawValue, forKey: Settings.disabledServicesKey, isSecret: false)
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    #expect(await stored(store) == [BuiltInManifests.ID.ntfy.rawValue])
  }

  // MARK: - What the registry does with it

  @Test("A seeded install does not start ntfy, and does start the other sinks")
  func seededInstallDoesNotEnableNtfy() async throws {
    let store = try await makeStore()
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    let enabled = await ServerComposition.enabledServices(settings: store)
    #expect(!enabled.contains(BuiltInManifests.ID.ntfy))
    #expect(enabled.contains(BuiltInManifests.ID.webhooks))
    #expect(enabled.contains(BuiltInManifests.ID.push))
  }
}

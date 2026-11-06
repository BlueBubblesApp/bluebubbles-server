//  DefaultDisabledServicesTests
//  Which built-ins ship switched off, and the upgrade that must not switch anything off.
//
//  Being compiled in is not a reason to be running: ntfy publishes to a third-party service
//  most installs do not use, and the audit log writes a row per request into `app.db` for a
//  record most installs never read. But a default is for somebody who has not decided, and an
//  install that had ntfy publishing before it was an integration HAS decided. Seeding that
//  one off during an upgrade stops a working setup silently — notifications simply stop —
//  which is the outcome every case here exists to rule out.

import BBBuiltIns
import BBPersistence
import BBServiceKit
import BBSettings
import BBTestSupport
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Default disabled services")
struct DefaultDisabledServicesTests {

  private let logger = Logger(label: "test")

  private func makeStore() async throws -> SettingsStore {
    try await TestSettings.store()
  }

  /// What `ServiceSettingsBridge.prepare` leaves behind on every start: a version stamp for
  /// each service. An install that has started once has one for every default-off service,
  /// which is what tells the seed it has seen them.
  private func stampDefaultOffServices(_ store: SettingsStore) async throws {
    for manifest in BuiltInManifests.all
    where BuiltInManifests.disabledByDefault.contains(manifest.id) {
      try await store.set(
        "1", forKey: ServiceMigrator.versionKey(for: manifest), isSecret: false)
    }
  }

  private func stored(_ store: SettingsStore) async -> Set<String> {
    ServiceEnablement.disabledIdentifiers(
      in: await store.string(forKey: Settings.disabledServicesKey) ?? "")
  }

  // MARK: - The rule

  @Test("ntfy and the audit log are the built-ins that ship switched off")
  func ntfyAndAuditLogShipOff() {
    #expect(
      BuiltInManifests.disabledByDefault == [
        BuiltInManifests.ID.ntfy, BuiltInManifests.ID.auditLog,
      ])
    // And both are genuinely built-ins, not something excluded from the shipped set: a
    // manifest that is not in `all` would never be started whatever this list said.
    #expect(BuiltInManifests.all.contains { $0.id == BuiltInManifests.ID.ntfy })
    #expect(BuiltInManifests.all.contains { $0.id == BuiltInManifests.ID.auditLog })
  }

  /// The webhook sink is the contrast that makes "disabled by default" a decision rather
  /// than a habit: it is the other half of what ntfy used to be, and it stays on.
  @Test("Nothing else is switched off by default")
  func onlyThoseTwo() {
    #expect(!BuiltInManifests.disabledByDefault.contains(BuiltInManifests.ID.webhooks))
    #expect(!BuiltInManifests.disabledByDefault.contains(BuiltInManifests.ID.push))
  }

  // MARK: - Seeding

  @Test("A fresh install starts with ntfy and the audit log switched off")
  func freshInstallIsSeeded() async throws {
    let store = try await makeStore()
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    #expect(
      await stored(store)
        == [BuiltInManifests.ID.ntfy.rawValue, BuiltInManifests.ID.auditLog.rawValue])
  }

  /// The upgrade case. An install publishing to a topic under the old core setting keeps
  /// publishing; `NtfyDeliveryService.start` then moves the settings across.
  @Test("An install already using ntfy is not switched off by the upgrade")
  func existingNtfyInstallKeepsRunning() async throws {
    let store = try await makeStore()
    try await store.set(Settings.ntfyTopic, to: "test-topic-a7f3")

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    // The audit log has no "in use" signal (it writes nothing until it is on), so it is
    // seeded off regardless; only ntfy is spared.
    #expect(await stored(store) == [BuiltInManifests.ID.auditLog.rawValue])
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

    #expect(await stored(store) == [BuiltInManifests.ID.auditLog.rawValue])
  }

  /// An empty list is a real answer — somebody switched everything on — so re-seeding over
  /// it would turn ntfy back off underneath them.
  @Test("An existing choice is never re-seeded, including an empty one")
  func existingChoiceIsKept() async throws {
    let store = try await makeStore()
    try await stampDefaultOffServices(store)
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
    try await stampDefaultOffServices(store)

    // The person now switches ntfy off themselves. A second start must leave that alone.
    try await store.set(
      BuiltInManifests.ID.ntfy.rawValue, forKey: Settings.disabledServicesKey, isSecret: false)
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    #expect(await stored(store) == [BuiltInManifests.ID.ntfy.rawValue])
  }

  // MARK: - Upgrading an install that was seeded before a default existed

  /// An install seeded when ntfy was the only default: its list names ntfy, and the start
  /// before this one stamped every service it knew.
  private func seededBeforeTheAuditLog(
    commandLine: [String: String] = [:]
  ) async throws -> SettingsStore {
    let database = try AppDatabase.inMemory(contributors: [SettingsSchema.self])
    let first = try await TestSettings.store(database: database)
    try await first.set(
      BuiltInManifests.ID.ntfy.rawValue, forKey: Settings.disabledServicesKey, isSecret: false)
    try await first.set(
      "1", forKey: ServiceMigrator.versionKey(for: BuiltInManifests.ntfy), isSecret: false)
    return try await TestSettings.store(database: database, commandLineValues: commandLine)
  }

  /// The upgrade this whole section exists for: without it, the audit log comes up running
  /// on every install that already had a list, which is every install but a fresh one.
  @Test("An upgrade switches off a default-off service the install has never seen")
  func upgradeSwitchesOffANewDefault() async throws {
    let store = try await seededBeforeTheAuditLog()

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(
      await stored(store)
        == [BuiltInManifests.ID.ntfy.rawValue, BuiltInManifests.ID.auditLog.rawValue])
    let enabled = await ServerComposition.enabledServices(settings: store)
    #expect(!enabled.contains(BuiltInManifests.ID.auditLog))
  }

  /// Once the service has been prepared on this install its stamp exists, so a person who
  /// switches it on stays switched on across every later start.
  @Test("A default-off service the person switched on is not switched off again")
  func switchedOnStaysOn() async throws {
    let store = try await seededBeforeTheAuditLog()
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)
    // What `ServiceSettingsBridge.prepare` writes during that same start.
    try await store.set(
      "1", forKey: ServiceMigrator.versionKey(for: BuiltInManifests.auditLog), isSecret: false)

    // The person turns it on.
    try await store.set(
      BuiltInManifests.ID.ntfy.rawValue, forKey: Settings.disabledServicesKey, isSecret: false)
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store) == [BuiltInManifests.ID.ntfy.rawValue])
  }

  /// An empty list said "everything that existed then is on". It said nothing about a
  /// service that did not exist yet.
  @Test("An everything-on list still gets a service it has never seen switched off")
  func everythingOnStillGetsNewDefault() async throws {
    let store = try await seededBeforeTheAuditLog()
    try await store.set("", forKey: Settings.disabledServicesKey, isSecret: false)

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store) == [BuiltInManifests.ID.auditLog.rawValue])
  }

  /// The ntfy rule holds on the upgrade path too: an install publishing under the old core
  /// key, upgraded straight to a build where ntfy is an integration, has no ntfy stamp yet.
  @Test("The upgrade path does not switch off an ntfy that is already in use")
  func upgradeSparesNtfyInUse() async throws {
    let store = try await seededBeforeTheAuditLog()
    try await store.set("", forKey: Settings.disabledServicesKey, isSecret: false)
    try await store.remove(forKey: ServiceMigrator.versionKey(for: BuiltInManifests.ntfy))
    try await store.set(Settings.ntfyTopic, to: "test-topic-a7f3")

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await stored(store) == [BuiltInManifests.ID.auditLog.rawValue])
  }

  /// A `--set disabled_services=…` run amends the STORED list and leaves the override in
  /// charge of this run: persisting the override would be the one thing `--set` promises
  /// never to do.
  @Test("Under an override the stored list is amended and the override is not persisted")
  func overrideIsNotPersisted() async throws {
    let override = BuiltInManifests.ID.webhooks.rawValue
    let store = try await seededBeforeTheAuditLog(
      commandLine: [Settings.disabledServicesKey: override])

    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    #expect(await store.string(forKey: Settings.disabledServicesKey) == override)
    let persisted = await store.persistedString(forKey: Settings.disabledServicesKey) ?? ""
    #expect(
      ServiceEnablement.disabledIdentifiers(in: persisted)
        == [BuiltInManifests.ID.ntfy.rawValue, BuiltInManifests.ID.auditLog.rawValue])
  }

  // MARK: - What the registry does with it

  @Test("A seeded install does not start ntfy or the audit log, and does start the other sinks")
  func seededInstallDoesNotEnableNtfy() async throws {
    let store = try await makeStore()
    await ServerComposition.seedDisabledServices(settings: store, logger: logger)

    let enabled = await ServerComposition.enabledServices(settings: store)
    #expect(!enabled.contains(BuiltInManifests.ID.ntfy))
    #expect(!enabled.contains(BuiltInManifests.ID.auditLog))
    #expect(enabled.contains(BuiltInManifests.ID.webhooks))
    #expect(enabled.contains(BuiltInManifests.ID.push))
  }
}

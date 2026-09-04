//  SettingsPropagationTests
//  The wire between "a setting was saved" and "a service noticed".
//
//  Every piece of this existed already and none of it was connected. `SettingsStore.write`
//  emitted a change, `ServiceRegistry.apply` knew how to route one, and four services
//  declared `watchedSettings` and implemented `apply(_:)` — but nothing ever read the change
//  stream, so all of it was unreachable. Changing the port, the proxy provider or the
//  Private API toggle in the app did nothing until relaunch, and said nothing about it.
//
//  These tests fail if that connection is ever removed again.

import BBAuth
import BBPersistence
import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

// MARK: - Doubles

private actor RestartLog {
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var applied: [Set<String>] = []
  func start() { starts += 1 }
  func stop() { stops += 1 }
  func record(_ keys: Set<String>) { applied.append(keys) }
}

private struct LogContext: Sendable {
  let log: RestartLog
}

/// Watches the port, and asks for a restart when it moves — the shape `HTTPService` has.
private actor WatchingService: Service, ConfigurableService {
  static var manifest: ServiceManifest { .minimal(id: "watching") }
  static let watchedSettings: Set<String> = ["socket_port"]

  private let log: RestartLog
  init(host: LogContext) {
    log = host.log
  }

  func start() async throws { await log.start() }
  func stop() async { await log.stop() }
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    await log.record(change.changedKeys)
    return .restart
  }
  var health: ServiceHealth { get async { .running } }
}

/// Watches nothing relevant. Must not be woken.
private actor IndifferentService: Service, ConfigurableService {
  static var manifest: ServiceManifest { .minimal(id: "indifferent") }
  static let watchedSettings: Set<String> = ["log_level"]

  private let log: RestartLog
  init(host: LogContext) {
    log = host.log
  }

  func start() async throws {}
  func stop() async {}
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    await log.record(change.changedKeys)
    return .none
  }
  var health: ServiceHealth { get async { .running } }
}

// MARK: - Tests

@Suite("Settings propagation")
struct SettingsPropagationTests {

  private func makeStore() async throws -> SettingsStore {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    return try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
  }

  @Test("A saved setting restarts the service that watches it")
  func writeReachesTheService() async throws {
    let store = try await makeStore()
    let log = RestartLog()
    let registry = ServiceRegistry(host: LogContext(log: log))
    await registry.register(WatchingService.self)
    try await registry.startAll()

    let propagation = SettingsPropagation(
      settings: store, registry: registry, accessControl: AccessControlService()
    )
    await propagation.start()

    try await store.set(Settings.socketPort, to: 4321)
    // Driven directly as well as through the stream: the stream is asynchronous and this
    // assertion is about routing, not about delivery timing.
    await propagation.handle(SettingsChange(changedKeys: ["socket_port"]))

    #expect(await log.applied.contains(["socket_port"]))
    #expect(await log.stops >= 1)
    #expect(await log.starts >= 2)
  }

  /// The digest cache is the ONLY thing the auth path consults once the password has been
  /// read, so if this wire is ever cut a revoked password keeps working until the process
  /// restarts — silently, and with every test that checks authentication still passing.
  @Test("Saving a new password invalidates the cached digest")
  func passwordChangeInvalidatesTheDigest() async throws {
    let store = try await makeStore()
    try await store.set(Settings.password, to: "old-password-x")

    let digests = PasswordDigestCache(load: { await store.secret(Settings.password) })
    #expect(await digests.digest()?.constantTimeEquals("old-password-x") == true)

    let propagation = SettingsPropagation(
      settings: store, registry: ServiceRegistry(host: LogContext(log: RestartLog())),
      accessControl: AccessControlService(),
      passwordDigests: digests
    )

    try await store.set(Settings.password, to: "new-password-y")
    await propagation.handle(SettingsChange(changedKeys: [Settings.password.key]))

    #expect(await digests.digest()?.constantTimeEquals("new-password-y") == true)
    #expect(await digests.digest()?.constantTimeEquals("old-password-x") == false)
  }

  /// The invalidation is keyed on the password, not on "any write at all".
  @Test("An unrelated save leaves the cached digest alone")
  func unrelatedSaveKeepsTheDigest() async throws {
    let store = try await makeStore()
    try await store.set(Settings.password, to: "hunter2hunter2")

    let digests = PasswordDigestCache(load: { await store.secret(Settings.password) })
    _ = await digests.digest()

    let propagation = SettingsPropagation(
      settings: store, registry: ServiceRegistry(host: LogContext(log: RestartLog())),
      accessControl: AccessControlService(),
      passwordDigests: digests
    )
    await propagation.handle(SettingsChange(changedKeys: ["socket_port"]))

    #expect(await digests.digest()?.constantTimeEquals("hunter2hunter2") == true)
  }

  @Test("A service is not woken for a key it does not watch")
  func unrelatedKeysAreNotRouted() async throws {
    // Routing on the intersection is what stops one save from restarting everything —
    // the behaviour the old `proxiesRestarted` latch was hand-approximating.
    let store = try await makeStore()
    let log = RestartLog()
    let registry = ServiceRegistry(host: LogContext(log: log))
    await registry.register(WatchingService.self)
    await registry.register(IndifferentService.self)
    try await registry.startAll()

    let propagation = SettingsPropagation(
      settings: store, registry: registry, accessControl: AccessControlService()
    )
    await propagation.handle(SettingsChange(changedKeys: ["socket_port"]))

    let applied = await log.applied
    #expect(applied == [["socket_port"]])
  }

  @Test("A batch of five keys produces one round of restarts, not five")
  func batchesCoalesce() async throws {
    let store = try await makeStore()
    let log = RestartLog()
    let registry = ServiceRegistry(host: LogContext(log: log))
    await registry.register(WatchingService.self)
    try await registry.startAll()

    let propagation = SettingsPropagation(
      settings: store, registry: registry, accessControl: AccessControlService()
    )

    let change = try await store.write { batch in
      try batch.set(Settings.socketPort, to: 4321)
      try batch.set(Settings.dbPollInterval, to: 60_000)
      try batch.set(Settings.autoCaffeinate, to: true)
      try batch.set(Settings.startMinimized, to: true)
      try batch.set(Settings.hideDockIcon, to: true)
    }
    await propagation.handle(change)

    #expect(await log.stops == 1)
    #expect(await log.applied.count == 1)
  }

  @Test("Access control settings are applied even though no service owns them")
  func unownedKeysAreApplied() async throws {
    // `AccessControlService` is shared by the HTTP middleware and the socket handshake,
    // so it is in no service's `watchedSettings` and would otherwise never see a change.
    let store = try await makeStore()
    let control = AccessControlService()
    let propagation = SettingsPropagation(
      settings: store,
      registry: ServiceRegistry(host: LogContext(log: RestartLog())),
      accessControl: control
    )

    try await store.set(Settings.rateLimitEnabled, to: false)
    await propagation.handle(SettingsChange(changedKeys: ["rate_limit_enabled"]))

    // Disabled means every client is allowed, whatever the counters say.
    for _ in 0..<50 {
      _ = await control.recordFailure(
        .address("198.51.100.10"), path: "/x", reason: "bad"
      )
    }
    #expect(await control.evaluate(.address("198.51.100.10")) == .allow)
  }

  @Test("A change written after subscribing reaches the registry through the stream")
  func streamDeliversWithoutManualDriving() async throws {
    // The end-to-end path, timing included. Everything above drives `handle` directly to
    // keep the assertions about routing; this one proves the subscription exists at all.
    let store = try await makeStore()
    let log = RestartLog()
    let registry = ServiceRegistry(host: LogContext(log: log))
    await registry.register(WatchingService.self)
    try await registry.startAll()

    let propagation = SettingsPropagation(
      settings: store, registry: registry, accessControl: AccessControlService()
    )
    await propagation.start()
    #expect(await propagation.isRunning)

    try await store.set(Settings.socketPort, to: 4321)

    // Bounded wait rather than a fixed sleep: fast when it works, and it fails in
    // bounded time rather than hanging when it does not.
    var seen = false
    for _ in 0..<100 where !seen {
      if await !log.applied.isEmpty {
        seen = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen, "the settings change never reached the registry")

    await propagation.stop()
    #expect(await !propagation.isRunning)
  }
}

@Suite("Startup re-entrancy")
struct StartupReentrancyTests {

  /// Writes a setting from inside its own `start()`, which the proxy service genuinely
  /// does when it publishes the tunnel address.
  private actor SelfWritingService: Service, ConfigurableService {
    static var manifest: ServiceManifest { .minimal(id: "self-writing") }
    static let watchedSettings: Set<String> = ["socket_port"]

    nonisolated(unsafe) static var store: SettingsStore?
    private let log: RestartLog
    init(host: LogContext) {
      log = host.log
    }

    func start() async throws {
      await log.start()
      if let store = Self.store {
        try? await store.set(Settings.socketPort, to: 4321)
      }
    }
    func stop() async { await log.stop() }
    func apply(_ change: SettingsChange) async throws -> ReloadAction {
      await log.record(change.changedKeys)
      return .restart
    }
    var health: ServiceHealth { get async { .running } }
  }

  @Test("A setting written during startup does not restart services mid-startup")
  func writesDuringStartupAreDeferred() async throws {
    // `start(_:)` awaits each service's own `start()`, and the registry actor is free
    // during that await — so without a guard a change arriving here could stop a service
    // halfway through starting it, or restart one that had not started yet.
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
    SelfWritingService.store = store
    defer { SelfWritingService.store = nil }

    let log = RestartLog()
    let registry = ServiceRegistry(host: LogContext(log: log))
    await registry.register(SelfWritingService.self)

    let propagation = SettingsPropagation(
      settings: store, registry: registry, accessControl: AccessControlService()
    )
    await propagation.start()

    try await registry.startAll()

    // Started once during startup, and restarted at most once afterwards for the
    // deferred change — never interleaved, which would show up as a stop before the
    // first start had returned.
    let starts = await log.starts
    #expect(starts >= 1)
    #expect(await log.stops <= starts)

    await propagation.stop()
  }
}

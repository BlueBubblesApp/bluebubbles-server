//  BeforeGatesTests
//  What a service owes whether or not it may run, and what a retry asks again.
//
//  `Service.beforeGates` exists for a promise a refusal must not break, so these pin that it runs
//  ahead of each thing that can refuse, with no instance, and after a restart's stop. The last
//  suite is the other half of a start being refused or retried: a retry reuses its instance and
//  skips `performStart`, and the composition's gate has work to do each time it is asked.
//
//  See `.claude/docs/architecture.md`.

import BBSettings
import BBTestCore
import Foundation
import Testing

@testable import BBServiceKit

private actor OwingService: RecordingService, ConfigurableService {
  static var manifest: ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("owing"),
      name: "owing",
      summary: "Owes something whether or not it runs.",
      category: .system,
      entitlements: [.readSettings(keys: ["owing_enabled"])],
      permissions: [.init(.fullDiskAccess, .required, purpose: "to read things")]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  static func beforeGates(host: TestContext) async { await host.recorder.record("owed") }
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }
}

private actor RefusedByGateService: RecordingService, GatedService {
  static var manifest: ServiceManifest { .minimal(id: "declining") }
  let recorder: LifecycleRecorder
  init(host: TestContext) {
    recorder = host.recorder
  }
  static func beforeGates(host: TestContext) async { await host.recorder.record("owed") }
  func canRun() async -> Bool {
    await recorder.record("asked")
    return false
  }
}

private actor RetryingService: RecordingService {
  static var manifest: ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("retrying"),
      name: "retrying",
      summary: "Fails until told otherwise.",
      category: .system,
      permissions: [.init(.fullDiskAccess, .required, purpose: "to read things")]
    )
  }
  static var restartPolicy: RestartPolicy {
    .backoff(base: .milliseconds(1), max: .milliseconds(5), attempts: 3)
  }
  let recorder: LifecycleRecorder
  private var attempts = 0
  init(host: TestContext) { recorder = host.recorder }
  func start() async throws {
    attempts += 1
    await recorder.record("attempt-\(attempts)")
    if attempts < 3 { throw TestFailure.always }
  }
}

@Suite("What a service owes ahead of its gates", .serialized)
struct BeforeGatesTests {
  private static let owing = ServiceIdentifier("owing")

  @Test("It runs when a missing permission refuses the start, with no instance made")
  func aheadOfThePermission() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder), permissionCheck: { _ in false })
    await registry.register(OwingService.self)

    try await registry.startAll()
    #expect(await recorder.snapshot() == ["owed"])
    #expect(await registry.service(Self.owing) == nil)
  }

  @Test("It runs when the service has been switched off")
  func aheadOfEnablement() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder), enablementCheck: { _ in false })
    await registry.register(OwingService.self)

    try await registry.startAll()
    #expect(await recorder.snapshot() == ["owed"])
    #expect(await registry.service(Self.owing) == nil)
  }

  @Test("It runs before a gated service is asked")
  func aheadOfTheGate() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(RefusedByGateService.self)

    try await registry.startAll()
    #expect(await recorder.snapshot() == ["owed", "asked"])
  }

  @Test("A change to a watched key reaches it with no instance to route the change to")
  func settingsChangeWithNoInstance() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder), permissionCheck: { _ in false })
    await registry.register(OwingService.self)
    try await registry.startAll()

    await registry.apply(SettingsChange(changedKeys: ["owing_enabled"]))
    #expect(await recorder.snapshot() == ["owed", "owed"])
  }

  @Test("A restart for a settings change runs it after the stop and before the start")
  func betweenStopAndStart() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(OwingService.self)
    try await registry.startAll()
    await recorder.reset()

    await registry.apply(SettingsChange(changedKeys: ["owing_enabled"]))
    #expect(await recorder.snapshot() == ["stop:owing", "owed", "start:owing"])
  }

  @Test("Asking a running service to start again does not run it")
  func notForARunningService() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(OwingService.self)
    try await registry.startAll()
    await recorder.reset()

    await registry.start(Self.owing)
    #expect(await recorder.snapshot().isEmpty)
  }

  @Test("Stopping a service does not run it")
  func notForAStop() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(OwingService.self)
    try await registry.startAll()
    await recorder.reset()

    await registry.stopAll()
    #expect(await recorder.snapshot() == ["stop:owing"])
  }
}

@Suite("A retry asks the gate again", .serialized)
struct RetryGateTests {

  /// The composition's gate opens `chat.db` when it is asked about Full Disk Access, so a retry
  /// that did not ask could not recover from a database that would not open the first time.
  @Test("Each attempt under the restart policy asks the required permissions")
  func eachAttemptAsks() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(
      host: TestContext(recorder: recorder),
      permissionCheck: { id in
        await recorder.record("asked:\(id.rawValue)")
        return true
      })
    await registry.register(RetryingService.self)
    try await registry.startAll()

    try await waitUntil("the third attempt") {
      await recorder.snapshot().contains("attempt-3")
    }
    let asked = "asked:\(PermissionID.fullDiskAccess.rawValue)"
    let events = await recorder.snapshot().filter { $0 == asked || $0.hasPrefix("attempt-") }
    #expect(events == [asked, "attempt-1", asked, "attempt-2", asked, "attempt-3"])
    await registry.stopAll()
  }
}

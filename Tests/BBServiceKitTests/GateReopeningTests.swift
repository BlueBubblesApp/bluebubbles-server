//  GateReopeningTests
//  A gate that opens must start the service, without a restart of the whole server.
//
//  `apply` routes a settings change to `instances[id]`, and a `GatedService` that declined at
//  startup has no instance, so the change reached nothing. Turning the Private API on wrote
//  `enable_private_api`, restarted nothing, injected no helper, and left every Private-API
//  route refusing until the server was relaunched. From the UI that is indistinguishable from
//  the switch not working, which is how it was reported.
//
//  `applyEnablement` had already solved the same shape for the Integrations switch: its own
//  comment says a change "must reach a service with NO INSTANCE", but it runs only for
//  `enablementSettings`. A gate is the other way a service can be absent, and it reads
//  ordinary settings: the keys that can open it are the keys the service already declares it
//  watches.
//
//  See `.claude/docs/architecture.md`.

import BBSettings
import Foundation
import Testing

@testable import BBServiceKit

/// A gate the test can open, standing in for `enable_private_api`.
private actor Switch {
  private var isOn = false
  func turnOn() { isOn = true }
  func value() -> Bool { isOn }
}

private let featureSwitch = Switch()

private actor FeatureGatedService: RecordingService, GatedService, ConfigurableService {
  /// Built out rather than `.minimal`, because the read entitlement IS the subject: a
  /// service watches what its manifest says it reads, and that is the set the registry now
  /// re-evaluates a gate against.
  static var manifest: ServiceManifest {
    ServiceManifest(
      id: ServiceIdentifier("feature"),
      name: "feature",
      summary: "A gated feature.",
      category: .system,
      entitlements: [.readSettings(keys: ["feature_enabled"])]
    )
  }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
  func canRun() async -> Bool { await featureSwitch.value() }
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }
}

@Suite("Gate reopening", .serialized)
struct GateReopeningTests {

  @Test("Switching a gated service on starts it, with no instance to route the change to")
  func openingTheGateStarts() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(FeatureGatedService.self)
    try await registry.startAll()

    // Declined: nothing was constructed, which is the state that made the change
    // unroutable.
    #expect(await recorder.snapshot().isEmpty)

    await featureSwitch.turnOn()
    await registry.apply(SettingsChange(changedKeys: ["feature_enabled"]))

    #expect(await recorder.snapshot().contains("start:feature"))
    #expect(await registry.service(ServiceIdentifier("feature")) != nil)
  }

  /// The gate is still the authority. A change to a watched key is an invitation to
  /// re-evaluate, not an instruction to run.
  @Test("A change to a watched key does not start a service whose gate is still shut")
  func gateStillShutStaysInactive() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    await registry.register(DecliningService.self)
    try await registry.startAll()

    await registry.apply(SettingsChange(changedKeys: ["declining_enabled"]))

    #expect(await recorder.snapshot().isEmpty)
    #expect(await registry.service(ServiceIdentifier("declining")) == nil)
  }
}

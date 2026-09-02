//  ServiceHealthReportingTests
//  A service that is deliberately not running has to say WHY.
//
//  `ServiceHealth.inactive(reason:)` exists to distinguish "the Private API is switched off"
//  from "change detection cannot see chat.db" from "this never started". The registry
//  declined to start services correctly and then reported all three identically, which is
//  the obscurity the health model was added to remove — the server/info payload and the Home
//  screen both read this.

import Foundation
import Testing

@testable import BBServiceKit

private actor GatedRecordingService: RecordingService, GatedService {
  static var manifest: ServiceManifest { .minimal(id: "gated") }
  /// Always declines, which is how a disabled feature behaves.
  func canRun() async -> Bool { false }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

private actor PermissionedService: RecordingService, PermissionDependentService {
  static var manifest: ServiceManifest { .minimal(id: "permissioned") }
  static let requiredPermissions: [PermissionID] = [.fullDiskAccess]
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

@Suite("Inactive service reporting")
struct ServiceHealthReportingTests {

  private func registry(
    permissionCheck: @escaping @Sendable (PermissionID) async -> Bool = { _ in true }
  ) -> ServiceRegistry<TestContext> {
    ServiceRegistry(
      host: TestContext(recorder: LifecycleRecorder()),
      permissionCheck: permissionCheck
    )
  }

  @Test("A gated service that declines reports why")
  func gateDeclinedIsReported() async throws {
    let registry = registry()
    await registry.register(GatedRecordingService.self)
    try await registry.startAll()

    let health = await registry.health()
    #expect(health[ServiceID("gated")] == .inactive(reason: "disabled by configuration"))
  }

  @Test("A missing permission is named in the health report")
  func missingPermissionIsNamed() async throws {
    // "requires full-disk-access" is actionable. "not started" sends someone to the logs.
    let registry = registry(permissionCheck: { $0 != .fullDiskAccess })
    await registry.register(PermissionedService.self)
    try await registry.startAll()

    let health = await registry.health()
    #expect(
      health[ServiceID("permissioned")]
        == .inactive(reason: "requires the full-disk-access permission")
    )
  }

  @Test("A service reports running once it starts")
  func runningClearsTheReason() async throws {
    let registry = registry()
    await registry.register(DatabaseService.self)
    try await registry.startAll()
    #expect(await registry.health()[ServiceID("database")] == .running)
  }

  @Test("Registered but never started services still appear")
  func registeredServicesAppearBeforeStartup() async {
    // `health()` walked the start order, which is empty until `startAll()` — so a server
    // that failed before startup reported no services at all rather than a list of
    // stopped ones, which is exactly when the report is most needed.
    let registry = registry()
    await registry.register(DatabaseService.self)
    await registry.register(HTTPService.self)

    let health = await registry.health()
    #expect(health.count == 2)
    #expect(health[ServiceID("database")] == .inactive(reason: "not started"))
  }
}

//  NetworkRecoveryTests
//  What a network return is allowed to restart, and what it must leave alone.
//
//  Both halves matter and the second is the one that keeps the first usable. Restarting a
//  failed service when the network comes back is the point; restarting anything else turns a
//  transition nobody noticed into an outage, and restarting a service a person switched off is
//  worse than the bug being fixed.
//
//  The `.inactive` and `.degraded` cases below are not hypothetical caution. The plan this was
//  built from (`docs/NETWORK_AWARENESS.md` §4) had `.inactive` in its restart column, on the
//  reading that it meant "retries exhausted". In `ServiceRegistry` it means the opposite —
//  deliberately not running, and `"switched off"` is one of its reasons — so a service written
//  from that table would have restarted exactly what the table was trying to protect.

import BBBuiltIns
import BBHTTPAPI
import BBServiceKit
import BBSystem
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("Network recovery")
struct NetworkRecoveryTests {

  /// Records what was asked for, and answers with a health table written by the test.
  private actor RecordingDriver: ServiceRecoveryDriving {
    private let table: [ServiceIdentifier: ServiceHealth]
    private(set) var restarted: [ServiceIdentifier] = []
    private(set) var healthReads = 0

    init(_ table: [ServiceIdentifier: ServiceHealth]) { self.table = table }

    func serviceHealth() async -> [ServiceIdentifier: ServiceHealth] {
      healthReads += 1
      return table
    }

    func restartService(_ id: ServiceIdentifier) async { restarted.append(id) }
  }

  private static let http = ServiceIdentifier("app.bluebubbles.core.http")
  private static let ngrok = ServiceIdentifier("app.bluebubbles.proxy.ngrok")

  private static func path(satisfied: Bool = true) -> NetworkPath {
    NetworkPath(
      isSatisfied: satisfied, isExpensive: false, interfaces: [], localAddresses: ["192.0.2.10"])
  }

  private static func service(
    driver: any ServiceRecoveryDriving,
    floor: Duration = .seconds(30),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) -> NetworkRecoveryService {
    NetworkRecoveryService(
      observer: NetworkPathObserver { AsyncStream { $0.finish() } },
      driver: driver,
      logger: Logger(label: "test"),
      floor: floor,
      now: now
    )
  }

  @Test("A network return restarts a failed service")
  func returnRestartsFailed() async {
    let driver = RecordingDriver([Self.http: .failed(reason: "not listening")])
    let service = Self.service(driver: driver)

    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted == [Self.http])
  }

  /// The rule that stops this being worse than the problem.
  @Test("A return with nothing broken restarts nothing")
  func returnWithNothingBrokenDoesNothing() async {
    let driver = RecordingDriver([Self.http: .running, Self.ngrok: .running])
    let service = Self.service(driver: driver)

    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted.isEmpty)
  }

  /// `.inactive` is "deliberately not running", not "gave up". A person switched this off.
  @Test("A switched-off service is never restarted by a network return")
  func inactiveIsLeftAlone() async {
    let driver = RecordingDriver([
      Self.ngrok: .inactive(reason: "switched off"),
      Self.http: .inactive(reason: "requires the fullDiskAccess permission"),
    ])
    let service = Self.service(driver: driver)

    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted.isEmpty)
  }

  /// `.degraded` is overloaded: `PrivateAPIGatedService` reports it for a Mac with no helper,
  /// which is a normal configuration and not something a route change should restart.
  @Test("A degraded service is never restarted by a network return")
  func degradedIsLeftAlone() async {
    let driver = RecordingDriver([Self.http: .degraded(reason: "no helper connected")])
    let service = Self.service(driver: driver)

    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted.isEmpty)
  }

  /// Wi-Fi to Ethernet, or a VPN coming up. Everything is working during one of these.
  @Test("A route change that keeps the network up restarts nothing, even when something failed")
  func changedDoesNotRecover() async {
    let driver = RecordingDriver([Self.http: .failed(reason: "not listening")])
    let service = Self.service(driver: driver)

    await service.handle(.changed(Self.path()))
    await service.handle(.becameUnavailable(Self.path(satisfied: false)))

    #expect(await driver.restarted.isEmpty)
    // Not even asked: a transition that cannot lead to a restart must not cost a health read
    // of every service each time a marginal link flaps.
    #expect(await driver.healthReads == 0)
  }

  @Test("Two returns inside the floor produce one recovery pass")
  func floorSuppressesTheSecondPass() async {
    let driver = RecordingDriver([Self.http: .failed(reason: "not listening")])
    let clock = ClockStub()
    let service = Self.service(driver: driver, floor: .seconds(30), now: { clock.value })

    await service.handle(.becameAvailable(Self.path()))
    clock.advance(.seconds(5))
    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted == [Self.http])

    // And the floor expires rather than latching.
    clock.advance(.seconds(30))
    await service.handle(.becameAvailable(Self.path()))
    #expect(await driver.restarted == [Self.http, Self.http])
  }

  /// A quiet pass must not lock out the next one: the floor exists to space RESTARTS, and a
  /// return that found everything healthy did not restart anything.
  @Test("A return that found nothing broken does not spend the floor")
  func aQuietPassDoesNotSpendTheFloor() async {
    let driver = RecordingDriver([Self.http: .failed(reason: "not listening")])
    let healthy = RecordingDriver([Self.http: .running])
    let clock = ClockStub()

    let quiet = Self.service(driver: healthy, floor: .seconds(30), now: { clock.value })
    await quiet.handle(.becameAvailable(Self.path()))

    let service = Self.service(driver: driver, floor: .seconds(30), now: { clock.value })
    clock.advance(.seconds(1))
    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted == [Self.http])
  }

  /// The composition root actually calls it. A service nothing registers is dead code that
  /// compiles, and every test above would still pass.
  @Test("The composition root registers it, after the observer it consumes")
  func compositionRegistersTheService() async throws {
    let registry = ServiceRegistry<AppContext>(host: try await AppContextFixture.make())
    await ServerComposition.registerServices(in: registry)

    let registered = Set(await registry.manifests.map(\.id))
    #expect(registered.contains(BuiltInManifests.ID.networkRecovery))
    #expect(registered.contains(BuiltInManifests.ID.networkPath))

    // Declared, not assumed: without this edge the observer may not be started when the
    // recovery service subscribes, and the subscription would sit on a stream nobody drives.
    #expect(
      BuiltInManifests.networkRecovery.dependencies.contains(BuiltInManifests.ID.networkPath))
  }

  /// The capability chain, end to end, with no doubles in it.
  ///
  /// Every test above substitutes `ServiceRecoveryDriving`, so all of them would pass even if
  /// a service could not reach the registry at runtime — which is the reasonable worry about
  /// giving one the power to restart another. This runs the real thing: a real
  /// `ServiceRegistry<AppContext>`, a real `AppContext` wired to it, `NetworkRecoveryService`
  /// built from that context through its own `Host` projection, and a registered service that
  /// fails its start.
  ///
  /// It also pins the ordering the whole design rests on: `finishWiring` sets the context's
  /// weak registry reference, and it runs at composition line 200 while services start at
  /// 1009. If that order ever inverts, `serviceHealth()` answers `[:]` and this service
  /// becomes a no-op that logs nothing and reports healthy.
  @Test("Through the real context and registry, a failed service is actually restarted")
  func recoversThroughTheRealRegistry() async throws {
    let probe = RecoveryProbe()
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    await registry.register(RecoverableService.self) { _ in ProbeHost(probe: probe) }
    await context.finishWiring(registry: registry, handlers: HandlerRegistry())

    // First start fails, and the policy is `.never`, so nothing retries it.
    try? await registry.startAll()
    #expect(await probe.attempts == 1)
    let down = await registry.health()[RecoverableService.manifest.id]
    #expect(down == .failed(reason: "no network"))

    // The network comes back. Nothing in this line is a double.
    let service = NetworkRecoveryService(host: context)
    await probe.allowSuccess()
    await service.handle(.becameAvailable(Self.path()))

    #expect(await probe.attempts == 2, "the recovery service did not reach the registry")
    #expect(await registry.health()[RecoverableService.manifest.id] == .running)
  }

  /// A deterministic order, because the registry restarts each service's dependents with it.
  @Test("Several failed services are restarted in a stable order")
  func restartOrderIsStable() async {
    let driver = RecordingDriver([
      Self.ngrok: .failed(reason: "tunnel closed"),
      Self.http: .failed(reason: "not listening"),
    ])
    let service = Self.service(driver: driver)

    await service.handle(.becameAvailable(Self.path()))

    #expect(await driver.restarted == [Self.http, Self.ngrok])
  }
}

/// Counts start attempts, and decides whether the next one succeeds.
private actor RecoveryProbe {
  private(set) var attempts = 0
  private var succeeds = false

  func allowSuccess() { succeeds = true }

  func attempt() throws {
    attempts += 1
    if !succeeds { throw NoNetwork() }
  }

  struct NoNetwork: Error {}
}

private protocol RecoveryProbeHost: Sendable {
  var probe: RecoveryProbe { get }
}

private struct ProbeHost: RecoveryProbeHost {
  let probe: RecoveryProbe
}

/// A service that fails to start until the probe lets it through, standing in for one whose
/// bind address is not on any interface yet.
///
/// `Host` is its own protocol rather than `AppContext`, so the registry's projection closure
/// carries the probe in: a service is handed what it needs and nothing else, in a test for
/// the same reason as in production.
private actor RecoverableService: Service {
  static var manifest: ServiceManifest { .minimal(id: "test-recoverable") }
  /// `.never`, so nothing but the recovery service can account for a second attempt.
  static var restartPolicy: RestartPolicy { .never }

  private let probe: RecoveryProbe
  private var running = false

  init(host: any RecoveryProbeHost) { self.probe = host.probe }

  func start() async throws {
    try await probe.attempt()
    running = true
  }

  func stop() async { running = false }

  var health: ServiceHealth {
    get async { running ? .running : .failed(reason: "no network") }
  }
}

/// A clock a test moves by hand. `ContinuousClock.now` cannot be set, and the floor is thirty
/// seconds, which no suite should spend proving.
private final class ClockStub: @unchecked Sendable {
  /// Guarded by the actor hop in every test that uses it: each `advance` happens between two
  /// awaited calls, never concurrently with one.
  private(set) var value = ContinuousClock.now
  func advance(_ duration: Duration) { value = value.advanced(by: duration) }
}

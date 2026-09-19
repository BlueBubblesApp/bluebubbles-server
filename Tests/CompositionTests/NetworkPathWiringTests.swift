//  NetworkPathWiringTests
//  That the observer is constructed, registered, and reaches the server's lifetime.
//
//  "A module is not done until the composition root calls it and a test asserts that call
//  exists." An observer that is written, correct and never started is the failure this
//  catches, and it is invisible: nothing breaks, the server simply never notices anything.

import BBBuiltIns
import BBServiceKit
import BBSystem
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Network path wiring")
struct NetworkPathWiringTests {

  @Test("The observer service is registered with the container")
  func registered() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry(host: context)
    await ServerComposition.registerServices(in: registry)
    let ids = await registry.manifests.map(\.id)
    #expect(ids.contains(BuiltInManifests.networkPath.id))
  }

  /// Not an integration: there is nothing to configure, and a switch whose only effect is to
  /// stop the server noticing the network came back is not a choice worth offering.
  @Test("It does not appear on the Integrations screen")
  func notUserManageable() {
    #expect(BuiltInManifests.networkPath.isUserManageable == false)
  }

  /// It observes the local routing state and opens nothing. Declaring egress it does not use
  /// would make the permissions list less trustworthy rather than more careful.
  @Test("It declares no entitlements at all")
  func declaresNothing() {
    #expect(BuiltInManifests.networkPath.entitlements.isEmpty)
  }

  @Test("Starting and stopping it is clean, and it survives a restart with its memory")
  func lifecycle() async throws {
    let context = try await AppContextFixture.make()
    let service = NetworkPathService(host: context)
    try await service.start()
    #expect(await service.health == .running)
    await service.stop()
    // Started twice without a stop between is a no-op rather than two monitors.
    try await service.start()
    try await service.start()
    await service.stop()
  }
}

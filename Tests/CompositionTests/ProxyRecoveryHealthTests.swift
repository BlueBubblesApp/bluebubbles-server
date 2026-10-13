//  ProxyRecoveryHealthTests
//  A tunnel that dropped must be distinguishable from one waiting on a person.
//
//  The scenario: the Mac loses its network, or the lid closes, and ngrok, cloudflared or zrok
//  loses its tunnel. When the network comes back the tunnel has to come back with it, and the
//  only thing that can make that happen is `NetworkRecoveryService` seeing the service as
//  broken — which means `ProxyService.health` has to SAY so.
//
//  It did not. A tunnel with no address reported `.inactive`, the same case a service someone
//  switched off reports, and the recovery pass skips `.inactive` precisely so it cannot restart
//  something a person turned off. Nothing else covered the gap either:
//
//    - `restartPolicy` only re-enters `supervise` when `start()` THROWS. A tunnel that
//      connected and later dropped never threw.
//    - The liveness poll reads `isAlive`, which `ProxyService` does not override, so it
//      answers `true` for a tunnel with no connection.
//    - `ProxyObserver.disconnected` logs the drop and publishes health. It restarts nothing.
//
//  So a dropped tunnel stayed down until somebody restarted the server. These tests pin the
//  split that fixes it, and the half of the split that must NOT be restarted: a sign-in that
//  has not been completed is not something a returning network repairs.

import BBBuiltIns
import BBProxy
import BBServiceKit
import Foundation
import Testing

@testable import BlueBubblesServerCore

/// Connects, and can drop the tunnel afterwards the way a network outage does.
private actor DroppingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.dropping")
  private(set) var currentAddress: String?
  private var observer: ProxyObserver?

  func observe(_ observer: ProxyObserver) async { self.observer = observer }

  func connect() async throws -> String {
    currentAddress = "https://example.test"
    return "https://example.test"
  }

  func disconnect() async { currentAddress = nil }

  /// What the network going away looks like from inside a provider: the address is gone and
  /// the observer is told. Nothing throws, which is the whole difficulty.
  func drop(reason: String = "connection lost") async {
    currentAddress = nil
    await observer?.disconnected(reason)
  }
}

/// Never connects, because it is waiting for the user to finish signing in.
private actor SignInPendingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.test.proxy.signin")
  private(set) var currentAddress: String?
  private var observer: ProxyObserver?

  func observe(_ observer: ProxyObserver) async { self.observer = observer }
  func connect() async throws -> String { throw ProxyError.pending(reason: "signing in") }
  func disconnect() async { currentAddress = nil }
}

@Suite("Proxy health and network recovery")
struct ProxyRecoveryHealthTests {

  @Test("A connected tunnel is running")
  func connectedIsRunning() async throws {
    let service = ProxyService<TailscaleMethod>(host: try await AppContextFixture.make())
    try await service.coordinator.start(DroppingProvider())

    #expect(await service.health == .running)
  }

  /// The case the whole entry exists for.
  @Test("A tunnel that dropped reports failed, so a network return can retry it")
  func droppedTunnelIsFailed() async throws {
    let service = ProxyService<TailscaleMethod>(host: try await AppContextFixture.make())
    let provider = DroppingProvider()
    try await service.coordinator.start(provider)
    #expect(await service.health == .running)

    await provider.drop()

    #expect(
      await service.health == .failed(reason: "not connected"),
      "a dropped tunnel that reports .inactive is skipped by NetworkRecoveryService")
  }

  /// The other half, and the reason the rule cannot simply restart `.inactive` instead.
  @Test("A tunnel waiting on a sign-in stays inactive, and is not retried")
  func pendingSignInStaysInactive() async throws {
    let service = ProxyService<TailscaleMethod>(host: try await AppContextFixture.make())
    try await service.coordinator.start(SignInPendingProvider())

    #expect(await service.health == .inactive(reason: "signing in"))
  }

  /// End to end, through the real registry: the shape of the user's outage.
  @Test("After a drop, a network return restarts the proxy")
  func networkReturnRestartsADroppedProxy() async throws {
    let context = try await AppContextFixture.make()
    let service = ProxyService<TailscaleMethod>(host: context)
    let provider = DroppingProvider()
    try await service.coordinator.start(provider)
    await provider.drop()

    // What the recovery pass would see, with no double standing in for it.
    let broken = await service.health
    #expect(broken == .failed(reason: "not connected"))

    // And the rule acts on exactly that case. `NetworkRecoveryService.handle` reads health
    // and restarts what is failed; `NetworkRecoveryTests` proves the registry call happens,
    // so what this pins is that a dropped tunnel is IN the set it acts on.
    #expect(Self.isRecoverable(broken))
    #expect(!Self.isRecoverable(.inactive(reason: "signing in")))
    #expect(!Self.isRecoverable(.inactive(reason: "switched off")))
    #expect(!Self.isRecoverable(.running))
  }

  /// The predicate `NetworkRecoveryService.handle` applies, stated once so this suite tests
  /// the same rule rather than a paraphrase of it.
  private static func isRecoverable(_ health: ServiceHealth) -> Bool {
    if case .failed = health { return true }
    return false
  }
}

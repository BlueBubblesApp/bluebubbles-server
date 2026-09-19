//  ServiceContractTests
//  The two value types the service protocol is written in: `SettingsChange` and `ServiceHealth`.
//
//  Both encode a distinction the Electron server could not make. A settings write there ran a
//  160-line if-chain over every key; here a change carries its key set and the registry
//  consults only the services whose watched keys intersect it, and a batched write emits ONE
//  summary so a single UI save cannot fire N cascading restarts. And a gated service that
//  declines to run (the proxy that is not the configured one) is `inactive`, which is a
//  normal state, not `failed`; collapsing the two puts a red row on the Integrations screen
//  for a service working exactly as configured.
//
//  These are the type-level assertions only. That the registry actually routes by
//  intersection, and cascades a restart to dependents, is in `ServiceRegistryTests`.

import BBSettings
import Testing

@testable import BBServiceKit

@Suite("Settings change routing")
struct SettingsChangeTests {
  /// The registry routes a change only to services that watch an affected key. This is
  /// what replaces the 160-line if-chain and its manual proxiesRestarted latch.
  @Test("Only intersecting services are notified")
  func intersection() {
    let change = SettingsChange(changedKeys: ["socket_port", "password"])
    #expect(change.intersects(["socket_port"]))
    #expect(change.intersects(["password", "ngrok_key"]))
    #expect(!change.intersects(["auto_caffeinate"]))
  }

  /// A batched write emits one summary, not one per key, so a single UI save cannot fire
  /// N cascading restarts.
  @Test("A batch is a single summary")
  func batchIsOneEvent() {
    let change = SettingsChange(changedKeys: ["proxy_service", "zrok_token"])
    #expect(change.changedKeys.count == 2)
    #expect(change.contains("proxy_service"))
  }
}

@Suite("Service health")
struct ServiceHealthTests {
  /// A gated service declining to run is a normal state, not a failure: the distinction
  /// the reference does not draw.
  @Test("Inactive is distinct from failed")
  func inactiveIsNotFailure() {
    let inactive = ServiceHealth.inactive(reason: "proxy_service is not zrok")
    let failed = ServiceHealth.failed(reason: "bind: address in use")
    #expect(inactive != failed)
  }
}

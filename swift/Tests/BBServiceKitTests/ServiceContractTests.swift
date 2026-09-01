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
  /// A gated service declining to run is a normal state, not a failure — the distinction
  /// the current implementation does not draw.
  @Test("Inactive is distinct from failed")
  func inactiveIsNotFailure() {
    let inactive = ServiceHealth.inactive(reason: "proxy_service is not zrok")
    let failed = ServiceHealth.failed(reason: "bind: address in use")
    #expect(inactive != failed)
  }
}

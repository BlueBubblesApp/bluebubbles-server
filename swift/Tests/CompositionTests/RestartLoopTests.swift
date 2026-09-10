//  RestartLoopTests
//  A published address must not restart the thing that publishes it.
//
//  This pins a live defect, not a hypothetical one. A Cloudflare quick tunnel published
//  `server_address` on connect; `HTTPService` reads that key (`TLSProvisioning` puts it in a
//  generated certificate's SAN) and restarted on it; the five reverse proxies declare a
//  dependency on the HTTP service, so they were restarted with it; the restart reconnected
//  the tunnel; and the reconnect published the address again. Measured on a real machine: the
//  listener was rebuilt and cloudflared respawned about twenty times a second until the
//  process was killed, with 30 MB of log written in ten minutes.
//
//  `ServiceManifest.watchedSettingKeys` already subtracts the keys a service WRITES, and says
//  in its own comment that this is to stop "a restart on each publish". That subtraction only
//  sees a service looping on its own write. Here the writer (a proxy) and the restarter (the
//  HTTP service) are different services, each declaration correct on its own, and the cycle
//  closes through the dependency edge between them.
//
//  See `.claude/docs/architecture.md`.

import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesServerCore

@Suite("Restart loops")
struct RestartLoopTests {

  private func httpService() async throws -> HTTPService {
    let context = try await AppContextFixture.make()
    return HTTPService(host: HTTPServiceHost(context))
  }

  /// The half that made the loop possible: it IS routed the change.
  ///
  /// Asserted rather than assumed, because "just stop watching it" looks like the simpler
  /// fix and is the wrong one: the key is genuinely read, and a service that reads a
  /// setting it does not watch is the failure `WatchedSettingsTests` exists to catch.
  @Test("The HTTP service still watches the published address, because it reads it")
  func watchesServerAddress() {
    #expect(HTTPService.watchedSettings.contains(Settings.serverAddress.key))
  }

  @Test("A published address alone does not restart the listener")
  func addressAloneDoesNotRestart() async throws {
    let service = try await httpService()
    let action = try await service.apply(
      SettingsChange(changedKeys: [Settings.serverAddress.key])
    )
    #expect(action == .none)
  }

  /// The keys that genuinely rebind or re-authenticate still restart, so the exemption
  /// cannot quietly grow into "this service never restarts".
  @Test(
    "Everything else this service watches still restarts it",
    arguments: [
      Settings.socketPort.key,
      Settings.bindAddress.key,
      Settings.useCustomCertificate.key,
      Settings.password.key,
    ]
  )
  func otherKeysRestart(key: String) async throws {
    let service = try await httpService()
    #expect(try await service.apply(SettingsChange(changedKeys: [key])) == .restart)
  }

  /// A batch carrying both must still restart. Reading "some key I watch is exempt" as
  /// "this change is exempt" would drop a port change that happened to travel with an
  /// address publish.
  @Test("A restart-worthy key travelling with the address still restarts")
  func mixedBatchRestarts() async throws {
    let service = try await httpService()
    let action = try await service.apply(
      SettingsChange(changedKeys: [Settings.serverAddress.key, Settings.socketPort.key])
    )
    #expect(action == .restart)
  }

  /// A key belonging to some OTHER service must not restart this one just by being in the
  /// same batch, which is what a naive `changedKeys.subtracting(exempt)` would do.
  @Test("A key this service does not watch does not restart it")
  func unwatchedKeyDoesNotRestart() async throws {
    let service = try await httpService()
    let action = try await service.apply(
      SettingsChange(changedKeys: [Settings.serverAddress.key, Settings.logLevel.key])
    )
    #expect(action == .none)
  }
}

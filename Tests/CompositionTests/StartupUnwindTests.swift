//  StartupUnwindTests
//  A start that fails leaves nothing of itself running.
//
//  `RunningServer.start` subscribes the settings pump, installs the metrics tap and starts the
//  metrics ticker before it asks the registry to start the services, and the registry can
//  still refuse after that: a dependency cycle, or a service naming one that is not
//  registered. The app stops the composition when its start throws; the command line did
//  not, so a refused start went on with the pump and the ticker running against `app.db`.
//
//  `AppContextFixture` gives the context a throwaway daemon ledger, so the reap at the top of
//  `start` cannot terminate the tunnels of a server running on the same Mac.

import BBHTTPAPI
import BBHandlers
import BBServiceKit
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// Names a dependency nobody registers, so the start order cannot be resolved.
private actor DanglingDependencyService: Service {
  static var manifest: ServiceManifest {
    .minimal(id: "test.dangling", dependencies: [ServiceIdentifier("test.absent")])
  }
  init(host: AppContext) {}
  func start() async throws {}
  func stop() async {}
  var health: ServiceHealth { get async { .running } }
}

@Suite("Startup unwinding")
struct StartupUnwindTests {

  @Test("A start the registry refuses stops what it had already started")
  func refusedStartIsUnwound() async throws {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    await registry.register(DanglingDependencyService.self)

    var handlers = HandlerRegistry()
    _ = PlaceholderHandlers.fill(into: &handlers, groups: RouteTable.alwaysMounted)

    let propagation = SettingsPropagation(
      settings: context.settings, registry: registry, accessControl: context.accessControl)
    let server = RunningServer(
      context: context, logSink: nil, registry: registry, propagation: propagation,
      handlers: handlers, routeGroups: [], options: ServerComposition.Options(),
      logger: Logger(label: "bluebubbles.test.unwind"))

    await #expect(throws: ServiceRegistryError.self) { try await server.start() }

    #expect(await !propagation.isRunning, "the settings pump outlived a start that failed")
    #expect(
      await context.metrics.snapshot == nil,
      "the metrics ticker outlived a start that failed")
  }
}

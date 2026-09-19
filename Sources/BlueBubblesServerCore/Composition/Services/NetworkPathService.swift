//  NetworkPathService
//  Runs the network path observer for the life of the server.
//
//  A `Service` rather than a `nonisolated let` on the container, because the thing it owns has
//  a LIFETIME: a dispatch queue and a monitor that have to be cancelled when the server stops,
//  and the registry is what already knows how to do that in the right order.
//
//  **It publishes and nothing consumes it yet, deliberately.** The observer's own log is the
//  point of this step: `NWPathMonitor`'s behaviour on wake, and how long a real burst takes to
//  settle, are questions to be measured on a running Mac rather than guessed at and designed
//  around. See `docs/NETWORK_AWARENESS.md` §5 and §9. Recovery is the next step and is
//  deliberately not this one.
//
//  Not user-manageable and not gated: there is no configuration, and switching it off would
//  only stop the server noticing things.

import BBBuiltIns
import BBInterfaces
import BBServiceKit
import BBSystem
import Foundation
import Logging

actor NetworkPathService: Service {

  static let manifest = BuiltInManifests.networkPath
  /// Nothing here can fail in a way a restart would fix: the observer either has a monitor or
  /// the process has bigger problems. A retry loop would be machinery for an impossible case.
  static let restartPolicy = RestartPolicy.never

  /// The observer and a logger, and nothing else. It touches no settings, no database and no
  /// network.
  typealias Host = any NetworkPathProviding & LoggerProviding

  private let observer: NetworkPathObserver
  private let logger: Logger

  init(host: Host) {
    self.observer = host.networkPath
    self.logger = host.logger
  }

  func start() async throws {
    await observer.start()
    logger.debug("Watching for network changes")
  }

  func stop() async {
    await observer.stop()
  }

  var health: ServiceHealth {
    get async { .running }
  }
}

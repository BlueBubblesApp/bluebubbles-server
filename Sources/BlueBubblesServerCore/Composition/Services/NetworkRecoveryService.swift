//  NetworkRecoveryService
//  Retries services that failed while the network was down, when it comes back.
//
//  The recorded bug this exists for: a pinned `bind_address` that disappears takes the HTTP
//  listener with it, the registry's backoff exhausts after ten attempts over about half a
//  minute, and a network that returns two minutes later finds nobody still trying. The server
//  stays bound to nothing until a person restarts it. `NetworkPathObserver` already knows the
//  moment the network returns; until this service there was nothing on the other end of it.
//
//  ## The signal is permission to retry, never an instruction to restart
//
//  A Mac moving from Wi-Fi to Ethernet, or bringing a VPN up, changes the path while
//  everything is working. Restarting six tunnels and a listener because a route moved would
//  manufacture an outage nobody had — and `cloudflared` and `ngrok` run their own reconnection,
//  so tearing them down discards recovery already in progress. Two things keep that from
//  happening: only `becameAvailable` is acted on (`NetworkTransition.permitsRetry`, which is
//  where that decision is made once), and only services that are ALREADY broken are touched.
//
//  ## Why `.failed` alone, and not the other four
//
//  `docs/NETWORK_AWARENESS.md` §4 sketched this table against an assumed mapping, and two of
//  its rows did not survive contact with `ServiceRegistry`:
//
//    - It expected `.inactive` to mean "retries exhausted" and `.stopped` to mean "switched
//      off". In the registry it is the other way about: a service someone switched off reports
//      `.inactive(reason: "switched off")`, and so does one missing a required permission, or
//      one whose `canRun` declined. Restarting on `.inactive` would restart precisely the
//      services a person deliberately turned off — the failure mode the section was written to
//      avoid, arrived at through its own table.
//    - It expected exhaustion to produce a distinct state. It does not: `supervise` gives up,
//      logs and alerts, and leaves the instance in place, so what the registry reports is
//      whatever the service says about itself.
//
//  `.degraded` is out for a different reason: it is genuinely overloaded.
//  `PrivateAPIGatedService` reports it for a Mac with no helper, which is an ordinary Tuesday
//  and not something a network change should restart. `HTTPService` used to report it for a
//  listener that was not listening, which is why that now reports `.failed` — this service and
//  `APIReachability` both needed to tell those two apart, and one case could not carry both.
//
//  So: `.failed` and nothing else. A service that wants to participate says it is failed.
//
//  ## It asks; it does not reach
//
//  `Host` gives it `ServiceRecoveryDriving`, two methods, rather than the registry. A service
//  holding a `ServiceRegistry<AppContext>` could start, stop and re-register anything, which
//  inverts the ownership the registry exists to hold.

import BBBuiltIns
import BBCore
import BBInterfaces
import BBServiceKit
import BBSystem
import Foundation
import Logging

actor NetworkRecoveryService: Service {

  static let manifest = BuiltInManifests.networkRecovery

  /// Nothing here fails in a way a restart repairs: it subscribes to a stream and reads
  /// health. A retry loop would be machinery for an impossible case.
  static let restartPolicy = RestartPolicy.never

  /// The shortest gap between two recovery passes.
  ///
  /// A marginal connection produces transitions for as long as it stays marginal, and the
  /// observer's debounce bounds a single burst rather than a flapping link. Without a floor,
  /// a Wi-Fi radio going up and down every few seconds would restart the same failed service
  /// every few seconds and never let its own backoff run.
  ///
  /// Thirty seconds as a starting point rather than a measurement — `docs/NETWORK_AWARENESS.md`
  /// §7 — and deliberately longer than the registry's own backoff ceiling, so a pass this
  /// service triggers has time to finish being retried before another is allowed.
  static let recoveryFloor = Duration.seconds(30)

  typealias Host = any NetworkPathProviding & ServiceRecoveryDriving & LoggerProviding

  private let observer: NetworkPathObserver
  private let driver: any ServiceRecoveryDriving
  private let logger: Logger
  private let floor: Duration
  private let now: @Sendable () -> ContinuousClock.Instant

  private let follower = OwnedTask()
  private var lastRecovery: ContinuousClock.Instant?

  init(host: Host) {
    self.observer = host.networkPath
    self.driver = host
    self.logger = host.logger
    self.floor = Self.recoveryFloor
    self.now = { ContinuousClock.now }
  }

  /// - Parameters:
  ///   - floor: overridden in tests, which cannot wait thirty seconds to prove the floor
  ///     exists and must not sleep to prove it does not.
  ///   - now: the clock, injected for the same reason.
  init(
    observer: NetworkPathObserver,
    driver: any ServiceRecoveryDriving,
    logger: Logger,
    floor: Duration,
    now: @escaping @Sendable () -> ContinuousClock.Instant
  ) {
    self.observer = observer
    self.driver = driver
    self.logger = logger
    self.floor = floor
    self.now = now
  }

  func start() async throws {
    follower.run { [weak self] in
      guard let stream = await self?.observer.transitions() else { return }
      for await transition in stream {
        if Task.isCancelled { return }
        await self?.handle(transition)
      }
    }
    logger.debug("Watching for a network return")
  }

  /// Waited for: a restart this follow asked for is not cancelled with it (the registry runs
  /// it in the target's own lane), so returning early would let it land after this stop.
  func stop() async {
    await follower.stop()
  }

  var health: ServiceHealth {
    get async { follower.isRunning ? .running : .stopped }
  }

  /// The follow is the service: without it a network return restarts nothing.
  var isAlive: Bool { get async { follower.isRunning } }

  /// One transition. Internal rather than private so a test can drive it without a monitor.
  func handle(_ transition: NetworkTransition) async {
    guard transition.permitsRetry else { return }

    let instant = now()
    if let lastRecovery, instant - lastRecovery < floor {
      logger.trace(
        "Network returned again inside the recovery floor; nothing attempted",
        metadata: ["since": .stringConvertible(instant - lastRecovery)])
      return
    }

    let broken = await driver.serviceHealth().compactMap { id, health -> ServiceIdentifier? in
      guard case .failed = health else { return nil }
      return id
    }
    // The floor is only spent when there was something to do. A network that returns while
    // everything is healthy must not lock out the return thirty seconds later that finds a
    // service genuinely broken.
    guard !broken.isEmpty else {
      logger.debug("Network returned; no failed service to retry")
      return
    }
    lastRecovery = instant

    // Sorted so the order is the same on every run: the registry restarts each service's
    // dependents with it, and two passes that disagreed about the order would be two
    // different sequences of restarts for one cause.
    for id in broken.sorted(by: { $0.rawValue < $1.rawValue }) {
      logger.info(
        "Network returned; retrying a failed service",
        metadata: ["service": .string(id.rawValue)])
      await driver.restartService(id)
    }
  }
}

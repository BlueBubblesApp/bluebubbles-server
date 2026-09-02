//  ServiceRegistry
//  Starts, stops, restarts and supervises every service from what the services declare.
//
//  Start order is DERIVED from declared dependencies, and stop order is exactly its reverse.
//  Settings changes are routed only to services that watch an affected key, and restarting a
//  service restarts its dependents. There is no hand-maintained list anywhere in this file.
//
//  See `.claude/docs/architecture.md`.

import BBCore
import BBSettings
import Foundation
import Logging

/// Somewhere a settings change can be routed to.
///
/// The registry is the only production implementation, but the propagation layer needs
/// exactly this one method out of it — so it depends on the method rather than on a
/// `ServiceRegistry<AppContext>`, which would drag the whole application context into
/// anything that wanted to test routing.
public protocol SettingsChangeRouting: Sendable {
  func apply(_ change: SettingsChange) async
}

public actor ServiceRegistry<Host: Sendable> {

  public struct Registration {
    let id: ServiceID
    let dependencies: [ServiceID]
    let manifest: ServiceManifest
    let restartPolicy: RestartPolicy
    let make: @Sendable (Host) -> any Service
    let watchedSettings: Set<String>
    let requiredPermissions: [PermissionID]
  }

  private var registrations: [ServiceID: Registration] = [:]
  private var instances: [ServiceID: any Service] = [:]
  private var supervisors: [ServiceID: Task<Void, Never>] = [:]
  private var startOrder: [ServiceID] = []
  /// Why a registered service has no instance. `ServiceHealth.inactive` exists to say
  /// "deliberately not running, and here is why" — without recording it, a service that
  /// declined its gate and one that has a missing permission both reported the same
  /// "not started", which is exactly the obscurity the health model was added to remove.
  private var inactiveReasons: [ServiceID: String] = [:]
  /// Services not running because someone switched them off, plus the ones that depend on
  /// those.
  ///
  /// Tracked rather than re-derived, because the second group cannot be recognised by
  /// asking `enablementCheck`: a proxy whose HTTP API is switched off is not itself
  /// switched off, and asking it would say it may run. Holding the set is also what makes
  /// the answer transitive — a dependent of a dependent is blocked by the same lookup.
  private var blocked: Set<ServiceID> = []
  /// True while `startAll` is in flight.
  ///
  /// `start()` awaits each service's own `start()`, and the actor is free during that
  /// await — so a settings change arriving mid-startup could restart a service that had
  /// not started yet, or stop one halfway through starting. Services DO write settings
  /// while starting (the proxy publishes its address), so this is a live path, not a
  /// theoretical one. Changes that land during startup are coalesced and applied once it
  /// finishes, which is also the correct answer: the services are about to read the new
  /// value anyway.
  private var isStarting = false
  private var deferredChange: Set<String> = []

  private let logger = Logger(label: "bluebubbles.services")
  private let host: Host
  private let onAlert: @Sendable (ServiceID, any Error) async -> Void
  /// Consulted before starting a PermissionDependentService, so a missing permission
  /// produces a precise inactive state rather than an obscure failure at first use.
  private let permissionCheck: @Sendable (PermissionID) async -> Bool
  /// Consulted before starting ANY service: has the user switched this one off?
  ///
  /// Separate from `GatedService.canRun`, which is the service's own answer to "am I
  /// applicable" — configured credentials, a selected connection method. This is the host's
  /// answer to "did someone turn this off in the UI", and no service should have to
  /// implement it: a switch that every manageable service must remember to honour is a
  /// switch that some of them will not.
  private let enablementCheck: @Sendable (ServiceID) async -> Bool
  /// Settings keys that can change what `enablementCheck` answers.
  ///
  /// Held so a change to one can re-evaluate every service, which is the half that cannot
  /// come from `watchedSettings`: a service that is switched OFF has no instance, and an
  /// instance is what `watchedSettings` routes a change to.
  private let enablementSettings: Set<String>

  public init(
    host: Host,
    permissionCheck: @escaping @Sendable (PermissionID) async -> Bool = { _ in true },
    enablementCheck: @escaping @Sendable (ServiceID) async -> Bool = { _ in true },
    enablementSettings: Set<String> = [],
    onAlert: @escaping @Sendable (ServiceID, any Error) async -> Void = { _, _ in }
  ) {
    self.host = host
    self.permissionCheck = permissionCheck
    self.enablementCheck = enablementCheck
    self.enablementSettings = enablementSettings
    self.onAlert = onAlert
  }

  // MARK: - Registration

  /// Constrained to services built from THIS registry's host, so a service that needs a
  /// different one is a compile error rather than a crash inside its initialiser.
  public func register<S: Service>(_ type: S.Type) where S.Host == Host {
    let watched = (type as? any ConfigurableService.Type)?.watchedSettings ?? []
    let permissions = (type as? any PermissionDependentService.Type)?.requiredPermissions ?? []
    registrations[type.id] = Registration(
      id: type.id,
      dependencies: type.dependencies,
      manifest: type.manifest,
      restartPolicy: type.restartPolicy,
      make: { host in S(host: host) },
      watchedSettings: watched,
      requiredPermissions: permissions
    )
  }

  public func service(_ id: ServiceID) -> (any Service)? { instances[id] }

  /// Every registered service's manifest, for validation and for the UI.
  public var manifests: [ServiceManifest] {
    registrations.values.map(\.manifest).sorted { $0.id.rawValue < $1.id.rawValue }
  }

  // MARK: - Ordering

  /// Topological sort over declared dependencies.
  ///
  /// Throws on a cycle rather than deadlocking at startup, and names the services
  /// involved — a cycle is a programming error and should fail loudly at launch.
  func resolveStartOrder() throws -> [ServiceID] {
    var resolved: [ServiceID] = []
    var visiting: Set<ServiceID> = []
    var visited: Set<ServiceID> = []

    func visit(_ id: ServiceID, path: [ServiceID]) throws {
      if visited.contains(id) { return }
      if visiting.contains(id) {
        throw ServiceRegistryError.dependencyCycle(path + [id])
      }
      guard let registration = registrations[id] else {
        throw ServiceRegistryError.unknownDependency(id)
      }
      visiting.insert(id)
      for dependency in registration.dependencies {
        try visit(dependency, path: path + [id])
      }
      visiting.remove(id)
      visited.insert(id)
      resolved.append(id)
    }

    // Sorted for determinism: two runs with the same registrations must produce the
    // same order, or a startup bug becomes unreproducible.
    for id in registrations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      try visit(id, path: [])
    }
    return resolved
  }

  /// Everything that depends on `id`, transitively. Used when a restart cascades.
  func dependents(of id: ServiceID) -> Set<ServiceID> {
    var result: Set<ServiceID> = []
    var queue = [id]
    while let current = queue.popLast() {
      for (candidate, registration) in registrations
      where registration.dependencies.contains(current) && !result.contains(candidate) {
        result.insert(candidate)
        queue.append(candidate)
      }
    }
    return result
  }

  // MARK: - Lifecycle

  public func startAll() async throws {
    startOrder = try resolveStartOrder()
    logger.info(
      "Starting services",
      metadata: [
        "order": .string(startOrder.map(\.rawValue).joined(separator: " -> "))
      ])

    isStarting = true
    for id in startOrder {
      await start(id)
    }
    isStarting = false

    // Anything that arrived while we were coming up, applied once now that every
    // service exists and can be asked about it.
    if !deferredChange.isEmpty {
      let pending = deferredChange
      deferredChange = []
      logger.debug(
        "Applying settings changes deferred during startup",
        metadata: [
          "keys": .string(pending.sorted().joined(separator: ", "))
        ])
      await apply(SettingsChange(changedKeys: pending))
    }
  }

  public func start(_ id: ServiceID) async {
    guard let registration = registrations[id] else { return }
    guard instances[id] == nil else { return }

    // A missing required permission is a normal, reportable state — not a crash and not
    // a silent no-op.
    for permission in registration.requiredPermissions
    where await !permissionCheck(permission) {
      logger.notice(
        "Service inactive: missing permission",
        metadata: [
          "service": .string(id.rawValue),
          "permission": .string(permission.rawValue),
        ])
      inactiveReasons[id] = "requires the \(permission.rawValue) permission"
      return
    }

    // Checked BEFORE the instance is made: a service the user switched off should not
    // have its initialiser run, since that is where several of them open files and
    // capture resources.
    if await !enablementCheck(id) {
      logger.debug(
        "Service inactive: switched off",
        metadata: [
          "service": .string(id.rawValue)
        ])
      inactiveReasons[id] = "switched off"
      blocked.insert(id)
      return
    }

    // A dependency someone switched off takes its dependents with it. A tunnel published
    // for an HTTP server that is not listening is worse than no tunnel: it is an address
    // that resolves, accepts a connection, and fails.
    if let culprit = registration.dependencies.first(where: { blocked.contains($0) }) {
      logger.notice(
        "Service inactive: a dependency is switched off",
        metadata: [
          "service": .string(id.rawValue),
          "dependency": .string(culprit.rawValue),
        ])
      inactiveReasons[id] = "\(culprit.rawValue) is switched off"
      blocked.insert(id)
      return
    }

    blocked.remove(id)

    let instance = registration.make(host)

    // A gated service declining is likewise normal — it is how only the configured
    // proxy starts, replacing Proxy.canStart() and the inline `if privateApiEnabled`.
    if let gated = instance as? any GatedService, await !gated.canRun() {
      logger.debug(
        "Service inactive: gate declined",
        metadata: [
          "service": .string(id.rawValue)
        ])
      inactiveReasons[id] = "disabled by configuration"
      return
    }

    inactiveReasons[id] = nil
    instances[id] = instance

    // Read out of the registration before any Task. The registration itself is
    // actor-isolated and not Sendable, so capturing it would hand isolated state to a
    // concurrently-running closure; RestartPolicy is Sendable and is all the supervisor
    // needs.
    let policy = registration.restartPolicy

    // THE FIRST ATTEMPT IS AWAITED, not spawned.
    //
    // Spawning it would make the topological sort order task CREATION rather than actual
    // startup, so a dependent could run its `start()` before its dependency had run —
    // the exact failure the sort exists to prevent. It surfaced as an ordering test that
    // failed roughly one run in six, which is precisely how this would show up in
    // production: rarely, on a loaded machine, as an unreproducible startup bug.
    do {
      try await instance.start()
      // Returned cleanly, so the service is up. `Service.start()` brings a service up
      // and returns; anything long-running is the service's own task to hold.
      return
    } catch is CancellationError {
      return
    } catch {
      // Retries move to the background so one failing service does not hold the rest
      // of startup behind its backoff — which can run to minutes.
      supervisors[id] = Task { [weak self] in
        await self?.supervise(
          id: id, instance: instance, policy: policy, startingAt: 2, lastError: error
        )
      }
    }
  }

  /// Runs a service under its restart policy.
  ///
  /// Retries with backoff and gives up per the policy; a failing service never takes the
  /// application down with it.
  /// - Parameters:
  ///   - startingAt: Which attempt number this begins on. `start(_:)` performs attempt 1
  ///     inline so that startup ordering is real, and hands the remainder here.
  ///   - lastError: The failure that brought us here, so an immediately-exhausted policy
  ///     still alerts with a cause rather than with nothing.
  private func supervise(
    id: ServiceID,
    instance: any Service,
    policy: RestartPolicy,
    startingAt: Int = 1,
    lastError: (any Error)? = nil
  ) async {
    var attempt = startingAt

    // A policy already exhausted by the inline attempt never enters the loop, so the
    // alert has to be raised here.
    if case .backoff(_, _, let maxAttempts) = policy, attempt > maxAttempts,
      let lastError
    {
      logger.error(
        "Service failed permanently",
        metadata: [
          "service": .string(id.rawValue),
          "error": .string(String(describing: lastError)),
        ])
      await onAlert(id, lastError)
      return
    }
    if case .never = policy, let lastError {
      logger.error(
        "Service failed and its policy forbids restarting",
        metadata: [
          "service": .string(id.rawValue),
          "error": .string(String(describing: lastError)),
        ])
      await onAlert(id, lastError)
      return
    }

    // The first supervised attempt waits out the backoff for its own attempt number,
    // rather than retrying instantly on top of the inline failure.
    if startingAt > 1, case .backoff(_, _, let maxAttempts) = policy {
      let delay = RetryPolicy(
        maxAttempts: maxAttempts,
        initialDelay: policy.baseDelay,
        maxDelay: policy.maxDelay
      ).delay(forAttempt: attempt)
      try? await Task.sleep(for: delay)
      if Task.isCancelled { return }
    }

    while !Task.isCancelled {
      do {
        try await instance.start()
        return
      } catch is CancellationError {
        return
      } catch {
        guard case .backoff(_, _, let maxAttempts) = policy, attempt < maxAttempts else {
          logger.error(
            "Service failed permanently",
            metadata: [
              "service": .string(id.rawValue),
              "error": .string(String(describing: error)),
            ])
          // Policy exhausted: raise, do not relaunch the app.
          await onAlert(id, error)
          return
        }

        let delay = RetryPolicy(
          maxAttempts: maxAttempts,
          initialDelay: policy.baseDelay,
          maxDelay: policy.maxDelay
        ).delay(forAttempt: attempt + 1)

        logger.warning(
          "Service failed; retrying",
          metadata: [
            "service": .string(id.rawValue),
            "attempt": .stringConvertible(attempt),
            "error": .string(String(describing: error)),
          ])
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  public func stopAll() async {
    // Exactly the reverse of start order. The current implementation stops in a
    // different, hand-maintained order than it starts.
    for id in startOrder.reversed() {
      await stop(id)
    }
  }

  public func stop(_ id: ServiceID) async {
    supervisors[id]?.cancel()
    supervisors[id] = nil
    if let instance = instances[id] {
      await instance.stop()
    }
    instances[id] = nil
  }

  public func restart(_ id: ServiceID) async {
    await stop(id)
    await start(id)
  }

  /// Restarts a service and everything that depends on it, in order.
  public func restartWithDependents(_ id: ServiceID) async {
    let affected = dependents(of: id).union([id])
    let ordered = startOrder.filter { affected.contains($0) }
    for target in ordered.reversed() { await stop(target) }
    for target in ordered { await start(target) }
  }

  // MARK: - Settings changes

  /// Routes a change to the services that care, and acts on what they return.
  ///
  /// This is the whole of what handleConfigUpdate did, minus the if-chain and the manual
  /// `proxiesRestarted` latch: coalescing falls out of collecting the requests first and
  /// acting once.
  public func apply(_ change: SettingsChange) async {
    guard !isStarting else {
      deferredChange.formUnion(change.changedKeys)
      return
    }

    // Enablement first, and separately, because it is the one change that must reach a
    // service with NO INSTANCE. The loop below routes a change to `instances[id]`, so a
    // service that is switched off cannot be told that it has been switched back on —
    // it would stay off until the next full restart, which is indistinguishable from the
    // switch not working.
    if change.intersects(enablementSettings) {
      await applyEnablement()
    }

    var toRestart: Set<ServiceID> = []

    for id in startOrder {
      guard let registration = registrations[id],
        registration.watchedSettings.isEmpty == false,
        change.intersects(registration.watchedSettings),
        let configurable = instances[id] as? any ConfigurableService
      else { continue }

      do {
        switch try await configurable.apply(change) {
        case .none, .reconfigure:
          break
        case .restart:
          toRestart.insert(id)
        }
      } catch {
        logger.error(
          "Service rejected settings change",
          metadata: [
            "service": .string(id.rawValue),
            "error": .string(String(describing: error)),
          ])
        await onAlert(id, error)
      }
    }

    // Expand to dependents once, so a socket_port change restarts the HTTP service and
    // the proxies that depend on it without anyone hand-coding that relationship.
    var expanded: Set<ServiceID> = []
    for id in toRestart { expanded.formUnion(dependents(of: id).union([id])) }

    let ordered = startOrder.filter { expanded.contains($0) }
    guard !ordered.isEmpty else { return }

    logger.info(
      "Restarting services for settings change",
      metadata: [
        "services": .string(ordered.map(\.rawValue).joined(separator: ", "))
      ])
    for id in ordered.reversed() { await stop(id) }
    for id in ordered { await start(id) }
  }

  /// Brings what is running into line with what the user has switched on.
  ///
  /// Stops in reverse order and starts in forward order, for the same reason `startAll`
  /// does: a service switched off may be one another depends on.
  ///
  /// `start` is attempted for anything not currently running rather than only for services
  /// known to have been switched off — it re-checks permissions and gates itself, so the
  /// worst case is that a service inactive for some other reason stays inactive.
  private func applyEnablement() async {
    var switchedOff: Set<ServiceID> = []
    for id in startOrder where await !enablementCheck(id) { switchedOff.insert(id) }

    // Everything switched off, plus everything that depends on it.
    var toStop: Set<ServiceID> = []
    for id in switchedOff { toStop.formUnion(dependents(of: id).union([id])) }

    for id in startOrder.reversed() where toStop.contains(id) && instances[id] != nil {
      logger.info(
        "Stopping service: switched off",
        metadata: [
          "service": .string(id.rawValue)
        ])
      await stop(id)
      inactiveReasons[id] =
        switchedOff.contains(id)
        ? "switched off"
        : "a service it depends on is switched off"
      blocked.insert(id)
    }

    // Forward order, so a dependency is running again before its dependents are asked to
    // start. `start` re-checks permissions and gates itself, so attempting one that is
    // inactive for some other reason simply leaves it inactive.
    for id in startOrder where instances[id] == nil && !toStop.contains(id) {
      blocked.remove(id)
      await start(id)
    }
  }

  // MARK: - Health

  public func health() async -> [ServiceID: ServiceHealth] {
    var result: [ServiceID: ServiceHealth] = [:]
    // Every REGISTERED service, not only those in `startOrder` — which is empty until
    // `startAll()` runs. Reporting on the start order alone means a server that failed
    // before startup reports no services at all rather than nine stopped ones.
    let all =
      startOrder.isEmpty
      ? registrations.keys.sorted { $0.rawValue < $1.rawValue }
      : startOrder
    for id in all {
      if let instance = instances[id] {
        result[id] = await instance.health
      } else if registrations[id] != nil {
        result[id] = .inactive(reason: inactiveReasons[id] ?? "not started")
      }
    }
    return result
  }
}

public enum ServiceRegistryError: BBError, Equatable {
  case dependencyCycle([ServiceID])
  case unknownDependency(ServiceID)
}

extension RestartPolicy {
  var baseDelay: Duration {
    if case .backoff(let base, _, _) = self { return base }
    return .seconds(1)
  }
  var maxDelay: Duration {
    if case .backoff(_, let max, _) = self { return max }
    return .seconds(60)
  }
}

extension ServiceRegistry: SettingsChangeRouting {}

extension ServiceRegistryError {
  public var code: String {
    switch self {
    case .dependencyCycle: "services.dependency_cycle"
    case .unknownDependency: "services.unknown_dependency"
    }
  }

  public var domain: String { "Services" }

  /// A programming error that stops the whole server coming up, so it fails loudly.
  public var severity: Severity { .critical }

  public var title: String { "The service graph is invalid" }

  public var body: String {
    switch self {
    case .dependencyCycle(let path):
      "These services depend on each other in a loop: "
        + path.map(\.rawValue).joined(separator: " → ")
    case .unknownDependency(let id):
      "A service depends on \(id.rawValue), which is not registered."
    }
  }
}

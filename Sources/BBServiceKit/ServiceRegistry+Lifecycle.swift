//  ServiceRegistry+Lifecycle
//  Starting, stopping and restarting services, each through its own lane, and the
//  supervision that retries a start that threw.
//
//  Its own file so a reader changing how a service comes up or goes down reads the lifecycle
//  and not the registry around it. The state it works on is declared in
//  `ServiceRegistry.swift`, because an extension cannot hold stored properties.

import BBCore
import BBSettings
import Foundation
import Logging

extension ServiceRegistry {

  // MARK: - Lifecycle

  public func startAll() async throws {
    startOrder = try resolveStartOrder()
    logger.info(
      "Starting services",
      metadata: [
        "order": .string(startOrder.map(\.rawValue).joined(separator: " -> "))
      ])

    isStopped = false
    isStarting = true
    await markSwitchedOffAhead()
    for id in startOrder {
      await start(id)
    }
    isStarting = false
    startLivenessPolling()

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
    if !deferredGrants.isEmpty {
      let pending = deferredGrants
      deferredGrants = []
      await permissionsGranted(pending)
    }
  }

  /// Records, before anything starts, which services are switched off or stranded behind one
  /// that is, so they read as off from the first health snapshot.
  ///
  /// Without it every service reads `.waiting(on: .queued)` until startup reaches it, and the
  /// ones that turn out to be switched off leave the count only then: Home's "waiting" figure
  /// and its bar counted services that were never going to run, and shrank as startup
  /// discovered them. Only the two answers that need no instance are given here; a gate that
  /// declines (`canRun`) still has to be reached, because asking it means building the service.
  /// `start` checks both again when it gets there, so nothing here decides whether anything
  /// runs.
  func markSwitchedOffAhead() async {
    var off: Set<ServiceIdentifier> = []
    for id in startOrder {
      guard let registration = registrations[id] else { continue }
      if await !enablementCheck(id) {
        off.insert(id)
        notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.switchedOff)
      } else if registration.dependencies.contains(where: off.contains) {
        off.insert(id)
        notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.dependencySwitchedOff)
      }
    }
  }

  /// Starts a service, after whatever its lane was already doing.
  ///
  /// Idempotent for a running service, and a start queued behind a stop runs after it, so
  /// `stop` then `start` from two callers is a restart, never a stop that lands mid-start.
  public func start(_ id: ServiceIdentifier) async {
    // Somebody asked for this, so whatever the poll had counted against the service is no
    // longer the current story.
    revivals[id] = 0
    await serialized(id) { await self.performStart(id) }
    requestHealthPublication()
  }

  /// Runs `operation` once this service's lane is free, and holds the lane until it returns.
  ///
  /// Every lifecycle operation for one service is chained onto the last, which is what makes
  /// "the actor is free while a service starts" safe: a second operation cannot observe the
  /// half-started state because it cannot run yet. The chain is a task that awaits the
  /// previous task, so nothing here blocks the actor, and a caller that is cancelled stops
  /// waiting without cancelling the operation: a half-run stop is worse than a late one.
  func serialized<T: Sendable>(
    _ id: ServiceIdentifier,
    _ operation: @escaping @Sendable () async -> T
  ) async -> T {
    let previous = lanes[id]
    let task = Task<T, Never> {
      await previous?.value
      return await operation()
    }
    let marker = Task<Void, Never> { _ = await task.value }
    lanes[id] = marker
    let result = await task.value
    if lanes[id] == marker { lanes[id] = nil }
    return result
  }

  private func markStart(_ id: ServiceIdentifier, inFlight: Bool) async {
    if inFlight { startsInFlight.insert(id) } else { startsInFlight.remove(id) }
    requestHealthPublication()
  }

  func performStart(_ id: ServiceIdentifier) async {
    guard let registration = registrations[id] else { return }
    guard instances[id] == nil else { return }
    gaveUp[id] = nil

    // Ahead of every check below, because any of them can refuse. See `Service.beforeGates`.
    let beforeGates = registration.beforeGates
    await AuditContext.acting(as: .system(component: id.rawValue)) { [host] in
      await beforeGates(host)
    }

    // A missing required permission is a normal, reportable state, not a crash and not
    // a silent no-op. `permissionsGranted` is what comes back to it.
    for permission in registration.requiredPermissions
    where await !permissionCheck(permission) {
      logger.notice(
        "Service inactive: missing permission",
        metadata: [
          "service": .string(id.rawValue),
          "permission": .string(permission.rawValue),
        ])
      // WAITING, not inactive: `permissionsGranted` starts it the moment the grant lands.
      notRunning[id] = .waiting(
        reason: missingPermissionReason(permission, in: registration.manifest),
        on: .permission)
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
      notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.switchedOff)
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
      // The same sentence `applyEnablement` records, so one condition reads one way
      // whether it arose at startup or from a switch. It also says no identifier: this
      // reaches a screen, and `app.bluebubbles.core.http` names nothing a person can act
      // on. Whoever renders it holds the manifests and can say "Needs HTTP API"; the
      // culprit is in the log line above for anyone reading a log.
      notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.dependencySwitchedOff)
      blocked.insert(id)
      return
    }

    blocked.remove(id)

    let instance = registration.make(host)

    // A gated service declining is likewise normal: it is how only the configured
    // proxy starts, replacing Proxy.canStart() and the inline `if privateApiEnabled`.
    if let gated = instance as? any GatedService, await !gated.canRun() {
      logger.debug(
        "Service inactive: gate declined",
        metadata: [
          "service": .string(id.rawValue)
        ])
      notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.disabledByConfiguration)
      return
    }

    notRunning[id] = nil
    instances[id] = instance

    // Read out of the registration before any Task. The registration itself is
    // actor-isolated and not Sendable, so capturing it would hand isolated state to a
    // concurrently-running closure; RestartPolicy is Sendable and is all the supervisor
    // needs.
    let policy = registration.restartPolicy

    // THE FIRST ATTEMPT IS AWAITED, not spawned.
    //
    // Spawning it would make the topological sort order task CREATION rather than actual
    // startup, so a dependent could run its `start()` before its dependency had run:
    // the exact failure the sort exists to prevent. It surfaced as an ordering test that
    // failed roughly one run in six, which is precisely how this would show up in
    // production: rarely, on a loaded machine, as an unreproducible startup bug.
    startsInFlight.insert(id)
    defer { startsInFlight.remove(id) }
    requestHealthPublication()
    let started = ContinuousClock.now
    do {
      // As the service, so a setting it writes while starting is recorded against it rather
      // than against the person who happened to press Start. A task the service spawns here
      // inherits the same actor. See `AuditContext`.
      try await AuditContext.acting(as: .system(component: id.rawValue)) {
        try await instance.start()
      }
      // Returned cleanly, so the service is up. `Service.start()` brings a service up
      // and returns; anything long-running is the service's own task to hold.
      logger.info(
        "Service started",
        metadata: [
          "service": .string(id.rawValue),
          "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
        ])
      return
    } catch is CancellationError {
      return
    } catch {
      await undoFailedStart(id, instance)
      // Retries move to the background so one failing service does not hold the rest
      // of startup behind its backoff, which can run to minutes.
      supervisors[id] = Task { [weak self] in
        await self?.supervise(
          id: id, instance: instance, policy: policy, startingAt: 2, lastError: error
        )
      }
    }
  }

  /// Why a service is not running, in the words of the permission's title and of the
  /// manifest's own reason for needing it: "needs Full Disk Access so it can read your messages
  /// to build the search index". This reaches a screen, so it names nothing a person cannot
  /// recognise.
  private func missingPermissionReason(
    _ permission: PermissionID, in manifest: ServiceManifest
  ) -> String {
    let title = permissionTitle(permission)
    guard let purpose = manifest.permissions.first(where: { $0.id == permission })?.purpose
    else { return "needs \(title)" }
    return "needs \(title) \(purpose)"
  }

  /// Stops a service whose `start()` threw, before anything else happens to it.
  ///
  /// A start that fails part-way has already done part of its work: bound a socket, attached
  /// a pump, published a client. Retrying `start()` on top of that leaked each attempt's
  /// share, which the Private API service found as five bound sockets nothing would close,
  /// and a service given up on held its share until the server stopped. `Service.start()`
  /// states this call as part of the contract, so no service has to learn it again.
  private func undoFailedStart(_ id: ServiceIdentifier, _ instance: any Service) async {
    await AuditContext.acting(as: .system(component: id.rawValue)) { await instance.stop() }
  }

  /// Logs a permanent failure and raises it. The two callers below differ only in how they
  /// discovered the policy was out of attempts.
  ///
  /// The instance, already stopped by `undoFailedStart`, is dropped, but only if it is still
  /// the one registered: a stop that ran in the meantime has already removed it. Checked
  /// again after reading its health, which suspends.
  private func giveUp(
    id: ServiceIdentifier, instance: any Service, error: any Error, policy: RestartPolicy
  ) async {
    if let current = instances[id], current === instance {
      // The service's own account where it gives one, since that is written for the row it
      // appears in; the error's sentence otherwise.
      let health = await instance.health
      if let still = instances[id], still === instance {
        if case .failed(let reason) = health {
          gaveUp[id] = reason
        } else {
          gaveUp[id] = DiagnosticText.sentence(for: error)
        }
        instances[id] = nil
      }
    }
    supervisors[id] = nil
    logger.error(
      policy.forbidsRestart
        ? "Service failed and its policy forbids restarting"
        : "Service failed permanently",
      metadata: [
        "service": .string(id.rawValue),
        "error": .string(String(describing: error)),
      ])
    await onAlert(id, error)
    requestHealthPublication()
  }

  /// Runs a service under its restart policy.
  ///
  /// Retries with backoff and gives up per the policy; a failing service never takes the
  /// application down with it. Every failed attempt is stopped before the next one, or before
  /// giving up; see `undoFailedStart`.
  /// - Parameters:
  ///   - startingAt: Which attempt number this begins on. `start(_:)` performs attempt 1
  ///     inline so that startup ordering is real, and hands the remainder here.
  ///   - lastError: The failure that brought us here, so an immediately-exhausted policy
  ///     still alerts with a cause rather than with nothing.
  private func supervise(
    id: ServiceIdentifier,
    instance: any Service,
    policy: RestartPolicy,
    startingAt: Int = 1,
    lastError: (any Error)? = nil
  ) async {
    var attempt = startingAt

    // A policy already exhausted by the inline attempt never enters the loop, so the alert
    // has to be raised here rather than by the loop's own give-up path.
    if let lastError, !policy.permits(attempt: attempt) {
      await giveUp(id: id, instance: instance, error: lastError, policy: policy)
      return
    }

    // The first supervised attempt waits out the backoff for its own attempt number,
    // rather than retrying instantly on top of the inline failure.
    if startingAt > 1, let delay = policy.delay(forAttempt: attempt) {
      try? await clock.sleep(for: delay)
      if Task.isCancelled { return }
    }

    while !Task.isCancelled {
      // Through the service's lane, like the first attempt. A retry that ran outside it
      // could overlap a `stop`, which is the interleaving the lanes exist to rule out.
      let attemptOutcome: Result<Void, any Error> = await serialized(id) { [weak self] in
        await self?.markStart(id, inFlight: true)
        await self?.askPermissionsAgain(for: id)
        let outcome: Result<Void, any Error>
        do {
          try await AuditContext.acting(as: .system(component: id.rawValue)) {
            try await instance.start()
          }
          outcome = .success(())
        } catch is CancellationError {
          outcome = .failure(CancellationError())
        } catch {
          // In the same lane as the attempt, so a `stop` or `restart` queued behind it finds
          // the service already torn down rather than half-started.
          await self?.undoFailedStart(id, instance)
          outcome = .failure(error)
        }
        await self?.markStart(id, inFlight: false)
        return outcome
      }
      switch attemptOutcome {
      case .success:
        // Up, so the liveness poll watches it again (`checkLiveness` skips a service under
        // supervision). Not when cancelled: a stop or restart has already replaced this
        // supervisor, possibly with a new one that must stay.
        if !Task.isCancelled { supervisors[id] = nil }
        return
      case .failure(is CancellationError):
        return
      case .failure(let error):
        // Policy exhausted: raise, do not relaunch the app.
        guard policy.permits(attempt: attempt + 1) else {
          await giveUp(id: id, instance: instance, error: error, policy: policy)
          return
        }
        let delay = policy.delay(forAttempt: attempt + 1) ?? .zero

        logger.warning(
          "Service failed; retrying",
          metadata: [
            "service": .string(id.rawValue),
            "attempt": .stringConvertible(attempt),
            "error": .string(String(describing: error)),
          ])
        attempt += 1
        try? await clock.sleep(for: delay)
      }
    }
  }

  /// Asks a retry's permissions again, for what asking does rather than for the answer.
  ///
  /// A retry reuses its instance and skips `performStart`, so without this the one thing that
  /// could change the outcome never runs: the composition's gate opens `chat.db` when it asks
  /// about Full Disk Access, and a database that would not open at the first attempt was never
  /// tried again until something else started. The answer is not acted on: a permission lost
  /// since the last attempt fails the attempt as any other cause does, and the budget ends it.
  private func askPermissionsAgain(for id: ServiceIdentifier) async {
    for permission in registrations[id]?.requiredPermissions ?? [] {
      _ = await permissionCheck(permission)
    }
  }
}

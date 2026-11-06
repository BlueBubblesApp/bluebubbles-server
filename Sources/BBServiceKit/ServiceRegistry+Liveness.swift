//  ServiceRegistry+Liveness
//  The poll that finds a service which has stopped answering and revives it, within a limit.
//
//  Its own file so the revival rules are read together. The revival count and the poll's task
//  are declared in `ServiceRegistry.swift`, because an extension cannot hold stored properties.

import BBCore
import BBSettings
import Foundation
import Logging

extension ServiceRegistry {

  // MARK: - Liveness

  /// Starts the liveness poll. Idempotent; called by `startAll`.
  ///
  /// The same tick asks for a health sweep (`requestHealthPublication`), the safety net under
  /// `noteHealthChanged()` for a service whose health moved without a report. Nothing
  /// downstream churns on it, because an unchanged snapshot is not published.
  func startLivenessPolling() {
    livenessTask.runPeriodically(
      every: ServiceLiveness.interval, after: ServiceLiveness.interval
    ) { [weak self] in
      await self?.checkLiveness()
      await self?.requestHealthPublication()
    }
  }

  /// Asks every running service whether its own work is still going, and revives what is not.
  ///
  /// **`isAlive`, never `health`.** `SocketService.health` is `.degraded` whenever no client is
  /// connected and `ProxyService.health` is `.inactive` when a tunnel is switched off; both are
  /// ordinary states, and a supervisor acting on them would restart a working server all day.
  /// No service's `health` has ever returned `.failed`, so watching for that would watch for
  /// ever. `isAlive` answers the one question a supervisor can act on.
  func checkLiveness() async {
    for id in startOrder {
      guard let instance = instances[id] else { continue }
      // Not while its own lane is busy: a service part-way through a deliberate start or stop
      // is legitimately between states, and reviving it there would race the operation that is
      // already running.
      guard lanes[id] == nil, !startsInFlight.contains(id) else { continue }
      // Nor while its restart policy has it. A start that threw leaves the stopped instance
      // registered while the supervisor waits out the backoff, and that instance answers
      // `isAlive == false`. Reviving it there would cancel the supervisor and begin the
      // policy again from its second attempt, so the policy would bound nothing.
      guard supervisors[id] == nil else { continue }
      guard await instance.isAlive == false else { continue }

      let count = revivals[id, default: 0]
      guard count < ServiceLiveness.maximumRevivals else { continue }
      revivals[id] = count + 1

      logger.warning(
        "Service stopped on its own; restarting it",
        metadata: [
          "service": .string(id.rawValue),
          "attempt": .stringConvertible(count + 1),
        ])
      await revive(id)

      // Told only when the budget is spent, so a service that dies once and comes back does
      // not put a notice in front of anyone. One that will not stay up is worth interrupting
      // for: its feature is gone until somebody acts.
      if revivals[id] == ServiceLiveness.maximumRevivals, await instances[id]?.isAlive != true {
        await onAlert(id, ServiceLivenessError(id: id, attempts: ServiceLiveness.maximumRevivals))
      }
    }
  }

  /// Whether a service's restart policy has it, for a test to wait on rather than guess.
  func isSupervising(_ id: ServiceIdentifier) -> Bool { supervisors[id] != nil }

  private func stopLivenessPolling() {
    livenessTask.cancel()
  }

  public func stopAll() async {
    isStopped = true
    deferredGrants = []
    stopLivenessPolling()
    // Exactly the reverse of start order. The current implementation stops in a
    // different, hand-maintained order than it starts.
    for id in startOrder.reversed() {
      await stop(id)
    }
  }

  /// Stops a service, after whatever its lane was already doing.
  ///
  /// The supervisor is cancelled at once rather than when the lane gets round to it, so a
  /// retry loop schedules no further attempt; an attempt already in the lane finishes, and
  /// the stop runs after it against a service that is genuinely up or genuinely failed.
  public func stop(_ id: ServiceIdentifier) async {
    revivals[id] = 0
    supervisors[id]?.cancel()
    await serialized(id) { await self.performStop(id) }
    requestHealthPublication()
  }

  private func performStop(_ id: ServiceIdentifier) async {
    supervisors[id]?.cancel()
    supervisors[id] = nil
    if let instance = instances[id] {
      await AuditContext.acting(as: .system(component: id.rawValue)) { await instance.stop() }
      logger.debug("Service stopped", metadata: ["service": .string(id.rawValue)])
    }
    instances[id] = nil
    gaveUp[id] = nil
    // Stopped, not queued: without a record `health()` reports a service the registry has
    // not reached YET, which is true during a start and false after a stop. A switch that
    // stopped it records its own reason right after this.
    if notRunning[id] == nil {
      notRunning[id] = .inactive(reason: ServiceHealth.RoutineReason.notStarted)
    }
  }

  /// One lane operation, not two: a second restart queued behind this one runs its stop
  /// after this one's start, so two restarts are a stop, a start, a stop and a start, in
  /// that order and never interleaved.
  public func restart(_ id: ServiceIdentifier) async {
    // A DELIBERATE restart clears the revival budget; the liveness poll's own revivals go
    // through `revive` and do not, or a service that dies once a minute would be restarted
    // for ever by a budget that reset itself every time it was spent.
    revivals[id] = 0
    await revive(id)
  }

  /// The restart itself, without touching the revival budget.
  private func revive(_ id: ServiceIdentifier) async {
    logger.info("Restarting service", metadata: ["service": .string(id.rawValue)])
    supervisors[id]?.cancel()
    await serialized(id) {
      await self.performStop(id)
      await self.performStart(id)
    }
    requestHealthPublication()
  }
}

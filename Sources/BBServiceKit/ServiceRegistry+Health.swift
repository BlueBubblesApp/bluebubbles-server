//  ServiceRegistry+Health
//  What each service reports about itself, and the stream that publishes it when it moves.
//
//  Its own file so the health model is read in one place. What was last published is declared
//  in `ServiceRegistry.swift`, because an extension cannot hold stored properties.
//
//  **No lifecycle operation waits for a health read.** A transition asks for a snapshot
//  (`requestHealthPublication`) and carries on; one publisher task reads and publishes, and
//  requests that land while it reads are folded into its next pass. A `health` getter is a
//  call into a service that the registry does not control, and the getters that do real work
//  are the ones that are slow on a loaded machine: an `SMAppService` read can take tens of
//  seconds on a Mac with little memory and a spinning disk, and with three full snapshots
//  awaited per service started, startup ran to many minutes while each `start()` took
//  milliseconds. Waiting here put every getter on the critical path of startup.

import BBCore
import BBSettings
import Foundation
import Logging

extension ServiceRegistry {

  // MARK: - Health

  public func health() async -> [ServiceIdentifier: ServiceHealth] {
    var result: [ServiceIdentifier: ServiceHealth] = [:]
    // Every REGISTERED service, not only those in `startOrder`, which is empty until
    // `startAll()` runs. Reporting on the start order alone means a server that failed
    // before startup reports no services at all rather than nine stopped ones.
    let all =
      startOrder.isEmpty
      ? registrations.keys.sorted { $0.rawValue < $1.rawValue }
      : startOrder
    for id in all {
      result[id] = await healthEntry(for: id)
    }
    return result
  }

  /// One service's line in the snapshot; nil for an identifier nothing registered.
  private func healthEntry(for id: ServiceIdentifier) async -> ServiceHealth? {
    if startsInFlight.contains(id) { return .starting }
    if let instance = instances[id] { return await instance.health }
    if let reason = gaveUp[id] { return .failed(reason: reason) }
    if registrations[id] != nil {
      return notRunning[id]
        ?? .waiting(reason: ServiceHealth.RoutineReason.notStarted, on: .queued)
    }
    return nil
  }

  /// Every service's health, again whenever any of it changes.
  ///
  /// A snapshot rather than a per-service delta, because a consumer draws the whole table
  /// and a delta would leave it reconciling. Published after every lifecycle transition the
  /// registry performs and whenever a service reports through `noteHealthChanged()`; the
  /// newest snapshot is kept for a slow consumer, so it sees the current state rather than a
  /// backlog. A consumer that needs the state before the first change reads `health()`.
  public func healthChanges() -> AsyncStream<[ServiceIdentifier: ServiceHealth]> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: [ServiceIdentifier: ServiceHealth].self, bufferingPolicy: .bufferingNewest(1)
    )
    let id = UUID()
    healthSubscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeHealthSubscriber(id) }
    }
    return stream
  }

  /// A service's health moved on its own (a tunnel dropped, a helper connected) and the
  /// registry did not perform the transition, so it is told.
  ///
  /// Re-reads THAT service and nothing else. Some `health` getters do real work (a query over
  /// the webhook table), and a report that re-read every
  /// service put all of it on the reporter's schedule: the search backfill reports every few
  /// seconds while it builds. Every other line is what was last published, which each
  /// lifecycle transition and the periodic sweep refresh in full.
  public func noteHealthChanged(_ id: ServiceIdentifier) async {
    guard !healthSubscribers.isEmpty else { return }
    let entry = await healthEntry(for: id)
    // Read after the await, so a full publication that landed meanwhile is built on rather
    // than overwritten.
    guard var snapshot = lastPublishedHealth else { return requestHealthPublication() }
    snapshot[id] = entry
    publish(snapshot)
  }

  private func removeHealthSubscriber(_ id: UUID) {
    healthSubscribers[id] = nil
  }

  /// Asks for every service's health to be read and published, and returns at once.
  ///
  /// Coalesced: one publisher reads at a time, and any number of requests made while it reads
  /// cost one more pass, not one each, so a burst of transitions during startup is a handful
  /// of snapshots rather than three per service. The newest state always wins, because the
  /// pass that follows a request starts after it.
  ///
  /// Equal snapshots are not published, which is what makes the periodic sweep free for
  /// consumers: the app re-renders every row that shows a service on each snapshot. A
  /// consumer that subscribes later reads `health()` for the current state, so skipping an
  /// equal snapshot loses nobody anything.
  func requestHealthPublication() {
    guard !healthSubscribers.isEmpty else { return }
    healthPublicationPending = true
    // A flag of its own rather than `healthPublisher.isRunning`: the publisher's handle is
    // cleared after its body returns, and a request landing in that gap would see a publisher
    // that has already decided it is finished, and be lost.
    guard !healthPublisherActive else { return }
    healthPublisherActive = true
    healthPublisher.run { [weak self] in await self?.drainHealthPublications() }
  }

  /// The publisher's body: reads and publishes until no request is outstanding.
  ///
  /// The loop's exit and the flag that lets the next request start a publisher are one
  /// synchronous step on the actor, so no request can fall between them.
  private func drainHealthPublications() async {
    while healthPublicationPending, !Task.isCancelled {
      healthPublicationPending = false
      publish(await health())
    }
    healthPublisherActive = false
  }

  private func publish(_ snapshot: [ServiceIdentifier: ServiceHealth]) {
    guard snapshot != lastPublishedHealth else { return }
    lastPublishedHealth = snapshot
    for continuation in healthSubscribers.values {
      continuation.yield(snapshot)
    }
  }
}

//  ServiceHealthStreamTests
//  The registry's health stream: what publishes a snapshot, and what a consumer sees.
//
//  The app draws service state from this stream rather than polling `health()`, so the
//  properties that matter are that a transition the registry performs publishes without
//  being asked, and that a service whose health moved on its own can ask.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBServiceKit

/// The next snapshot satisfying `predicate`, or nil if none arrives in time.
///
/// A deadline rather than an open `for await`: the failure this guards against is a
/// snapshot that never comes, and without one that is a hung test rather than a red one.
private func nextSnapshot(
  in stream: AsyncStream<[ServiceIdentifier: ServiceHealth]>,
  timeout: Duration = .seconds(5),
  where predicate: @escaping @Sendable ([ServiceIdentifier: ServiceHealth]) -> Bool
) async -> [ServiceIdentifier: ServiceHealth]? {
  await withTaskGroup(of: [ServiceIdentifier: ServiceHealth]?.self) { group in
    group.addTask {
      for await snapshot in stream where predicate(snapshot) { return snapshot }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}

@Suite("Health stream", .serialized)
struct ServiceHealthStreamTests {

  private static let database = ServiceIdentifier("database")

  @Test("Starting and stopping a service publishes a snapshot")
  func lifecyclePublishes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    let changes = await registry.healthChanges()

    try await registry.startAll()
    let running = await nextSnapshot(in: changes) { $0[Self.database] == .running }
    #expect(running != nil, "no snapshot reported the service running")

    await registry.stopAll()
    let stopped = await nextSnapshot(in: changes) {
      if case .inactive? = $0[Self.database] { return true }
      return false
    }
    #expect(stopped != nil, "no snapshot reported the service stopped")
  }

  /// A tunnel dropping or a helper connecting changes a service's health without the
  /// registry doing anything, so the service has to be able to say so.
  @Test("A service reporting its own change publishes a snapshot")
  func reportedChangePublishes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    try await registry.startAll()

    // Subscribed after startup, so the only thing that can publish is the report.
    let changes = await registry.healthChanges()
    await registry.noteHealthChanged()
    let snapshot = await nextSnapshot(in: changes) { _ in true }
    #expect(snapshot?[Self.database] == .running)
  }

  @Test("A subscriber that stops listening is forgotten")
  func terminationUnsubscribes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    do {
      let changes = await registry.healthChanges()
      var iterator = changes.makeAsyncIterator()
      await registry.noteHealthChanged()
      _ = await iterator.next()
    }
    // Nothing observable from outside but the absence of a leak; publishing to a dropped
    // subscriber must at least not trap.
    await registry.noteHealthChanged()
  }
}

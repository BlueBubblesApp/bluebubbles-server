//  WaitingHealthTests
//  A service that is meant to run and has not yet says WHICH kind of not-yet, and one that is
//  switched off says so from the first snapshot.
//
//  Both used to be `.inactive`, told apart only by the words, so Home could say no more than
//  "14 switched off or waiting". The registry now reports `.waiting(on: .queued)` for a service
//  it has not reached, and marks switched-off ones before it starts anything, so a count of
//  what is still to come never includes a service that was never going to run.

import BBTestCore
import Foundation
import Testing

@testable import BBServiceKit

/// Started after `SlowService` (`"slow"` sorts first), so its health can be read while startup
/// is held on that one.
actor TunnelAfterSlow: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "tunnel") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

actor WatcherAfterSlow: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "watcher") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

@Suite("Waiting health", .serialized)
struct WaitingHealthTests {

  @Test("While startup is on another service, a switched-off one is off and the rest are queued")
  func offIsKnownAheadOfItsTurn() async throws {
    let recorder = LifecycleRecorder()
    let context = TestContext(recorder: recorder)
    let registry = ServiceRegistry(
      host: context, enablementCheck: { $0 != TunnelAfterSlow.id })
    await registry.register(SlowService.self)
    await registry.register(TunnelAfterSlow.self)
    await registry.register(WatcherAfterSlow.self)

    let starting = Task { try await registry.startAll() }
    try await waitUntil("the slow start begins") {
      await recorder.snapshot().contains("start-begin")
    }

    let health = await registry.health()
    #expect(health[SlowService.id] == .starting)
    #expect(health[TunnelAfterSlow.id] == .inactive(reason: "switched off"))
    #expect(health[WatcherAfterSlow.id] == .waiting(reason: "not started", on: .queued))

    await context.startGate.open()
    try await starting.value
    #expect(await registry.health()[WatcherAfterSlow.id] == .running)
    await registry.stopAll()
  }

  @Test("A stopped service reads as stopped, not as waiting for its turn")
  func stoppedIsNotQueued() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    try await registry.startAll()
    await registry.stopAll()
    #expect(
      await registry.health()[DatabaseService.id] == .inactive(reason: "not started"))
  }
}

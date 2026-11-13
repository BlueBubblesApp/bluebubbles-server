//  SlowHealthStartupTests
//  A `health` getter that does not answer cannot hold up startup.
//
//  The registry used to await a full health snapshot (every running service's getter, one
//  after another) around each service it started. One getter called `SMAppService`, which can
//  take tens of seconds per read on a slow Mac, so services whose `start()` each took
//  milliseconds came up over many minutes, the socket service among the last.
//  The getter here never answers until the test lets it, which is the limit of "slow": if
//  startup waits on it at all, startup does not finish.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBServiceKit

@Suite("A slow health getter does not hold up startup", .serialized)
struct SlowHealthStartupTests {

  @Test("Startup finishes while a running service's health getter is still waiting")
  func startupDoesNotWaitOnHealth() async throws {
    let recorder = LifecycleRecorder()
    let registry = ServiceRegistry(host: TestContext(recorder: recorder))
    // Registered first and sorted first, so every later start would have waited on it.
    await registry.register(StalledHealthService.self)
    await registry.register(QuickServiceOne.self)
    await registry.register(QuickServiceTwo.self)
    await registry.register(QuickServiceThree.self)
    // Without a subscriber nothing is published, which would make this pass for the wrong
    // reason: the app is always subscribed, so the test is too.
    let changes = await registry.healthChanges()

    let finished = Locked(false)
    let startup = Task {
      try await registry.startAll()
      finished.withLock { $0 = true }
    }

    // Polled rather than awaited, so a registry that does wait fails this assertion instead
    // of hanging the suite: the getter it would be waiting on answers only when told.
    let done = try await poll(.every(.milliseconds(20)), within: .seconds(10)) { _ in
      finished.withLock { $0 } ? true : nil
    }
    #expect(done == true, "startAll() waited on a health getter that had not answered")
    #expect(await StalledHealthService.reads.value >= 1, "the getter was never read at all")
    let started = await recorder.snapshot()
    for id in ["stalled", "quick-one", "quick-two", "quick-three"] {
      #expect(started.contains("start:\(id)"), "\(id) did not start")
    }

    // Once the getter answers, the snapshot that follows is the state after startup, not a
    // backlog of the transitions it missed.
    await StalledHealthService.gate.open()
    try await startup.value
    var snapshot: [ServiceIdentifier: ServiceHealth]?
    for await next in changes where next.values.allSatisfy({ $0 == .running }) {
      snapshot = next
      break
    }
    #expect(snapshot?.count == 4)
    await registry.stopAll()
  }
}

/// A running service whose `health` does not answer until the test opens its gate.
private actor StalledHealthService: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "stalled") }

  /// Shared, because the registry builds the instance and the test cannot reach it.
  static let gate = Gate()
  static let reads = Reads()

  actor Reads {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }

  var health: ServiceHealth {
    get async {
      await Self.reads.increment()
      await Self.gate.wait()
      return .running
    }
  }
}

private actor QuickServiceOne: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "quick-one") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

private actor QuickServiceTwo: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "quick-two") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

private actor QuickServiceThree: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "quick-three") }
  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }
}

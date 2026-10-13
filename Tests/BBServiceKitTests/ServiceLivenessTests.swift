//  ServiceLivenessTests
//  A service that stops on its own is noticed and restarted.
//
//  Supervision covered `start()` and nothing after it. Once `start()` returned cleanly a
//  service was "up" for the life of the process, however dead its own work became — so a pump
//  task whose stream ended, or that an error escaped, left the feature silently gone. The
//  change detector's pump was the worst case: it logged its own exit at `debug`, below the
//  default level, and `health` went on reporting `.running`. The symptom is "messages stopped
//  arriving" with nothing in a log bundle to find.
//
//  **Why `isAlive` and not `health`.** `health` is a diagnostic for a person to read:
//  `SocketService` is `.degraded` whenever no client is connected, `ProxyService` is
//  `.inactive` when a tunnel is switched off. Both are ordinary, and a supervisor acting on
//  them would restart a working server all day. No service's `health` has ever returned
//  `.failed`, so watching for that would watch for ever. `isAlive` answers the single question
//  a supervisor can act on, and is cheap enough to ask on a timer — which the last test here
//  is about.

import BBCore
import Foundation
import Testing

@testable import BBServiceKit

@Suite("Service liveness")
struct ServiceLivenessTests {

  private func registry(_ state: LivenessState) async -> ServiceRegistry<LivenessHost> {
    let registry = ServiceRegistry<LivenessHost>(host: LivenessHost(state: state))
    await registry.register(Flaky.self) { $0 }
    try? await registry.startAll()
    return registry
  }

  @Test("A service that stops on its own is restarted")
  func deadServiceIsRevived() async throws {
    let state = LivenessState()
    let registry = await registry(state)
    #expect(await state.starts == 1)

    await state.die()
    // Driven directly rather than waiting out the 60-second timer: the poll's SCHEDULE is a
    // constant asserted below, and a test that slept for it would be a minute long.
    await registry.checkLiveness()

    #expect(await state.starts == 2, "a dead service should have been restarted")
  }

  @Test("A live service is not restarted")
  func liveServiceIsLeftAlone() async throws {
    // The half that keeps the poll safe. `isAlive` defaults to true for every service with no
    // long-running work, so a poll that restarted on anything but a definite `false` would
    // churn the whole graph once a minute.
    let state = LivenessState()
    let registry = await registry(state)

    for _ in 0..<5 { await registry.checkLiveness() }

    #expect(await state.starts == 1, "a living service must not be restarted")
  }

  @Test("Reviving is bounded, so a service that will not stay up is not hammered")
  func revivalIsBounded() async throws {
    // Without this, a service that dies the moment it starts is restarted once a minute for
    // the life of the process — the crash loop `RestartPolicy` bounds at start time, except
    // that this path never goes through a `start()` that threw.
    let state = LivenessState()
    let registry = await registry(state)
    await state.die()

    for _ in 0..<(ServiceLiveness.maximumRevivals + 4) { await registry.checkLiveness() }

    #expect(await state.starts == 1 + ServiceLiveness.maximumRevivals)
  }

  @Test("A deliberate restart clears the budget")
  func deliberateRestartResetsTheBudget() async throws {
    // Somebody intervened, so whatever the poll had counted is no longer the current story.
    // The revival path deliberately does NOT reset, or the budget would refresh itself every
    // time it was spent and bound nothing.
    let state = LivenessState()
    let registry = await registry(state)
    await state.die()
    for _ in 0..<(ServiceLiveness.maximumRevivals + 2) { await registry.checkLiveness() }
    let spent = await state.starts

    await registry.restart(Flaky.id)
    for _ in 0..<(ServiceLiveness.maximumRevivals + 2) { await registry.checkLiveness() }

    // The explicit restart, plus a fresh budget's worth of revivals after it.
    #expect(await state.starts == spent + 1 + ServiceLiveness.maximumRevivals)
  }

  @Test("A service that comes back is left running")
  func recoveredServiceIsNotRestartedAgain() async throws {
    let state = LivenessState()
    let registry = await registry(state)

    await state.die()
    await registry.checkLiveness()
    await state.recover()
    let afterRevival = await state.starts

    for _ in 0..<5 { await registry.checkLiveness() }
    #expect(await state.starts == afterRevival)
  }

  // MARK: - What a tick costs

  @Test("A tick reads each service once and does nothing else")
  func tickCostIsOneReadPerService() async throws {
    // The budget, asserted rather than asserted-in-a-comment. This runs for the life of the
    // server, so the cost per tick is the design constraint: one actor hop per running
    // service, reading a `Task?` for nil. A tick that asked twice, or that fell back to
    // `health` (a database query in `WebhookDeliveryService`, an `SMAppService` call in
    // `LaunchAtLoginService`), would put real work on a permanent timer. This server has had
    // two such loops already and neither was noticed until an audit went looking.
    let state = LivenessState()
    let registry = await registry(state)
    let before = await state.aliveReads

    await registry.checkLiveness()

    #expect(await state.aliveReads == before + 1, "a tick must ask each service exactly once")
  }

  @Test("The poll interval is not hot")
  func intervalIsNotHot() {
    // A dead pump means messages have stopped arriving; the difference between hearing about
    // it in ten seconds and in sixty is not worth a sixfold cost on an idle Mac.
    #expect(ServiceLiveness.interval >= .seconds(30))
    #expect(ServiceLiveness.maximumRevivals >= 1)
  }

  @Test("Services with nothing long-running to watch cost nothing")
  func defaultIsAliveIsFree() async {
    // The default is what keeps the poll free across the eighteen registered services: only
    // the three that own a pump override it, and the rest answer from a protocol extension
    // with no stored state to read.
    #expect(await Plain(host: LivenessHost(state: LivenessState())).isAlive)
  }
}

/// What the services under test are built from. The state lives here because `Service`
/// requires `init(host:)` and nothing else, which is the same reason `FailingService` reaches
/// its recorder through `TestContext`.
private struct LivenessHost: Sendable {
  let state: LivenessState
}

/// The half both the test and the service can reach.
private actor LivenessState {
  private(set) var starts = 0
  private(set) var aliveReads = 0
  private var alive = true

  func recordStart() { starts += 1 }
  func die() { alive = false }
  func recover() { alive = true }

  var isAlive: Bool {
    aliveReads += 1
    return alive
  }
}

/// A service whose `isAlive` is driven by the test, counting starts as it goes.
private actor Flaky: Service {
  static var manifest: ServiceManifest { .minimal(id: "test.flaky") }
  static var restartPolicy: RestartPolicy { .never }
  private let state: LivenessState
  init(host: LivenessHost) { state = host.state }

  func start() async { await state.recordStart() }
  func stop() async {}
  var health: ServiceHealth { get async { .running } }
  var isAlive: Bool { get async { await state.isAlive } }
}

/// A service with no long-running work, which is most of them: it does not override
/// `isAlive`, so the poll reads a protocol-extension default and touches no state at all.
private actor Plain: Service {
  static var manifest: ServiceManifest { .minimal(id: "test.plain") }
  init(host: LivenessHost) {}
  func start() async {}
  func stop() async {}
  var health: ServiceHealth { get async { .running } }
}

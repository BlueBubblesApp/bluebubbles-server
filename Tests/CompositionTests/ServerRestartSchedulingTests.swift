//  ServerRestartSchedulingTests
//  A whole-server restart is serialised with the server's stop, and a request that joins a
//  pending restart is honoured rather than dropped.
//
//  Both restart routes answer 200 before the restart begins, so a client cannot tell a
//  restart that ran from one that was dropped. Two ways it went wrong: a `.process` request
//  arriving while a `.services` restart was pending joined it and was never performed, and a
//  restart already scheduled when the server stopped ran its `startAll` after the stop's
//  `stopAll`, bringing every service back on a stopped server.
//
//  The process replacement is faked throughout: the real one ends the process running it.

import BBBuiltIns
import BBHTTPAPI
import BBServiceKit
import BBTestSupport
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

/// What the service and the faked process replacement did, in order.
private actor RestartProbe {
  private(set) var log: [String] = []
  /// While closed, a start waits here, so a test can hold a restart part-way through.
  private var gate: CheckedContinuation<Void, Never>?
  private var holdsStarts = false

  func note(_ entry: String) { log.append(entry) }

  func holdNextStart() { holdsStarts = true }

  func enterStart() async {
    log.append("start")
    guard holdsStarts else { return }
    holdsStarts = false
    await withCheckedContinuation { gate = $0 }
  }

  var isHolding: Bool { gate != nil }

  func release() {
    gate?.resume()
    gate = nil
  }
}

private struct ProbeHost: Sendable {
  let probe: RestartProbe
}

private actor RecordedService: Service {
  static var manifest: ServiceManifest { .minimal(id: "test.recorded") }
  private let probe: RestartProbe
  init(host: ProbeHost) { probe = host.probe }

  func start() async { await probe.enterStart() }
  func stop() async { await probe.note("stop") }
  var health: ServiceHealth { get async { .running } }
}

@Suite("Server restart scheduling")
struct ServerRestartSchedulingTests {

  /// A lifecycle over a real registry holding one recorded service. The registry is returned
  /// because the lifecycle holds it unowned.
  private func lifecycle(
    _ probe: RestartProbe
  ) async throws -> (ServerLifecycle, ServiceRegistry<AppContext>) {
    let context = try await AppContextFixture.make()
    let registry = ServiceRegistry<AppContext>(host: context)
    await registry.register(RecordedService.self) { _ in ProbeHost(probe: probe) }
    let lifecycle = ServerLifecycle(
      registry: registry,
      events: context.events,
      pushDelivery: { nil },
      logger: Logger(label: "bluebubbles.test"),
      processReplacement: { await probe.note("process") }
    )
    return (lifecycle, registry)
  }

  @Test("A process restart asked for behind a pending services restart replaces it")
  func processUpgradesAPendingServicesRestart() async throws {
    let probe = RestartProbe()
    let (lifecycle, registry) = try await lifecycle(probe)

    await lifecycle.schedule(.services, after: .milliseconds(100))
    await lifecycle.schedule(.process, after: .zero)

    try await waitUntil("the process restart") { await probe.log.contains("process") }
    // Upgraded before it began, so the services restart never ran on its own: the process
    // restart stops every service itself.
    #expect(await probe.log == ["process"])
    await lifecycle.stop()
    withExtendedLifetime(registry) {}
  }

  @Test("A process restart asked for during a services restart runs after it")
  func processRunsAfterAServicesRestartInFlight() async throws {
    let probe = RestartProbe()
    let (lifecycle, registry) = try await lifecycle(probe)
    await probe.holdNextStart()

    await lifecycle.schedule(.services, after: .zero)
    try await waitUntil("the services restart part-way") { await probe.isHolding }
    await lifecycle.schedule(.process, after: .zero)
    await probe.release()

    try await waitUntil("the process restart") { await probe.log.contains("process") }
    #expect(await probe.log == ["start", "process"])
    await lifecycle.stop()
    withExtendedLifetime(registry) {}
  }

  @Test("Stopping cancels a restart still waiting, and refuses one asked for after")
  func stopCancelsAWaitingRestart() async throws {
    let probe = RestartProbe()
    let (lifecycle, registry) = try await lifecycle(probe)

    await lifecycle.schedule(.services, after: .milliseconds(50))
    await lifecycle.stop()
    await lifecycle.schedule(.services, after: .zero)

    // Past the cancelled restart's delay, so it would have run by now.
    try await Task.sleep(for: .milliseconds(150))
    #expect(await probe.log.isEmpty)
    withExtendedLifetime(registry) {}
  }

  @Test("Stopping waits for a restart already running, so its start cannot land after")
  func stopWaitsForARestartInFlight() async throws {
    let probe = RestartProbe()
    let (lifecycle, registry) = try await lifecycle(probe)
    await probe.holdNextStart()

    await lifecycle.schedule(.services, after: .zero)
    try await waitUntil("the services restart part-way") { await probe.isHolding }

    async let stopped: Void = lifecycle.stop()
    await probe.release()
    await stopped
    // The stop the server performs next, after the lifecycle's.
    await registry.stopAll()

    #expect(await probe.log == ["start", "stop"])
  }

  @Test("The running server stops the lifecycle before it stops the services")
  func runningServerStopsTheLifecycleFirst() throws {
    let file = try SourceScanner.file(
      "Sources/BlueBubblesServerCore/Composition/ServerComposition+RunningServer.swift")
    let code = file.code
    guard let stop = code.range(of: "public func stop() async {") else {
      Issue.record("RunningServer.stop() was not found")
      return
    }
    let body = code[stop.upperBound...]
    let lifecycle = body.range(of: "lifecycle?.stop()")
    let services = body.range(of: "registry.stopAll()")
    #expect(lifecycle != nil, "RunningServer.stop() never stops the lifecycle")
    if let lifecycle, let services {
      #expect(lifecycle.lowerBound < services.lowerBound)
    }
  }
}

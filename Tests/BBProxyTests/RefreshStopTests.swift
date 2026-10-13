//  RefreshStopTests
//  A scheduled tunnel restart that is waiting for the server to go idle, then stopped.
//
//  The wait slept with `try?`, and a cancelled sleep returns at once, so a stopped
//  coordinator spun through the rest of a ten-minute wait as fast as the actor allowed. And
//  when the wait ended, the restart reconnected the provider it had captured before the
//  stop: an ngrok nothing owned, after the person had switched to another method.

import BBCore
import BBServiceKit
import Foundation
import Testing

@testable import BBProxy

private actor CountingProvider: ProxyProviding {
  nonisolated let identifier = ServiceIdentifier("app.bluebubbles.proxy.test")
  nonisolated var requiresRefresh: Bool { true }
  private(set) var connects = 0
  private(set) var currentAddress: String?

  func connect() async throws -> String {
    connects += 1
    currentAddress = "https://example.invalid"
    return "https://example.invalid"
  }

  func disconnect() async { currentAddress = nil }
}

@Suite("A tunnel restart that is stopped while it waits")
struct RefreshStopTests {

  @Test("Stopping ends the wait and the restart never reconnects")
  func stopDuringIdleWait() async throws {
    // Never idle: a connection a moment ago, every time it is asked.
    let asked = Locked(0)
    let coordinator = ProxyCoordinator(
      policy: RefreshPolicy(
        interval: .milliseconds(10), idleThreshold: .seconds(3600),
        maximumWait: .seconds(600), pollInterval: .milliseconds(20)),
      lastConnectionAt: {
        asked.withLock { $0 += 1 }
        return Date()
      }
    )
    let provider = CountingProvider()
    try await coordinator.start(provider)

    // The scheduled restart is waiting for idle.
    let waiting = try await poll(.every(.milliseconds(5)), within: .seconds(5)) { _ in
      asked.value > 0 ? true : nil
    }
    #expect(waiting == true, "the restart never started waiting")

    await coordinator.stop()
    let atStop = asked.value
    try await Task.sleep(for: .milliseconds(200))

    // At most the one look that was already in flight, not one per actor hop.
    #expect(asked.value - atStop <= 1, "the wait went on after the stop")
    #expect(await provider.connects == 1, "a stopped coordinator reconnected its old tunnel")
  }
}

//  ShutdownTargetTests
//  A quit that arrives while the server is starting waits for the start and stops what came up.
//
//  The quit decided from `AppModel.server`, which is nil until every service is up, so a quit
//  during a start answered `.terminateNow` and left the tunnels and daemons already started
//  running. `ShutdownTarget` is what the quit asks instead; these pin what it answers at each
//  point of a start. The delegate itself is AppKit and cannot run here, so the last test holds
//  it to asking the target.

import BBCore
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Shutdown target")
struct ShutdownTargetTests {

  private struct Refused: Error {}

  /// A start that holds until the test lets it go, and says when it has begun.
  private struct HeldStart: Sendable {
    let begun = Locked(false)
    let release = AsyncStream<Void>.makeStream()

    func run() async {
      begun.withLock { $0 = true }
      for await _ in release.stream { return }
    }
  }

  @Test("With nothing started there is nothing to stop, and no wait")
  func nothingStarted() async {
    let target = ShutdownTarget<String>()
    #expect(!target.isHolding)
    #expect(await target.settled() == nil)
  }

  @Test("A quit during a start is told there is something to stop, and waits for the start")
  func quitDuringAStartWaits() async throws {
    let target = ShutdownTarget<String>()
    let held = HeldStart()
    let starting = Task { try await target.start("server") { _ in await held.run() } }
    try await waitUntil("the start to begin") { held.begun.value }

    // What `applicationShouldTerminate` asks, mid-start, where `model.server` is still nil.
    #expect(target.isHolding)
    #expect(target.current == "server")

    let settled = Locked<String??>(nil)
    let quitting = Task {
      let server = await target.settled()
      settled.withLock { $0 = .some(server) }
    }
    // Not answered while the start is still running: stopping it now would race the services
    // coming up.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(settled.value == nil)

    held.release.continuation.yield()
    try await starting.value
    await quitting.value
    #expect(settled.value == .some("server"))
    #expect(target.isHolding)
  }

  @Test("A start that fails leaves nothing to stop, and its error reaches the caller")
  func failedStartLeavesNothing() async {
    let target = ShutdownTarget<String>()
    await #expect(throws: Refused.self) {
      try await target.start("server") { _ in throw Refused() }
    }
    #expect(!target.isHolding)
    #expect(await target.settled() == nil)
  }

  @Test("A server the app has stopped itself is released")
  func releaseForgets() async throws {
    let target = ShutdownTarget<String>()
    try await target.start("server") { _ in }
    #expect(await target.settled() == "server")
    target.release()
    #expect(!target.isHolding)
  }

  @Test("The quit decides from the shutdown target, never from the model's server")
  func delegateAsksTheTarget() throws {
    let source = try SourceScanner.file("Sources/BlueBubblesApp/BlueBubblesApp.swift").code
    #expect(!source.contains("model.server"))
    #expect(source.contains("model.shutdownTarget"))
  }
}

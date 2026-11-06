//  ServerLifecycleTests
//  The two lists that undo a start: what was attached, and what is being followed.
//
//  Neither can be exercised through `AppModel.start` in a test process, which opens two
//  databases and binds a port. Both are types of their own for that reason, and these pin
//  the properties `AppModel` relies on: every attach is undone, in reverse, exactly once;
//  stopping the follows clears what they held while cancelling one keeps it; and a stop waits
//  for a follow suspended mid-write, so nothing it read lands after the reset.
//
//  `FrontEndPlumbingPolicyTests` holds the other half: that `AppModel` attaches every child
//  through the list and detaches none by hand.

import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Server lifecycle")
@MainActor
struct ServerLifecycleTests {

  /// A child that records when it was detached.
  private final class Child: ServerAttachable {
    let name: String
    let log: Log
    init(_ name: String, log: Log) {
      self.name = name
      self.log = log
    }
    func detach() async { log.events.append(name) }
  }

  private final class Log {
    var events: [String] = []
  }

  private struct Refused: Error {}

  @Test("Detaching undoes every attach, the most recent first, and only once")
  func detachesInReverseOnce() async {
    let log = Log()
    let attachments = ServerAttachments()
    await attachments.attach(Child("storage", log: log)) { _ in }
    attachments.onDetach("server") { log.events.append("server") }
    await attachments.attach(Child("alerts", log: log)) { _ in }

    await attachments.detachAll()
    #expect(log.events == ["alerts", "server", "storage"])
    #expect(attachments.names.isEmpty)

    // A second teardown (a stop after a failed start, say) finds nothing to repeat.
    await attachments.detachAll()
    #expect(log.events == ["alerts", "server", "storage"])
  }

  @Test("A child whose attach threw is not detached; everything before it is")
  func failedAttachIsNotRecorded() async {
    let log = Log()
    let attachments = ServerAttachments()
    await attachments.attach(Child("storage", log: log)) { _ in }
    await #expect(throws: Refused.self) {
      try await attachments.attach(Child("broken", log: log)) { _ in throw Refused() }
    }

    await attachments.detachAll()
    #expect(log.events == ["storage"])
  }

  @Test("Stopping the follows clears what they held; cancelling one keeps it")
  func stopClearsCancelKeeps() async {
    let table = FollowTable()
    var cleared: [ServerFollow] = []
    let clearRuntime: @MainActor () -> Void = { cleared.append(.privateAPIRuntime) }
    let clearAccess: @MainActor () -> Void = { cleared.append(.accessControl) }
    table.start(.privateAPIRuntime, reset: clearRuntime) {}
    table.start(.accessControl, reset: clearAccess) {}

    // The runtime follow is cancelled whenever it is pointed at another runtime, and what it
    // held is kept until the next one replaces it.
    await table.cancel(.privateAPIRuntime)
    #expect(cleared.isEmpty)
    #expect(table.following == [.accessControl])

    await table.stopAll()
    #expect(Set(cleared) == [.privateAPIRuntime, .accessControl])
    #expect(table.following.isEmpty)
  }

  @Test("Starting a follow again replaces it, and keeps its reset unless given another")
  func restartReplaces() async throws {
    let table = FollowTable()
    let log = Log()
    var cleared = 0
    let reset: @MainActor () -> Void = { cleared += 1 }
    table.start(.tools, reset: reset) {
      log.events.append("first")
      try? await Task.sleep(for: .seconds(60))
      log.events.append(Task.isCancelled ? "first cancelled" : "first ran out")
    }
    try await waitUntil("the first follow to be running") { log.events == ["first"] }
    table.start(.tools, reset: nil) { log.events.append("second") }

    try await waitUntil("the second follow to have run") { log.events.count == 3 }
    #expect(log.events == ["first", "first cancelled", "second"])
    await table.stopAll()
    #expect(cleared == 1)
  }

  // MARK: - A stop waits for what it stops

  /// Somewhere for a follow's body to park, standing for a seed read that does not notice
  /// cancellation: an actor call into the server returns whether or not the caller has been
  /// cancelled, and the follow writes what it read on the next line.
  @MainActor
  private final class Parking {
    private var parked: CheckedContinuation<Void, Never>?
    var isParked: Bool { parked != nil }
    func park() async { await withCheckedContinuation { parked = $0 } }
    func release() {
      parked?.resume()
      parked = nil
    }
  }

  @Test("Stopping waits for a follow suspended in its seed, so its write lands before the reset")
  func stopWaitsForASuspendedSeed() async throws {
    let table = FollowTable()
    let seed = Parking()
    var shown = "nothing"
    let reset: @MainActor () -> Void = { shown = "nothing" }
    table.start(.accessControl, reset: reset) {
      await seed.park()
      shown = "a stopped server's state"
    }
    try await waitUntil("the follow to reach its seed") { seed.isParked }

    let stopping = Task { await table.stopAll() }
    try await waitUntil("the stop to cancel the follow") { table.following.isEmpty }
    seed.release()
    await stopping.value

    #expect(shown == "nothing")
  }

  @Test("A follow started by one that is stopping is stopped too, and its reset runs")
  func stopCatchesAFollowStartedOnTheWayOut() async throws {
    let table = FollowTable()
    let seed = Parking()
    var cleared: [ServerFollow] = []
    // The health follow's seed re-points the Private API follow, which is this shape.
    table.start(.serviceHealth, reset: nil) {
      await seed.park()
      let reset: @MainActor () -> Void = { cleared.append(.privateAPIRuntime) }
      table.start(.privateAPIRuntime, reset: reset) {
        try? await Task.sleep(for: .seconds(60))
      }
    }
    try await waitUntil("the follow to reach its seed") { seed.isParked }

    let stopping = Task { await table.stopAll() }
    try await waitUntil("the stop to cancel the follow") { table.following.isEmpty }
    seed.release()
    await stopping.value

    #expect(table.following.isEmpty)
    #expect(cleared == [.privateAPIRuntime])
  }

  @Test("A replacement starts only once the follow it replaces has made its last write")
  func replacementWaitsForTheReplaced() async throws {
    let table = FollowTable()
    let seed = Parking()
    let log = Log()
    table.start(.privateAPIRuntime, reset: nil) {
      await seed.park()
      log.events.append("old runtime")
    }
    try await waitUntil("the follow to reach its seed") { seed.isParked }
    table.start(.privateAPIRuntime, reset: nil) { log.events.append("new runtime") }
    seed.release()

    try await waitUntil("both follows to have written") { log.events.count == 2 }
    #expect(log.events == ["old runtime", "new runtime"])
    await table.stopAll()
  }

  @Test("A model with no server follows nothing and stopping it is harmless")
  func stoppingAnIdleModel() async {
    let model = AppModel()
    #expect(model.follows.following.isEmpty)
    #expect(model.attachments.names.isEmpty)
    await model.stopFollowingServer()
    await model.stop()
    #expect(model.phase == .idle)
  }
}

//  ShutdownTarget
//  The composition a quit has to stop, reachable without the main actor.
//
//  A quit answers `.terminateLater` and stops the server from a DETACHED task, because the
//  nested run loop AppKit spins while it waits does not drain the main queue (see
//  `AppDelegate.applicationShouldTerminate`). So nothing the quit needs may be main-actor
//  state, and `AppModel.server` is main-actor state that is nil until every service is up. A
//  quit deciding from it during a start finds nothing to stop, answers `.terminateNow`, and
//  leaves every tunnel and daemon the start has already spawned running, parented to launchd.
//
//  So the composition is recorded HERE the moment its services begin to start, and the start
//  runs on a task the quit can wait for from any thread. A quit that arrives mid-start waits
//  for the start to settle, inside its own deadline, and then stops what came up in order.
//  A start that fails has already unwound itself (`RunningServer.start`), so it leaves
//  nothing here for a quit to stop twice.
//
//  Generic over the server so a test can drive it without assembling one.

import BBCore

final class ShutdownTarget<Server: Sendable>: Sendable {

  private struct State: Sendable {
    var server: Server?
    /// What the last start threw, held only until `start` rethrows it.
    var failure: (any Error)?
  }

  private let state = Locked(State())
  private let starting = OwnedTask()

  init() {}

  /// The composition, without waiting for a start in flight: what the daemon sweep after a
  /// quit's deadline reaches.
  var current: Server? { state.value.server }

  /// Whether a quit has anything to wait for or to stop: a start in flight, or a composition
  /// that came up. The task is asked first, because the body records the composition and a
  /// failed start forgets it before the task reports that it has ended.
  var isHolding: Bool { starting.isRunning || current != nil }

  /// Runs `start` on `server`, on a task a quit can wait for without the main actor, and
  /// records `server` as that task's first step. Returns or throws when `start` does.
  ///
  /// Recorded INSIDE the task, not before it is started: this function does not run on the
  /// main actor, so a quit can arrive between any two of its lines, and a composition
  /// recorded with no task yet to wait on would be stopped while its start was beginning.
  func start(
    _ server: Server, with start: @escaping @Sendable (Server) async throws -> Void
  ) async throws {
    let state = self.state
    starting.run {
      state.withLock { $0 = State(server: server) }
      do {
        try await start(server)
      } catch {
        // Forgotten before the body returns, so a quit waiting on this start finds nothing
        // to stop: the start unwound what it had brought up before it threw.
        state.withLock { $0 = State(failure: error) }
      }
    }
    await starting.wait()
    let failure = state.withLock { state in
      defer { state.failure = nil }
      return state.failure
    }
    if let failure { throw failure }
  }

  /// Waits for a start in flight to settle, then answers what there is to stop: the
  /// composition if it came up, nil if it failed or there never was one.
  func settled() async -> Server? {
    await starting.wait()
    return current
  }

  /// Forgets the composition once the app has stopped it itself.
  func release() {
    state.withLock { $0 = State() }
  }
}

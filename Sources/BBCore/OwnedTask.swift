//  OwnedTask
//  One long-running task with an owner: replaced on restart, cancelled on stop and on the
//  owner's release, and able to say whether its body is still running.
//
//  A bare `Task?` cannot be asked whether its body has returned. A loop held that way that
//  ends on its own (its stream finished, or an error escaped it) leaves the handle set, so a
//  service's `isAlive`, which the registry's liveness poll reads, answers true for a feature
//  that is dead, and nothing revives it. This type clears its own handle when the body
//  returns, so `isRunning` is right by construction rather than by each owner remembering to
//  clear it on the way out.
//
//  It also owns the two lines every holder of a `Task?` wrote at each assignment: the cancel
//  before a replacement (two pumps on one stream deliver every event twice) and the stop.
//  `stop()` cancels AND waits, and it is the short name on purpose: an owner whose stop only
//  cancels returns while the old body is still running, so a restart puts the next instance
//  beside it (a scheduled message read by the old sweep was sent after its cancel). `cancel()`
//  is for a synchronous caller, or one that is itself called from the body it would wait for.
//  `OwnedTaskPolicyTests` refuses a bare stored `Task` anywhere under `Sources/` or `Helper/`,
//  and a service `stop()` that cancels without waiting.
//
//  A class behind a lock rather than an actor: `isRunning` is a synchronous read, so the
//  liveness poll stays one hop to the service and nothing more, and the body clears the handle
//  without hopping back to its owner.

public final class OwnedTask: Sendable {

  private struct State {
    var task: Task<Void, Never>?
    /// Bumped on every start and every cancel, so a body that finishes after it was replaced
    /// or cancelled cannot clear its successor's handle, and is not reported as having ended
    /// on its own.
    var generation: UInt64 = 0
  }

  private let state = Locked(State())

  public init() {}

  /// Released with its owner, the task goes with it: a task nothing can reach any more can
  /// never be cancelled by anyone else.
  deinit {
    state.withLock { $0.task?.cancel() }
  }

  /// Whether a body started here is still running. False before the first `run`, after a
  /// `cancel`, and once the body has returned on its own.
  public var isRunning: Bool {
    state.withLock { $0.task != nil }
  }

  /// Cancels whatever is running and starts `operation` in its place.
  ///
  /// `ended` runs only when `operation` returns WITHOUT its owner having cancelled or replaced
  /// it: the case that leaves a feature silently dead, and the one worth a warning. A
  /// deliberate stop reaches nothing.
  ///
  /// The body does not inherit the caller's actor. An owner that needs its own state reaches
  /// it with `await`, through a `[weak self]` capture so the task does not keep it alive.
  public func run(
    _ operation: @escaping @Sendable () async -> Void,
    ifItEndsOnItsOwn ended: (@Sendable () async -> Void)? = nil
  ) {
    // Created inside the lock, so a body that returns at once cannot clear the handle before
    // it has been stored: its `finish` waits for this critical section to end.
    state.withLock { state in
      state.task?.cancel()
      state.generation &+= 1
      let generation = state.generation
      state.task = Task { [weak self] in
        await operation()
        guard let self, self.finish(generation) else { return }
        await ended?()
      }
    }
  }

  /// Runs `work` every `interval` until cancelled: `runPeriodically` as an owned task.
  public func runPeriodically(
    every interval: Duration,
    after initialDelay: Duration = .zero,
    _ work: @escaping @Sendable () async -> Void
  ) {
    run {
      await BBCore.runPeriodically(every: interval, after: initialDelay, work)
    }
  }

  /// Waits for the running body, if any, to return, without cancelling it.
  public func wait() async {
    let task = state.withLock { $0.task }
    await task?.value
  }

  /// Cancels the running body, if any, without waiting for it to return.
  ///
  /// For a synchronous caller, or a replacement made from inside the body itself, which
  /// would wait for ever on its own return. Anywhere else, `stop()`.
  public func cancel() {
    state.withLock { state in
      state.task?.cancel()
      state.task = nil
      state.generation &+= 1
    }
  }

  /// Cancels the running body and waits for it to return, so the owner's stop lands after the
  /// body's last write and a restart never runs the next body beside this one.
  public func stop() async {
    let task = state.withLock { state in
      let task = state.task
      task?.cancel()
      state.task = nil
      state.generation &+= 1
      return task
    }
    await task?.value
  }

  /// Clears the handle if it still belongs to `generation`. True when it did: the body ended
  /// on its own rather than being cancelled or replaced.
  private func finish(_ generation: UInt64) -> Bool {
    state.withLock { state in
      guard state.generation == generation else { return false }
      state.task = nil
      return true
    }
  }
}

/// Runs `work`, then sleeps `interval`, until the calling task is cancelled.
///
/// The first run waits `initialDelay`; zero runs at once, which is what a sweep that must
/// catch up on what happened while the server was down wants. It returns only on
/// cancellation, at a sleep or before the next run, never part-way through `work`.
///
/// The clock is a parameter so a test can drive the schedule instead of waiting it out.
public func runPeriodically<C: Clock>(
  every interval: C.Duration,
  after initialDelay: C.Duration,
  clock: C = ContinuousClock(),
  _ work: () async -> Void
) async {
  if initialDelay > .zero {
    do { try await clock.sleep(for: initialDelay) } catch { return }
  }
  while !Task.isCancelled {
    await work()
    do { try await clock.sleep(for: interval) } catch { return }
  }
}

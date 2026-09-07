//  LauncherPolicy
//  What the launcher should do when the application it supervises stops.
//
//  Separated from the launcher's AppKit glue because it is the only part with a decision in
//  it, and because the alternative way to test it is to kill a real server on a real Mac and
//  watch what happens. It takes the intent, the recent history and the clock, and returns one
//  of three answers; the launcher supplies the world and performs the result.
//
//  **The crash-loop budget is the reason this is not a one-line `if`.** A supervisor with no
//  give-up condition turns a crash-on-launch bug into an unbounded spawn loop — worse than the
//  fault it is covering, because it burns a core, floods the log, and buries the original crash
//  under thousands of identical restarts. It has to stop, and it has to stop somewhere a person
//  would still call it "tried a few times" rather than "gave up immediately".

import Foundation

public enum LauncherPolicy {

  public enum Decision: Sendable, Equatable {
    /// Start it again now.
    case relaunch
    /// The user quit. Stop watching until the next login.
    case standDown
    /// It keeps dying. Stop watching, and say so.
    case giveUp
  }

  /// Relaunches allowed inside `crashLoopWindow` before the launcher stops trying.
  ///
  /// Three and sixty seconds: enough to ride out a transient failure — a port still held by
  /// the process that just exited, a database mid-checkpoint — and few enough that a genuine
  /// crash-on-launch is abandoned in seconds rather than spinning.
  public static let relaunchLimit = 3
  public static let crashLoopWindow: TimeInterval = 60

  /// - Parameters:
  ///   - intent: why the application stopped, as it recorded before exiting.
  ///   - recentRelaunches: when the launcher last restarted it after an UNEXPECTED stop. A
  ///     deliberate restart is not counted — restarting on request, repeatedly, is the feature
  ///     working, and letting it consume the crash budget would make a user who restarts three
  ///     times in a minute lose supervision for the rest of the session.
  ///   - now: injected so the window is testable without sleeping.
  /// - Returns: what to do, and the history to carry forward.
  public static func decide(
    intent: LauncherContract.Intent,
    recentRelaunches: [Date],
    now: Date = Date()
  ) -> (decision: Decision, recentRelaunches: [Date]) {
    switch intent {
    case .quit:
      return (.standDown, recentRelaunches)

    case .restart:
      return (.relaunch, recentRelaunches)

    case .supervise:
      let recent = recentRelaunches.filter { now.timeIntervalSince($0) < crashLoopWindow }
      guard recent.count < relaunchLimit else { return (.giveUp, recent) }
      return (.relaunch, recent + [now])
    }
  }
}

/// Turns "is it running now?" into "has it just stopped?".
///
/// Trivial-looking, and it hid two distinct bugs.
///
/// **The first was losing the edge.** The launcher folded this into a `defer` that wrote the
/// fresh observation back over the expectation. After a relaunch that stored `false` — the app
/// had not started yet when it was sampled — so the running → stopped transition could never
/// occur again. The launcher restarted the server exactly once per login and then sat there,
/// alive, watching nothing, with nothing to indicate it had stopped working.
///
/// **The second is why a boolean cannot do this job at all.** Immediately after a launch, "not
/// running" is ambiguous: the app may be starting, or it may have died on launch. Treat it as
/// starting and a genuine crash-on-launch is never noticed — the budget is never spent and
/// `giveUp` is unreachable. Treat it as a death and a slow cold start is relaunched over and
/// over until the launcher gives up on an application that was working.
///
/// So starting is its own state with a bounded patience. The app gets `startGracePolls` to
/// appear; if it has not by then, the launch failed and that is a stop.
public struct RunStateTracker: Sendable, Equatable {

  /// How many polls an application gets to appear after being launched.
  ///
  /// Eight polls is about sixteen seconds at the launcher's interval — comfortably longer than
  /// a cold start of a SwiftUI app on a slow disk, and short enough that a crash-on-launch is
  /// abandoned while somebody might still be watching.
  public static let startGracePolls = 8

  private enum State: Sendable, Equatable {
    /// Nothing expected. A stop here has already been reported.
    case idle
    /// Launched, waiting for it to appear.
    case starting(pollsRemaining: Int)
    /// Seen running.
    case running
  }

  private var state: State

  public init(expectsRunning: Bool = false) {
    state = expectsRunning ? .running : .idle
  }

  /// Records an observation and reports whether the application has just stopped.
  ///
  /// True exactly once per stop, so a caller can act without acting again on every poll while
  /// it stays down. A launch that never appears counts as a stop, once its grace has run out.
  public mutating func observe(isRunning: Bool) -> Bool {
    switch (state, isRunning) {
    case (_, true):
      state = .running
      return false

    case (.running, false):
      state = .idle
      return true

    case (.starting(let remaining), false):
      guard remaining <= 1 else {
        state = .starting(pollsRemaining: remaining - 1)
        return false
      }
      // Patience exhausted: it was launched and never arrived.
      state = .idle
      return true

    case (.idle, false):
      return false
    }
  }

  /// The application has just been launched.
  ///
  /// Called instead of trusting the next poll, which is the whole point: a launch that has not
  /// finished starting reads as "not running", and letting that overwrite the expectation is
  /// what broke the edge.
  public mutating func expectRunning() {
    state = .starting(pollsRemaining: Self.startGracePolls)
  }
}

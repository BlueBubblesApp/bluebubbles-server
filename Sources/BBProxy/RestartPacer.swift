//  RestartPacer
//  How often a supervised daemon that keeps dying is tried again.
//
//  Spending the restart budget slows the retry down; it never ends it. Successive attempts
//  are about a minute apart (the restart delay plus the readiness wait) and the window that
//  resets the count is five, so during any sustained outage the budget never resets and the
//  ten fast tries are gone in about eleven minutes. A tunnel that stopped there would stay
//  dead for the rest of the process, with the network back, nothing trying, and
//  `server_address` naming a URL that resolves to nothing, on a server whose premise is
//  running unattended.
//
//  One type rather than a loop in each tunnel, because the copies drift: `BinaryTunnel`
//  dropped to the slow phase and `TailscaleTunnel` gave up for good, under the same budget.

import Foundation
import Logging

/// Paces one incident of restarts: `restartDelay` while the daemon's budget lasts, then
/// `dormantRestartDelay` for as long as the caller keeps asking.
struct RestartPacer {

  /// The wait before one attempt.
  struct Attempt: Equatable {
    let delay: Duration
    /// True for exactly one attempt per incident: the first one after the fast budget ran
    /// out, which is when the person is told. Not once per attempt, for ever.
    let becameDormant: Bool
  }

  private let restartDelay: Duration
  private let dormantRestartDelay: Duration
  private(set) var isDormant = false

  init(_ configuration: DaemonConfiguration) {
    self.restartDelay = configuration.restartDelay
    self.dormantRestartDelay = configuration.dormantRestartDelay
  }

  /// The next attempt, spending one slot of `daemon`'s budget while there is one.
  ///
  /// `shouldRestart()` is not consulted once dormant. It is not a question: it MUTATES the
  /// budget (it counts the attempt and moves the last-exit timestamp), so calling it every
  /// five minutes for ever would keep the window sliding and the count climbing for no reader.
  mutating func nextAttempt(of daemon: DaemonProcess) async -> Attempt {
    if isDormant { return Attempt(delay: dormantRestartDelay, becameDormant: false) }
    if await daemon.shouldRestart() { return Attempt(delay: restartDelay, becameDormant: false) }
    isDormant = true
    return Attempt(delay: dormantRestartDelay, becameDormant: true)
  }
}

extension RestartPacer {

  /// Waits out the next attempt's delay, first telling the person once, at the attempt that
  /// spent the fast budget, that the tunnel is now being retried slowly.
  ///
  /// - Returns: False when the task was cancelled during the wait: stop, do not attempt.
  mutating func waitForNextAttempt(
    of daemon: DaemonProcess,
    kind: String,
    dormantReason: String,
    observer: ProxyObserver?,
    logger: Logger
  ) async -> Bool {
    let attempt = await nextAttempt(of: daemon)
    if attempt.becameDormant {
      logger.error(
        "The tunnel has exhausted its fast retry budget; slowing down",
        metadata: [
          "kind": .string(kind),
          "interval": .stringConvertible(attempt.delay),
        ])
      await observer?.failed(dormantReason)
    }
    do { try await Task.sleep(for: attempt.delay) } catch { return false }
    return !Task.isCancelled
  }
}

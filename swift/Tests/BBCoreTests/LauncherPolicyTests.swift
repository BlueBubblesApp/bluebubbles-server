//  LauncherPolicyTests
//  The supervisor's judgement, tested without killing anything.
//
//  Two properties matter more than the rest and are easy to get backwards:
//
//    - A DELIBERATE restart must not spend the crash budget. Someone who restarts the server
//      three times in a minute — which is an ordinary thing to do while configuring one —
//      would otherwise lose supervision for the rest of the login session, silently.
//    - Giving up has to be reachable. A supervisor with no give-up condition turns a
//      crash-on-launch into an unbounded spawn loop that buries the original crash.

import Foundation
import Testing

@testable import BBCore

@Suite("Launcher policy")
struct LauncherPolicyTests {

  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("An unexpected stop is restarted")
  func unexpectedStopRestarts() {
    let outcome = LauncherPolicy.decide(intent: .supervise, recentRelaunches: [], now: now)
    #expect(outcome.decision == .relaunch)
    #expect(outcome.recentRelaunches == [now], "the attempt is recorded against the budget")
  }

  @Test("A deliberate quit stands down")
  func quitStandsDown() {
    #expect(
      LauncherPolicy.decide(intent: .quit, recentRelaunches: [], now: now).decision == .standDown)
  }

  @Test("A requested restart relaunches")
  func restartRelaunches() {
    #expect(
      LauncherPolicy.decide(intent: .restart, recentRelaunches: [], now: now).decision
        == .relaunch)
  }

  /// The budget is spent by crashes, not by the user.
  @Test("A requested restart never spends the crash budget")
  func restartDoesNotSpendTheBudget() {
    var history: [Date] = []
    for offset in 0..<10 {
      let outcome = LauncherPolicy.decide(
        intent: .restart, recentRelaunches: history,
        now: now.addingTimeInterval(Double(offset)))
      #expect(outcome.decision == .relaunch, "restart \(offset) was refused")
      history = outcome.recentRelaunches
    }
    #expect(history.isEmpty)
  }

  @Test("Repeated crashes stop being restarted")
  func crashLoopGivesUp() {
    var history: [Date] = []
    for attempt in 0..<LauncherPolicy.relaunchLimit {
      let outcome = LauncherPolicy.decide(
        intent: .supervise, recentRelaunches: history,
        now: now.addingTimeInterval(Double(attempt)))
      #expect(outcome.decision == .relaunch, "attempt \(attempt) should still be allowed")
      history = outcome.recentRelaunches
    }

    let final = LauncherPolicy.decide(
      intent: .supervise, recentRelaunches: history,
      now: now.addingTimeInterval(Double(LauncherPolicy.relaunchLimit)))
    #expect(final.decision == .giveUp)
  }

  /// A server that has run happily for hours and then crashes once is not a crash loop, and
  /// must not inherit a budget spent when it was last unhealthy.
  @Test("The budget only counts what is inside the window")
  func historyOutsideTheWindowIsForgotten() {
    let old = (0..<LauncherPolicy.relaunchLimit).map {
      now.addingTimeInterval(-LauncherPolicy.crashLoopWindow - Double($0) - 1)
    }
    let outcome = LauncherPolicy.decide(intent: .supervise, recentRelaunches: old, now: now)
    #expect(outcome.decision == .relaunch)
    #expect(outcome.recentRelaunches == [now], "stale attempts are dropped, not carried")
  }

  /// Exactly at the boundary the entry is already outside the window — `<`, not `<=`. Pinned
  /// because an off-by-one here is the difference between giving up on the third crash and
  /// never giving up at all.
  @Test("An attempt exactly one window old no longer counts")
  func theWindowBoundaryIsExclusive() {
    let boundary = (0..<LauncherPolicy.relaunchLimit).map {
      now.addingTimeInterval(-LauncherPolicy.crashLoopWindow - Double($0))
    }
    #expect(
      LauncherPolicy.decide(intent: .supervise, recentRelaunches: boundary, now: now).decision
        == .relaunch)
  }
}

/// The edge detector, which was wrong in a way that made the launcher supervise exactly once
/// per login and then sit there watching nothing. Every test here would have failed against it.
@Suite("Launcher run-state tracking")
struct RunStateTrackerTests {

  @Test("A stop is reported once, not on every poll while it stays down")
  func stopIsReportedOnce() {
    var tracker = RunStateTracker(expectsRunning: true)
    let first = tracker.observe(isRunning: false)
    let second = tracker.observe(isRunning: false)
    let third = tracker.observe(isRunning: false)
    #expect(first, "the stop itself")
    #expect(second == false, "still down is not a new stop")
    #expect(third == false)
  }

  @Test("Steady running is never a stop")
  func steadyStateIsQuiet() {
    var tracker = RunStateTracker(expectsRunning: true)
    var reports: [Bool] = []
    for _ in 0..<5 { reports.append(tracker.observe(isRunning: true)) }
    #expect(reports.allSatisfy { $0 == false })
  }

  /// The regression. A relaunch is followed by polls that may still see nothing, and letting
  /// those become the expectation lost every future stop.
  @Test("A slow start is not mistaken for a crash")
  func slowStartIsNotAStop() {
    var tracker = RunStateTracker(expectsRunning: true)
    let firstCrash = tracker.observe(isRunning: false)
    tracker.expectRunning()

    // Still starting. None of these is a stop.
    var whileStarting: [Bool] = []
    for _ in 0..<(RunStateTracker.startGracePolls - 1) {
      whileStarting.append(tracker.observe(isRunning: false))
    }
    let onceUp = tracker.observe(isRunning: true)
    let secondCrash = tracker.observe(isRunning: false)

    #expect(firstCrash)
    #expect(whileStarting.allSatisfy { $0 == false }, "a cold start was called a crash")
    #expect(onceUp == false)
    #expect(secondCrash, "the second crash must still be seen")
  }

  /// The other half of the same decision: patience is bounded, or a crash-on-launch is never
  /// noticed at all and `LauncherPolicy.giveUp` becomes unreachable.
  @Test("A launch that never appears is eventually a stop")
  func aLaunchThatNeverArrivesIsAStop() {
    var tracker = RunStateTracker()
    tracker.expectRunning()

    var reports: [Bool] = []
    for _ in 0..<RunStateTracker.startGracePolls {
      reports.append(tracker.observe(isRunning: false))
    }

    #expect(reports.dropLast().allSatisfy { $0 == false }, "gave up before its grace expired")
    #expect(reports.last == true, "a launch that never arrived was never reported")
  }

  /// Crash-on-launch, over and over: every cycle has to register, or the crash budget is never
  /// spent and the launcher spins forever.
  @Test("Repeated crash-on-launch registers every cycle")
  func crashOnLaunchRegistersEveryCycle() {
    var tracker = RunStateTracker(expectsRunning: true)
    var noticed: [Bool] = []
    for _ in 0..<5 {
      // The app comes up, then dies — the realistic crash-on-launch, where it lives long
      // enough to be seen once.
      _ = tracker.observe(isRunning: true)
      noticed.append(tracker.observe(isRunning: false))
      tracker.expectRunning()
    }
    #expect(noticed.allSatisfy { $0 }, "a cycle went unnoticed: \(noticed)")
  }

  @Test("A tracker that never expected anything reports no stop")
  func freshTrackerIsQuiet() {
    var tracker = RunStateTracker()
    let reported = tracker.observe(isRunning: false)
    #expect(reported == false)
  }
}

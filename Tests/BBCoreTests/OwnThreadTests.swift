//  OwnThreadTests
//  Blocking work run through `onOwnThread` holds no cooperative thread, and `OneAtATime` runs
//  its operations in turn.
//
//  The failure `onOwnThread` prevents is a starved pool: an address-book pass held one of
//  two cooperative threads on a two-core Mac for tens of seconds, and everything else queued
//  behind it. The test that matters blocks MORE threads than the pool has and checks that an
//  unrelated task still runs. Run on the pool instead, it does not fail: it stalls, because the
//  poll and the deadline need a pool thread too, so a regression shows as a suite that hangs.

import Foundation
import Testing

@testable import BBCore

@Suite("Work on a thread of its own")
struct OwnThreadTests {

  @Test("More blocked calls than the pool has threads still leave the pool free")
  func blockedCallsDoNotStarveThePool() async throws {
    let gate = DispatchSemaphore(value: 0)
    let blockers = ProcessInfo.processInfo.activeProcessorCount + 2
    let entered = Locked(0)

    let held = (0..<blockers).map { _ in
      Task {
        try await onOwnThread { _ in
          entered.withLock { $0 += 1 }
          gate.wait()
        }
      }
    }
    defer {
      for _ in 0..<blockers { gate.signal() }
    }

    // Every blocker is parked on its thread before the unrelated work is asked for.
    let allIn = try await poll(.every(.milliseconds(10), attempts: 300)) { _ in
      entered.value == blockers ? true : nil
    }
    #expect(allIn == true)

    let ran = try await withTimeout(.seconds(5)) {
      await Task.detached { 42 }.value
    }
    #expect(ran == 42)

    for _ in 0..<blockers { gate.signal() }
    for task in held { try await task.value }
  }

  @Test("It answers with what the body returns and throws what it throws")
  func returnsAndThrows() async throws {
    struct Refused: Error {}
    #expect(try await onOwnThread { _ in "done" } == "done")
    await #expect(throws: Refused.self) {
      try await onOwnThread { _ -> Int in throw Refused() }
    }
  }

  /// The caller waits for the body even when cancelled, because the body owns the clean-up.
  @Test("Cancelling the caller raises the flag and still waits for the body")
  func cancellationRaisesTheFlag() async throws {
    let started = DispatchSemaphore(value: 0)
    let finished = Locked(false)

    let task = Task {
      try await onOwnThread { isCancelled -> Bool in
        started.signal()
        while !isCancelled() { Thread.sleep(forTimeInterval: 0.005) }
        finished.withLock { $0 = true }
        return true
      }
    }
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        started.wait()
        resume.resume()
      }
    }
    task.cancel()

    let sawFlag = try await withTimeout(.seconds(5)) { try await task.value }
    #expect(sawFlag)
    // Returned only once the body had: nothing is left running unseen.
    #expect(finished.value)
  }
}

@Suite("One at a time")
struct OneAtATimeTests {

  @Test("Operations never overlap, and run in the order they arrive")
  func serialises() async throws {
    let turns = OneAtATime()
    let log = Locked<[String]>([])
    let running = Locked(0)
    let overlapped = Locked(false)

    let first = Task {
      try await turns.run {
        running.withLock { $0 += 1 }
        log.withLock { $0.append("first in") }
        try await Task.sleep(for: .milliseconds(100))
        if running.value > 1 { overlapped.withLock { $0 = true } }
        log.withLock { $0.append("first out") }
        running.withLock { $0 -= 1 }
      }
    }
    // Queued behind the first, which has had time to claim the turn.
    try await Task.sleep(for: .milliseconds(20))
    let second = Task {
      try await turns.run {
        running.withLock { $0 += 1 }
        log.withLock { $0.append("second in") }
        running.withLock { $0 -= 1 }
      }
    }
    try await first.value
    try await second.value

    #expect(!overlapped.value)
    #expect(log.value == ["first in", "first out", "second in"])
  }

  @Test("A waiter cancelled in the queue leaves, and the next one still gets its turn")
  func cancelledWaiterIsSkipped() async throws {
    let turns = OneAtATime()
    let ran = Locked<[String]>([])

    let first = Task {
      try await turns.run { try await Task.sleep(for: .milliseconds(150)) }
    }
    try await Task.sleep(for: .milliseconds(20))
    let cancelled = Task {
      try await turns.run { ran.withLock { $0.append("cancelled") } }
    }
    try await Task.sleep(for: .milliseconds(20))
    let third = Task {
      try await turns.run { ran.withLock { $0.append("third") } }
    }
    try await Task.sleep(for: .milliseconds(20))
    cancelled.cancel()

    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await first.value
    try await withTimeout(.seconds(5)) { try await third.value }
    #expect(ran.value == ["third"])
  }
}

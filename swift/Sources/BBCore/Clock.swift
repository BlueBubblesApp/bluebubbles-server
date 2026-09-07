//  Clock
//  Wall-clock time behind a protocol, so time-dependent behavior is testable.
//
//  Everything that expires — rate-limit lockouts, alert retention, enrollment codes, token
//  lifetimes, cache TTLs — needs a test that proves the expiry actually happens. Without an
//  injectable clock those tests either sleep (slow and flaky) or don't exist. The current
//  server has no such abstraction, and correspondingly no expiry tests.
//
//  Note this is deliberately about `Date`, not `ContinuousClock`. Both matter and they are
//  not interchangeable: durations measured for backoff and debounce use `ContinuousClock`
//  because it does not jump when the system clock is adjusted, while anything persisted or
//  shown to a person needs a wall-clock `Date`. Sleeping the Mac and waking it hours later
//  is the case that separates them, and this server runs on Macs that sleep.

import Foundation
import os

public protocol BBClock: Sendable {
  var now: Date { get }
}

public struct SystemClock: BBClock {
  public init() {}
  public var now: Date { Date() }
}

/// A clock a test drives by hand. Nothing sleeps.
public final class ManualClock: BBClock, Sendable {
  private let current: OSAllocatedUnfairLock<Date>

  public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    current = OSAllocatedUnfairLock(initialState: start)
  }

  public var now: Date { current.withLock { $0 } }

  public func advance(by interval: TimeInterval) {
    current.withLock { $0 = $0.addingTimeInterval(interval) }
  }

  public func advance(by duration: Duration) {
    advance(by: duration.seconds)
  }

  public func set(_ date: Date) {
    current.withLock { $0 = date }
  }
}

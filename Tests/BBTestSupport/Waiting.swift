//  Waiting
//  Waiting for something another task does, without guessing how long it takes.
//
//  A test about asynchronous work has to wait for it, and the two ways that go wrong are a
//  fixed sleep (too short on a loaded machine, wasted on an idle one) and a hand-written
//  deadline loop, of which there were dozens, each with its own interval, its own ceiling,
//  and its own idea of what to do at the end: record an issue, return false, or fall
//  through having asserted nothing. These two functions poll on BBCore's schedule and, at
//  the deadline, THROW an error naming what never happened, so a test cannot carry on past
//  a wait that failed.
//
//  This is for state the test cannot be told about. Where the code under test takes a
//  clock, inject one and advance it instead; that is faster and cannot flake.

import BBCore
import Foundation

/// A wait that reached its deadline.
public struct WaitTimedOut: Error, CustomStringConvertible {
  public let what: String
  public let timeout: Duration

  public var description: String { "Waited \(timeout) for \(what), and it never happened." }
}

/// Polls `condition` until it holds.
///
/// - Parameters:
///   - what: What is being waited for, as the end of "waited 5 seconds for …".
///   - timeout: Generous on purpose: it is paid only by a test that is failing.
///   - interval: How often to look.
/// - Throws: `WaitTimedOut` at the deadline, and whatever `condition` throws.
public func waitUntil(
  _ what: String,
  timeout: Duration = .seconds(5),
  interval: Duration = .milliseconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async throws {
  _ = try await waitFor(what, timeout: timeout, interval: interval, isolation: isolation) {
    try await condition() ? true : nil
  }
}

/// Polls `value` until it returns something, and returns it.
///
/// - Throws: `WaitTimedOut` at the deadline, and whatever `value` throws.
public func waitFor<T>(
  _ what: String,
  timeout: Duration = .seconds(5),
  interval: Duration = .milliseconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ value: () async throws -> T?
) async throws -> T {
  // `poll` looks once more after the last sleep, so a value that arrives just before the
  // deadline is still seen.
  let found = try await poll(.every(interval), within: timeout, isolation: isolation) { _ in
    try await value()
  }
  guard let found else { throw WaitTimedOut(what: what, timeout: timeout) }
  return found
}

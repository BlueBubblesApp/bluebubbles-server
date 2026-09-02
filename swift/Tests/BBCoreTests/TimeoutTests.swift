//  TimeoutTests
//  The one timeout helper, now that six copies became one.
//
//  The copies were all correct, so nothing here is a regression test for a bug that shipped.
//  What it pins is the contract callers depend on: the deadline actually bounds the call, the
//  work's own error wins over the deadline, and the losing side is cancelled rather than left
//  running — the last of which the task group does for us and which is worth asserting
//  precisely because it is invisible in the source.

import Foundation
import Testing

@testable import BBCore

@Suite("Timeout")
struct TimeoutTests {

  @Test("Work that finishes in time returns its value")
  func fastWorkReturns() async throws {
    let value = try await withTimeout(.seconds(5)) { 42 }
    #expect(value == 42)
  }

  @Test("Work that overruns throws, and does not wait for it")
  func slowWorkThrows() async throws {
    let clock = ContinuousClock()
    var thrown: (any Error)?

    let elapsed = await clock.measure {
      do {
        _ = try await withTimeout(.milliseconds(50)) {
          try await Task.sleep(for: .seconds(30))
          return 0
        }
      } catch {
        thrown = error
      }
    }

    #expect(thrown is TimedOut)
    // The point of the deadline: the call returns on it, rather than on the work it gave up
    // waiting for. Generous bound because CI machines stall.
    #expect(elapsed < .seconds(5))
  }

  /// The group cancels the loser on its way out, so the abandoned work stops rather than
  /// running to completion with nobody reading its result.
  @Test("The abandoned work is cancelled")
  func loserIsCancelled() async throws {
    let observed = Cancellation()

    _ = try? await withTimeout(.milliseconds(50)) {
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        await observed.note()
        throw error
      }
      return 0
    }

    // Cancellation reaches the child after this call returns, so wait for it rather than
    // reading immediately.
    for _ in 0..<200 where await !observed.happened {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await observed.happened)
  }

  @Test("An error from the work wins over the deadline")
  func operationErrorPropagates() async {
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
      try await withTimeout(.seconds(5)) { throw Boom() }
    }
  }

  @Test("The deadline is carried on the error when it is known")
  func errorCarriesTheDeadline() async {
    do {
      _ = try await withTimeout(.milliseconds(10)) {
        try await Task.sleep(for: .seconds(30))
        return 0
      }
      Issue.record("expected the deadline to pass")
    } catch let timeout as TimedOut {
      #expect(timeout.duration == .milliseconds(10))
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  private actor Cancellation {
    private(set) var happened = false
    func note() { happened = true }
  }
}

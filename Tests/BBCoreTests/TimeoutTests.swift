//  TimeoutTests
//  The one timeout helper, now that six copies became one.
//
//  The copies were all correct, so nothing here is a regression test for a bug that shipped.
//  What it pins is the contract callers depend on: the deadline actually bounds the call, the
//  work's own error wins over the deadline, and the losing side is cancelled rather than left
//  running: the last of which the task group does for us and which is worth asserting
//  precisely because it is invisible in the source.

import BBTestSupport
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
    try await waitUntil("the child to observe its cancellation") { await observed.happened }
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

  /// What `DiagnosticText` shows a person: the syslog forwarder's failing state carries it.
  @Test("The deadline is spelled as a sentence, not as a Double")
  func sentenceSpellsTheDeadline() {
    #expect(TimedOut(after: .seconds(5)).body == "The operation did not finish within 5 seconds.")
    #expect(TimedOut(after: .seconds(1)).body == "The operation did not finish within 1 second.")
    #expect(
      TimedOut(after: .milliseconds(250)).body
        == "The operation did not finish within 0.25 seconds.")
    #expect(TimedOut().body == "The operation timed out.")
    #expect(DiagnosticText.sentence(for: TimedOut(after: .seconds(5))).hasPrefix("The operation"))
  }

  private actor Cancellation {
    private(set) var happened = false
    func note() { happened = true }
  }
}

/// `awaitContinuation` exists because a task group racing a bare continuation against a
/// sleep cannot finish when the sleep wins: cancelling the continuation's task does not
/// resume it. These pin the three orderings that each stranded a caller somewhere.
@Suite("Awaiting a continuation")
struct AwaitContinuationTests {

  struct Deadline: Error {}

  @Test("The owner's answer is returned")
  func ownerAnswers() async throws {
    let value: Int = try await awaitContinuation(
      timeout: .seconds(5), timeoutError: { Deadline() },
      register: { waiter in
        Task {
          try? await Task.sleep(for: .milliseconds(10))
          waiter.resume(returning: 7)
        }
      },
      abandon: { _ in }
    )
    #expect(value == 7)
  }

  @Test("An answer delivered before the waiter attaches is not lost")
  func answerBeforeAttach() async throws {
    let value: Int = try await awaitContinuation(
      timeout: .seconds(5), timeoutError: { Deadline() },
      register: { $0.resume(returning: 3) }, abandon: { _ in }
    )
    #expect(value == 3)
  }

  @Test("An owner that never answers is timed out, promptly, and told to let go")
  func ownerNeverAnswers() async throws {
    let abandoned = Flag()
    let clock = ContinuousClock()
    var thrown: (any Error)?
    let elapsed = await clock.measure {
      do {
        let _: Int = try await awaitContinuation(
          timeout: .milliseconds(50), timeoutError: { Deadline() },
          register: { _ in }, abandon: { _ in await abandoned.set() }
        )
      } catch {
        thrown = error
      }
    }
    #expect(thrown is Deadline)
    #expect(elapsed < .seconds(5))
    #expect(await abandoned.value)
  }

  @Test("A caller cancelled before registration lands is released, and the owner can tell")
  func cancelledBeforeRegistration() async throws {
    let sawResolved = Flag()
    let task = Task {
      let _: Int = try await awaitContinuation(
        timeout: .seconds(30), timeoutError: { Deadline() },
        register: { waiter in
          try? await Task.sleep(for: .milliseconds(100))
          if waiter.isResolved { await sawResolved.set() }
        },
        abandon: { _ in }
      )
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    try await waitUntil("the abandoned wait to be resolved") { await sawResolved.value }
    #expect(await sawResolved.value)
  }

  @Test("A second answer is ignored rather than trapping")
  func secondAnswerIgnored() async throws {
    let value: Int = try await awaitContinuation(
      timeout: .seconds(5), timeoutError: { Deadline() },
      register: { waiter in
        waiter.resume(returning: 1)
        waiter.resume(returning: 2)
        waiter.resume(throwing: Deadline())
      },
      abandon: { _ in }
    )
    #expect(value == 1)
  }

  private actor Flag {
    private(set) var value = false
    func set() { value = true }
  }
}

@Suite("OnceContinuation as its own waiter")
struct OnceContinuationValueTests {

  /// A process that exits before anyone waits on it is the ordinary case for `Subprocess`.
  @Test("A result delivered before the wait is returned when the wait arrives")
  func earlyResultIsHeld() async throws {
    let once = OnceContinuation<Int>()
    once.resume(returning: 7)
    let value = try await withTimeout(.seconds(5)) { try await once.value() }
    #expect(value == 7)
  }

  /// The permission probe races a thread against a deadline, and each must know whether it
  /// was the one that answered.
  @Test("Only the first resume is delivered, and each caller is told whether it won")
  func firstResumeWins() async throws {
    let once = OnceContinuation<String>()
    #expect(once.resume(returning: "probe"))
    #expect(!once.resume(returning: "deadline"))
    #expect(!once.resume(throwing: CancellationError()))
    let value = try await withTimeout(.seconds(5)) { try await once.value() }
    #expect(value == "probe")
  }
}

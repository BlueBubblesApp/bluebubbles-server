//  PrivateAPIStartDeadlineTests
//  A Private API that cannot come up must not take the server with it.
//
//  Starting it quits and relaunches somebody else's app and then waits for a helper inside
//  it to call back — every step at the mercy of a process this one does not control. Without
//  a ceiling the whole server start waits on the slowest of them, and that was observed: the
//  HTTP port was open (NIO runs its own threads) while every async task behind it starved, so
//  connections were accepted and never served. From outside it looks like a hung server with
//  no error anywhere.
//
//  Two properties matter and they pull in opposite directions:
//    - Overrunning must NOT fail the server. The Private API is optional; running without it
//      is documented as supported rather than degraded.
//    - Failing must STILL fail. "Messages is switched on and cannot be injected" is fatal on
//      purpose, and a deadline must not quietly downgrade that to a warning.

import BBPrivateAPI
import Testing

@Suite("Private API start is bounded")
struct PrivateAPIStartDeadlineTests {

  @Test("The deadline is generous enough for a real injection")
  func deadlineIsGenerous() {
    // Injection quits and relaunches Messages and waits for a callback. A tight deadline
    // would disable a working Private API on a busy Mac, which is worse than the hang it
    // is meant to prevent — that at least is visible.
    #expect(PrivateAPIRuntime.startDeadline >= .seconds(60))
  }

  @Test("The deadline is short enough to be a ceiling rather than a formality")
  func deadlineIsBounded() {
    #expect(PrivateAPIRuntime.startDeadline <= .seconds(180))
  }

  @Test("Outcomes distinguish off, working, overran and failed")
  func outcomesAreDistinct() {
    // The UI reads these, and collapsing any two would put the wrong sentence on screen:
    // "switched off" and "did not finish starting" need different remedies.
    let all: [PrivateAPIRuntime.StartOutcome] = [
      .notStarted, .disabled, .running, .timedOut, .failed("x"),
    ]
    for (index, outcome) in all.enumerated() {
      for other in all[(index + 1)...] {
        #expect(outcome != other, "\(outcome) and \(other) are indistinguishable")
      }
    }
  }

  @Test("A failure carries its reason forward")
  func failureCarriesReason() {
    // `.failed` is rendered verbatim, so it has to hold the explanation rather than being
    // a bare marker the UI then has to guess at.
    guard case .failed(let reason) = PrivateAPIRuntime.StartOutcome.failed("dylib is arm64") else {
      Issue.record("failed lost its reason")
      return
    }
    #expect(reason == "dylib is arm64")
  }
}

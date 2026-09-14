//  ResumeOnceTests
//  The three things an IMCore completion does that a bare continuation cannot survive.

import Foundation
import HelperShared
import Testing

@Suite("ResumeOnce")
struct ResumeOnceTests {

  @Test("The first finish wins and a second is ignored")
  func firstFinishWins() async {
    let once = ResumeOnce<Int>()
    once.finish(1)
    once.finish(2)
    #expect(await once.wait() == 1)
    #expect(once.isFinished)
  }

  @Test("Finishing before anyone waits releases the waiter immediately")
  func finishBeforeWait() async {
    let once = ResumeOnce<String>()
    once.finish("early")
    #expect(await once.wait() == "early")
  }

  @Test("A waiter is released when finish arrives from another task")
  func finishFromAnotherTask() async {
    let once = ResumeOnce<Void>()
    Task {
      try? await Task.sleep(for: .milliseconds(20))
      once.finish()
    }
    await once.wait()
    #expect(once.isFinished)
  }

  @Test("A bounded wait delivers the timeout value when nothing answers")
  func timeoutValue() async {
    let once = ResumeOnce<String>()
    let value = await once.wait(timeout: .milliseconds(30), onTimeout: "timed out")
    #expect(value == "timed out")
  }

  @Test("A completion that answers in time is not overridden by the watchdog")
  func answerBeatsWatchdog() async {
    let once = ResumeOnce<String>()
    Task { once.finish("answered") }
    let value = await once.wait(timeout: .seconds(5), onTimeout: "timed out")
    #expect(value == "answered")
    // The watchdog was cancelled; give it a moment and confirm the value stuck.
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await once.wait() == "answered")
  }
}

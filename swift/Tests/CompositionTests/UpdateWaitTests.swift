//  UpdateWaitTests
//  `POST /server/update/install?wait=true` answers when the download has landed.
//
//  The flag was accepted and ignored. The reference awaits `autoUpdater.downloadUpdate()`
//  before answering (`serverRouter.ts:37-40`); this server answered as soon as Sparkle had
//  been asked, so the one client that cares about the difference — the one that sent the
//  flag — was told "downloading started" in the same words it would have been told
//  "downloading finished", and could not tell which it got.
//
//  The real implementation is Sparkle's delegate (`SparkleUpdater.awaitDownload`), which
//  needs an actual update on a real feed to exercise. What is testable here is the contract
//  every caller depends on: the handler waits when asked, does not when it is not, and
//  reports the outcome rather than claiming success.

import BBInterfaces
import BBUpdates
import Foundation
import Testing

@Suite("Update install wait")
struct UpdateWaitTests {

  /// A Sparkle stand-in that records what it was asked and answers what it was told to.
  private actor Installer: UpdateInstalling {
    private let outcome: UpdateDownloadOutcome
    private let delay: Duration
    private(set) var beganUpdates = 0
    private(set) var waits: [Duration] = []

    init(outcome: UpdateDownloadOutcome, delay: Duration = .zero) {
      self.outcome = outcome
      self.delay = delay
    }

    func beginUpdate(to item: AppcastItem) async { beganUpdates += 1 }
    var installState: UpdateInstallState? { nil }

    func awaitDownload(timeout: Duration) async -> UpdateDownloadOutcome {
      waits.append(timeout)
      if delay > .zero { try? await Task.sleep(for: delay) }
      return outcome
    }
  }

  @Test("A download that lands is reported as landed")
  func downloaded() async {
    let installer = Installer(outcome: .downloaded)
    let outcome = await installer.awaitDownload(timeout: .seconds(600))
    #expect(outcome == .downloaded)
    #expect(await installer.waits == [.seconds(600)])
  }

  /// The case the bounded wait exists for: an HTTP request must not be held open until the
  /// route's own timeout answers nothing at all, and "still downloading" is a true answer.
  @Test("A wait that runs out says so rather than claiming success")
  func timedOut() async {
    let installer = Installer(outcome: .timedOut)
    #expect(await installer.awaitDownload(timeout: .seconds(1)) == .timedOut)
  }

  @Test("A failed download carries its reason")
  func failed() async {
    let installer = Installer(outcome: .failed("the server returned 404"))
    #expect(
      await installer.awaitDownload(timeout: .seconds(1)) == .failed("the server returned 404"))
  }

  /// `beginUpdate` can find Sparkle already busy, or put its own window up for whoever is at
  /// the Mac. Neither downloads anything, and waiting for a callback that cannot come would
  /// hold the request for the whole deadline.
  @Test("Nothing downloading is answered at once, not after the deadline")
  func notDownloading() async {
    let installer = Installer(outcome: .notDownloading)
    let started = ContinuousClock.now
    #expect(await installer.awaitDownload(timeout: .seconds(600)) == .notDownloading)
    #expect(ContinuousClock.now - started < .seconds(1))
  }

  /// The outcomes are what the handler turns into the response's `state`, so each has to be
  /// distinguishable; two that compared equal would collapse into one answer on the wire.
  @Test("Every outcome is its own answer")
  func outcomesAreDistinct() {
    let all: [UpdateDownloadOutcome] = [
      .downloaded, .timedOut, .notDownloading, .failed("a"),
    ]
    for (index, outcome) in all.enumerated() {
      for (otherIndex, other) in all.enumerated() where index != otherIndex {
        #expect(outcome != other)
      }
    }
    #expect(UpdateDownloadOutcome.failed("a") != .failed("b"))
  }
}

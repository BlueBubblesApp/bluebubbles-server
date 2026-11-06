//  FaceTimeNoVideoAlertTests
//  The automatic dismissal ends FaceTime's "No Video" alert and nothing else.
//
//  This runs unasked inside somebody's FaceTime, so what matters is what it REFUSES. The
//  dismissal itself, and the alert being presented by FaceTime's own timer, need FaceTime.
//  See docs/headers/FACETIME.md.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import AppKit
import Foundation
import Testing

@testable import BlueBubblesFaceTimeHelper

@Suite("FaceTime's No Video alert is recognised specifically")
struct FaceTimeNoVideoAlertTests {

  private let expected = "FaceTime has not received any video from the connected camera."

  @Test("The alert FaceTime shows is recognised")
  func recognisesTheAlert() {
    #expect(
      FaceTimeNoVideoAlert.recognises(
        informativeText: expected, buttonCount: 1, expected: expected))
  }

  @Test(
    "Another alert with one button is left alone",
    arguments: [
      "someone@example.com is not available for FaceTime.",
      "This call has ended.",
      "",
    ])
  func refusesOtherText(text: String) {
    #expect(
      !FaceTimeNoVideoAlert.recognises(informativeText: text, buttonCount: 1, expected: expected))
  }

  @Test("Text that only contains the expected sentence is left alone")
  func refusesAContainingSentence() {
    #expect(
      !FaceTimeNoVideoAlert.recognises(
        informativeText: expected + " Allow it to call someone?", buttonCount: 1,
        expected: expected))
  }

  /// An alert offering a choice is never answered automatically, whatever it says.
  @Test("The right text with a choice to make is left alone", arguments: [0, 2, 3])
  func refusesAnyOtherButtonCount(buttons: Int) {
    #expect(
      !FaceTimeNoVideoAlert.recognises(
        informativeText: expected, buttonCount: buttons, expected: expected))
  }

  @Test("With no expected text, nothing is recognised, not even empty text")
  func recognisesNothingWithoutTheString() {
    #expect(
      !FaceTimeNoVideoAlert.recognises(informativeText: expected, buttonCount: 1, expected: nil))
    #expect(!FaceTimeNoVideoAlert.recognises(informativeText: "", buttonCount: 1, expected: nil))
  }

  /// `localizedString(forKey:value:table:)` answers with the key when the key is missing.
  @Test("A lookup that found nothing gives no expected text")
  func aMissingKeyIsNotAnExpectedText() {
    #expect(FaceTimeNoVideoAlert.expectedText(localized: FaceTimeNoVideoAlert.textKey) == nil)
    #expect(FaceTimeNoVideoAlert.expectedText(localized: "") == nil)
    #expect(FaceTimeNoVideoAlert.expectedText(localized: expected) == expected)
  }

  /// The class lives in FaceTime's own plug-in, so this process is a release without it.
  @Test("Outside FaceTime there is no expected text")
  func absentOutsideFaceTime() {
    #expect(FaceTimeNoVideoAlert.expectedTextInThisProcess() == nil)
  }

  /// Stopping a preview before its first frame leaves FaceTime's timer running.
  @Test("A running preview waits for its first frame")
  func waitsForTheFirstFrame() {
    let now = Date()
    let later = now.addingTimeInterval(1)
    let earlier = now.addingTimeInterval(-1)

    #expect(
      !FaceTimeNoVideoAlert.mayStopPreview(
        firstFrameArrived: false, timerExists: true, now: now, waitEnds: later))
    #expect(
      FaceTimeNoVideoAlert.mayStopPreview(
        firstFrameArrived: true, timerExists: true, now: now, waitEnds: later))
    // A frame that never comes does not leave the camera on for good.
    #expect(
      FaceTimeNoVideoAlert.mayStopPreview(
        firstFrameArrived: false, timerExists: true, now: now, waitEnds: earlier))
    // A release without the timer has nothing to wait for.
    #expect(
      FaceTimeNoVideoAlert.mayStopPreview(
        firstFrameArrived: false, timerExists: false, now: now, waitEnds: later))
  }

  /// The wait has to outlast the 30 seconds FaceTime schedules, or it protects nothing.
  @Test("The wait outlasts FaceTime's timer")
  func theWaitOutlastsTheTimer() {
    #expect(FaceTimeNoVideoAlert.longestFirstFrameWait > 30)
  }

  /// What the observer filters on and reads, pinned against real AppKit.
  @Test("An alert's window has the alert as its delegate")
  @MainActor
  func theWindowLeadsToTheAlert() {
    let alert = NSAlert()
    alert.informativeText = expected
    #expect(alert.window.delegate === alert)
    #expect((alert.window.delegate as? NSAlert)?.informativeText == expected)
  }
}

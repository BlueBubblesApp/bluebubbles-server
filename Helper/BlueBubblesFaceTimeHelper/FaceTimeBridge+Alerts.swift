//  FaceTimeBridge+Alerts
//  The UI FaceTime puts up on its own: an alert when a dial wedges, and the "No Video" alert
//  when a camera sends nothing. The Private API says nothing about either, so both are read
//  and dismissed through AppKit, and dismissal always cancels, never confirms.
//
//  Two different policies, on purpose. `dismissBlockingAlerts` is recovery: it runs when the
//  helper registers and on request, and ends whatever is up. `dismissNoVideoAlertWhenShown`
//  runs for as long as the helper is loaded, so it ends ONE alert it can recognise and leaves
//  every other alone: a blanket cancel at any moment would take a prompt somebody was reading.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import AppKit
import HelperShared

/// Recognises FaceTime's "No Video" alert, and nothing else.
///
/// **What it is.** `-[CameraController _noFramesTimeout:]`, in FaceTime's
/// `FaceTimeMacHelper.bundle` (disassembled on 27.0.1). The first time the controller starts a
/// preview on a camera it considers valid, it schedules that method 30 seconds out, and only
/// a first preview frame or `-cleanupNoFramesTimer` cancels it. A Mac with no camera at all
/// takes a different branch and never arms it. The alert carries one button and no decision.
///
/// **Compared against FaceTime's own string, so it holds in every language.** The expected text
/// comes from the same table, key and bundle the alert reads, so it is whatever FaceTime would
/// show in this process. A macOS that renames the class or drops the key leaves `expected` nil,
/// and nil recognises nothing: the alert stays up, which is the state with no helper at all.
enum FaceTimeNoVideoAlert {

  /// FaceTime's class that presents the alert, used only to find its bundle. Never messaged.
  static let presentingClass = "CameraController"
  static let textKey = "NO_FRAMES_ALERT_TEXT"
  static let table = "Localizable"

  /// Whether an alert with this content is the No Video alert.
  ///
  /// The button count is a second, independent check: an alert with a second button is
  /// offering a choice, and an automatic dismissal must never make one for somebody.
  static func recognises(informativeText: String, buttonCount: Int, expected: String?) -> Bool {
    guard let expected else { return false }
    return buttonCount == 1 && informativeText == expected
  }

  /// What a lookup answered, as text worth comparing against.
  ///
  /// `localizedString(forKey:value:table:)` answers with the key itself when the key is missing,
  /// so a missing key would otherwise be an expected text no alert should be matched on.
  static func expectedText(localized: String) -> String? {
    localized.isEmpty || localized == textKey ? nil : localized
  }

  /// How long a preview is left running for its first frame: the timer's 30 seconds, plus
  /// enough for it to have fired by the time the wait ends.
  static let longestFirstFrameWait: TimeInterval = 35

  /// Whether the helper's idle-camera stop may stop a running preview yet.
  ///
  /// **Stopping a preview before its first frame would leave the timer to fire on a Mac whose
  /// camera works.** The frame is the only thing that cancels it apart from FaceTime's own
  /// `-cleanupNoFramesTimer`, and stopping the preview through its owner goes through neither.
  /// The gap is about 50 ms on a healthy built-in camera, and it has been recorded at 13 seconds
  /// on a struggling Mac, against a stop polled every half second.
  ///
  /// Bounded, because a frame that never comes must not leave a camera indicator lit for good,
  /// which also covers a macOS posting the frame under another name. A preview first started
  /// after the wait ends can still lose the race; the dismissal covers that.
  static func mayStopPreview(
    firstFrameArrived: Bool, timerExists: Bool, now: Date, waitEnds: Date
  ) -> Bool {
    firstFrameArrived || !timerExists || now >= waitEnds
  }

  /// The text FaceTime would show here, or nil if this macOS does not have the alert.
  static func expectedTextInThisProcess() -> String? {
    guard let presenter = IMCoreRuntime.lookUpClass(presentingClass) else { return nil }
    return expectedText(
      localized: Bundle(for: presenter).localizedString(forKey: textKey, value: "", table: table))
  }
}

extension FaceTimeBridge {

  // MARK: - Blocking alerts

  /// What FaceTime.app is showing, for diagnosing a wedged dial.
  ///
  /// Dialling an address that is not FaceTime-capable does not fail the API call: a
  /// `TUCall` is created and reports `outgoing`, but FaceTime puts up "…is not available
  /// for FaceTime" and the call never forms a conversation. The alert is a UI object the
  /// private API says nothing about, so it is inspected through AppKit.
  @MainActor
  static func windowSummaries() -> [String] {
    NSApplication.shared.windows.map { window in
      let sheet = window.attachedSheet.map { " attachedSheet=\(type(of: $0))" } ?? ""
      return "\(type(of: window)) title=\(window.title.isEmpty ? "-" : window.title) "
        + "visible=\(window.isVisible) sheet=\(window.isSheet) "
        + "level=\(window.level.rawValue)\(sheet)"
    }
  }

  /// Dismisses a blocking alert, CANCELLING rather than confirming.
  ///
  /// Deliberately the safe button: this alert's other options offer to call a DIFFERENT
  /// address on the contact card, and dismissing it by confirming could place a call to
  /// someone the client never asked for. Cancelling only ever un-wedges the app.
  ///
  /// Returns how many were dismissed, so a caller can tell "cleared a blockage" from
  /// "nothing was blocking".
  @MainActor
  static func dismissBlockingAlerts() -> Int {
    alertsUp().count(where: cancel)
  }

  /// Every alert FaceTime has up: the app-modal one, and a sheet on any window.
  @MainActor
  private static func alertsUp() -> [NSWindow] {
    let app = NSApplication.shared
    return [app.modalWindow].compactMap(\.self) + app.windows.compactMap(\.attachedSheet)
  }

  /// Ends one alert, whichever way it was presented. Answers whether it was up to end.
  @MainActor
  private static func cancel(_ alertWindow: NSWindow) -> Bool {
    let app = NSApplication.shared
    // App-modal: end the session, then close the window it ran.
    if app.modalWindow === alertWindow {
      app.abortModal()
      alertWindow.close()
      return true
    }
    // A sheet: end it with a cancel response.
    if let parent = alertWindow.sheetParent, parent.attachedSheet === alertWindow {
      parent.endSheet(alertWindow, returnCode: .cancel)
      return true
    }
    return false
  }

  // MARK: - The No Video alert

  /// Ends FaceTime's "No Video" alert as soon as it appears.
  ///
  /// **Why registration cannot catch it.** `FaceTimeCleanup` cancels alerts when the helper
  /// registers, as FaceTime launches, and this alert is on a 30-second timer from about then.
  /// Without this it stays up until somebody clicks OK, and on a server Mac there may be
  /// nobody. When FaceTime is in the background the alert is app-modal and it ACTIVATES
  /// FaceTime (measured, 27.0.1), which takes focus from whatever the Mac was doing and turns
  /// the camera on: `keepPreviewOffWhileInactive` stands down while FaceTime is frontmost.
  ///
  /// **Rung 1, not a poll.** AppKit posts these for the alert's own window. It is presented
  /// two ways, and both post them (measured): `runModal` when FaceTime has no visible main
  /// window, a sheet when it does. Two names, because the key-window one depends on FaceTime
  /// being allowed to activate.
  ///
  /// **Not gated on FaceTime being frontmost**, unlike the camera, because the modal alert
  /// makes it frontmost itself, so the rule could never be true when it mattered. What this
  /// costs somebody at the Mac is one notice saying their camera sent nothing, and the black
  /// preview behind it says the same. Its advice is to restart the computer.
  static func dismissNoVideoAlertWhenShown() {
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        // A later turn, because these arrive while the alert is still being presented, and
        // because `abortModal` wants a running session to end. The modal loop drains the
        // main queue (measured), so this runs while the alert is up.
        DispatchQueue.main.async {
          MainActor.assumeIsolated { dismissNoVideoAlertIfUp() }
        }
      }
    }
  }

  @MainActor
  private static func dismissNoVideoAlertIfUp() {
    for window in alertsUp() {
      guard let alert = window.delegate as? NSAlert,
        FaceTimeNoVideoAlert.recognises(
          informativeText: alert.informativeText,
          buttonCount: alert.buttons.count,
          expected: FaceTimeNoVideoAlert.expectedTextInThisProcess()),
        cancel(window)
      else { continue }
      BlueBubblesFaceTimeHelper.log.info("Dismissed FaceTime's No Video alert")
    }
  }
}

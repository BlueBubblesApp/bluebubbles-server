//  FaceTimeBridge+IdlePreview
//  The camera FaceTime turns on when the server relaunches it for injection, and keeping it
//  off while FaceTime is in the background. Turning it off undoes this helper's own side
//  effect, and the camera is left alone while FaceTime is the app the user is looking at.
//
//  One flow's worth of `FaceTimeBridge`. The static state it reads and writes is declared
//  in `FaceTimeBridge.swift`, beside the enum.

import AppKit
import Foundation
import HelperShared

extension FaceTimeBridge {

  // MARK: - The idle camera

  /// Turns off the self-preview FaceTime starts when we relaunch it for injection.
  ///
  /// **The camera is a side effect of injection, not something the Private API needs.**
  /// Injection RELAUNCHES FaceTime.app, and FaceTime comes up previewing you, so turning
  /// the FaceTime Private API on lit the user's camera and the recording indicator for as
  /// long as the server ran, with no call in progress. What this helper drives is
  /// `TUConversationManagerXPCClient` and the daemons behind it, which do not care whether a
  /// preview is running. Stopping it is undoing our own side effect.
  ///
  /// **It has to be stopped at the layer that OWNS it.** `AVConferencePreview` is the object
  /// that runs the camera, and stopping it there does nothing lasting: its delegate (a
  /// `TUVideoDeviceControllerProvider`) still believes a preview should exist and starts a
  /// new one about 1.2 seconds later. Sending `stopPreview` to the DELEGATE instead turns the
  /// camera off and it stays off. The delegate is reached through the preview because
  /// `TUVideoDeviceControllerProvider` has no singleton; FaceTime owns the instance.
  ///
  /// **This is ONE SHOT, and that is a known limitation rather than a decision.** FaceTime's
  /// own `PowerManager` cycles the camera as the app gains and loses focus ("Want camera
  /// paused because of power saver"), and a later resume starts it again with nothing here
  /// to stop it, which presents as the preview being absent from the window while the green
  /// indicator is lit. See `TODO.md`. One shot is what keeps this from fighting a user who
  /// opened FaceTime to actually make a call.
  ///
  /// `isPreviewRunning` is what this waits for rather than a delay: the preview does not
  /// exist at `didFinishLaunching`, and a fixed sleep is a race dressed as a constant. That
  /// flag turns true when the first frame arrives, so the camera is live for about fourteen
  /// seconds after a server start and off thereafter.
  ///
  /// Every failure is silent and survivable. This runs inside somebody's FaceTime, and a
  /// macOS that renames any of it must cost them a camera indicator, not their FaceTime.
  static func stopIdlePreview(attemptsRemaining: Int = 60) {
    guard attemptsRemaining > 0 else {
      BlueBubblesFaceTimeHelper.log.info(
        "Gave up waiting for FaceTime's preview to start; the camera may stay on")
      return
    }
    guard
      let preview = try? IMCoreRuntime.sharedInstance(
        ofClass: "AVConferencePreview", accessors: ["AVConferencePreviewSingleton"]
      ),
      let owner = try? IMCoreRuntime.send(preview, "delegate"),
      IMCoreRuntime.responds(owner, to: "stopPreview")
    else {
      retryStoppingIdlePreview(attemptsRemaining: attemptsRemaining - 1)
      return
    }

    // `isPreviewRunning` returns BOOL, so it goes through `bool`; `send` would read the
    // byte as a pointer. False simply means "not started yet".
    guard (try? IMCoreRuntime.bool(owner, "isPreviewRunning")) == true else {
      retryStoppingIdlePreview(attemptsRemaining: attemptsRemaining - 1)
      return
    }

    do {
      try IMCoreRuntime.send(owner, "stopPreview")
      BlueBubblesFaceTimeHelper.log.info("Turned off FaceTime's idle camera preview")
    } catch {
      BlueBubblesFaceTimeHelper.log.info("Could not turn off the idle preview: \(error)")
    }
  }

  private static func retryStoppingIdlePreview(attemptsRemaining: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      MainActor.assumeIsolated { stopIdlePreview(attemptsRemaining: attemptsRemaining) }
    }
  }

  // MARK: - Keeping it off while nobody is looking

  /// Keeps the camera off for as long as FaceTime is not the app the user is looking at.
  ///
  /// **The one-shot stop is not enough, because FaceTime's `CameraController` is a
  /// RECONCILER.** It re-derives `wantCamera` on its own events and restarts anything that
  /// does not match; its log line for undoing our stop is literally "Unpausing preview". So
  /// the camera comes back the moment the user switches windows, which is exactly when they
  /// notice: no preview in the window, green indicator lit.
  ///
  /// **The rule is `NSApp.isActive`, not "the preview started".** Hooking the start and
  /// stopping again would also fight somebody who opened FaceTime to make a call: before
  /// they dial there is no active call to test for, so "is there a call" cannot tell the two
  /// apart. "Is FaceTime the frontmost app" can: not frontmost means the only reason it is
  /// running is that WE relaunched it for injection, and its camera is our side effect to
  /// undo. Bring FaceTime to the front and this stops touching it entirely.
  ///
  /// WHY A WATCHDOG AND NOT A HOOK. The observation ladder was walked first
  /// (`docs/OBSERVATION_LADDER.md`) and the top two rungs are genuinely closed here:
  ///
  ///   - **Rung 1, a notification: absent.** The dyld cache carries only the
  ///     `AVCaptureVideoPreviewLayer…` family; observing all five of them across three real
  ///     preview restarts produced zero callbacks. AVConference does not post one; its
  ///     pipeline is not `AVCaptureVideoPreviewLayer`.
  ///   - **Rung 2, registering as an additional observer: no such API.**
  ///     `AVConferencePreview` has a single `delegate`, already FaceTime's own
  ///     `TUVideoDeviceControllerProvider`, and `registerBlocksForDelegateNotifications`
  ///     takes no arguments; it is AVConference wiring its own internals.
  ///
  /// That leaves rung 3, a swizzle, and a poll is strictly better than one here: it replaces
  /// no method inside somebody's FaceTime, it cannot recurse against the reconciler, and a
  /// selector that vanishes costs a camera indicator rather than the host. It only runs while
  /// FaceTime is in the background, so the cost when the user is actually using FaceTime is
  /// zero.
  static func keepPreviewOffWhileInactive() {
    for name in [
      NSApplication.didResignActiveNotification,
      NSApplication.didBecomeActiveNotification,
    ] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { activeStateChanged() }
      }
    }
    activeStateChanged()
  }

  private static func activeStateChanged() {
    if NSApplication.shared.isActive {
      // The user is looking at FaceTime. Their camera, their business.
      isWatching = false
    } else if !isWatching {
      isWatching = true
      // Every activation change starts the watch over at its shortest interval: a camera
      // that comes on does so when FaceTime's state changes, which is exactly what these
      // notifications report.
      pollInterval = Self.shortestPollInterval
      quietPolls = 0
      pollWhileInactive()
    }
  }

  /// Checks for a camera FaceTime left running, backing off and then stopping.
  ///
  /// It does not re-arm at a fixed interval for as long as FaceTime is not frontmost, because
  /// that is the NORMAL state: the server relaunches FaceTime precisely in order to inject
  /// into it, and nobody is looking at it afterwards. A fixed two-second poll wakes FaceTime's
  /// main thread thirty times a minute, forever, doing four Objective-C runtime lookups and
  /// two malloc/free pairs each time, in a process that would otherwise be idle enough for
  /// App Nap. The cost that matters is the one paid while nobody is using FaceTime.
  ///
  /// The camera coming on is not a silent event: it happens when FaceTime activates or a
  /// call starts, and `keepPreviewOffWhileInactive` is already observing activation. So the
  /// poll exists only to catch the moments just after one of those, and backing off to
  /// nothing is safe -- an activation change re-arms it at two seconds.
  private static func pollWhileInactive() {
    guard isWatching, !NSApplication.shared.isActive else {
      isWatching = false
      return
    }
    if stopPreviewIfRunning() {
      // Something was running, so stay attentive: a preview that restarts usually restarts
      // soon after.
      pollInterval = Self.shortestPollInterval
      quietPolls = 0
    } else {
      quietPolls += 1
      guard quietPolls < Self.quietPollsBeforeStopping else {
        isWatching = false
        return
      }
      pollInterval = min(pollInterval * 2, Self.longestPollInterval)
    }
    let delay = pollInterval
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { pollWhileInactive() }
    }
  }

  /// One stop, only if something is actually running. Silent on every failure.
  ///
  /// - Returns: whether anything was stopped, which is what decides how soon to look again.
  @discardableResult
  private static func stopPreviewIfRunning() -> Bool {
    guard
      let preview = try? IMCoreRuntime.sharedInstance(
        ofClass: "AVConferencePreview", accessors: ["AVConferencePreviewSingleton"]
      ),
      let owner = try? IMCoreRuntime.send(preview, "delegate"),
      IMCoreRuntime.responds(owner, to: "stopPreview"),
      (try? IMCoreRuntime.bool(owner, "isPreviewRunning")) == true
    else { return false }
    _ = try? IMCoreRuntime.send(owner, "stopPreview")
    BlueBubblesFaceTimeHelper.log.info("Stopped the camera FaceTime restarted in the background")
    return true
  }
}

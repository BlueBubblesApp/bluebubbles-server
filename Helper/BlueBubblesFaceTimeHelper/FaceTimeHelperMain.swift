//  FaceTimeHelperMain
//  What runs when FaceTime.app loads this dylib.
//
//  The sequence (latch, host guard, socket client, deferral to `didFinishLaunching`) and the
//  two absolute rules of the load path are `HelperStartup`'s, shared with the Messages
//  helper. What is particular to FaceTime is here: its dispatch, its log, the event emitter
//  wired before the client connects, and turning off the camera our relaunch turned on.
//
//  Its constructor symbol is `bluebubbles_facetime_helper_main`, DISTINCT from the Messages
//  helper's `bluebubbles_helper_main`, so both dylibs can be linked into one binary (the test
//  bundle) without a duplicate symbol. The two helpers connect to different sockets, one in
//  each app's container (`SocketLocation`).

import BBPrivateAPIContract
import Darwin
import Foundation
import HelperShared

public enum BlueBubblesFaceTimeHelper {

  /// The FaceTime helper's log. Queryable with
  /// `log stream --predicate 'subsystem == "com.bluebubbles.facetimehelper"'`; see
  /// `HelperLog`.
  static let log = HelperLog(subsystem: "com.bluebubbles.facetimehelper")

  /// Called from the dylib constructor. Idempotent.
  public static func start() {
    HelperStartup.start(
      host: HelperHost.faceTime,
      name: "BlueBubbles FaceTime helper",
      log: log,
      // FaceTime events (call status, membership) ride the bridge's `emit`, not the
      // observation ladder; there is no daemon-listener rung here.
      eventRung: { "facetime" },
      dispatch: { try await FaceTimeDispatch.perform($0) },
      describeError: { FaceTimeDispatch.describe($0) },
      startsClient: true,
      onLoad: { client in
        // Wired BEFORE the client connects, so a membership change observed during startup
        // has somewhere to go. `emit` is `@Sendable` and the socket client's `emit` is
        // thread-safe, so this is safe from the delegate's queue.
        FaceTimeBridge.setEmitter { [weak client] event, payload in
          client?.emit(event: event, payload: payload)
        }
      },
      onLaunch: { _ in
        // The camera FaceTime turns on because WE relaunched it. There is no preview to stop
        // while the constructor runs, hence the deferral.
        guard isIdleCameraOffEnabled else {
          log.info("Idle-camera control is switched off; leaving FaceTime's camera alone")
          return
        }
        FaceTimeBridge.stopIdlePreview()
        FaceTimeBridge.keepPreviewOffWhileInactive()
      }
    )
  }

  /// Whether the server asked us to keep FaceTime's camera off while it is in the background.
  ///
  /// From the INJECTION ENVIRONMENT, because that is the only channel readable at load time:
  /// this runs inside FaceTime's sandbox with no reach into the settings store, and the
  /// socket is not connected yet. `PrivateAPIGatedService` reads
  /// `Settings.faceTimeIdleCameraOff` and `PrivateAPIRuntime` sets it on the relaunch, so a
  /// change to the setting re-injects and arrives here.
  ///
  /// **Absent means ON.** A helper injected by an older server, or by hand, should behave the
  /// way the setting defaults rather than leaving somebody's camera running because a variable
  /// was missing.
  private static var isIdleCameraOffEnabled: Bool {
    guard let raw = getenv(HelperEnvironment.faceTimeIdleCameraOff) else { return true }
    return String(cString: raw) != "0"
  }
}

/// The C constructor's target: a DISTINCT symbol from the Messages helper's
/// `bluebubbles_helper_main`, so both dylibs can be linked into one binary (the test bundle)
/// without a duplicate symbol. `HelperBootstrapFaceTime`'s constructor calls this on load.
@_cdecl("bluebubbles_facetime_helper_main")
public func bluebubblesFaceTimeHelperMain() {
  BlueBubblesFaceTimeHelper.start()
}

//  HelperMain
//  What runs when Messages.app loads this dylib.
//
//  The sequence (latch, host guard, socket client, deferral to `didFinishLaunching`) and the
//  two absolute rules of the load path are `HelperStartup`'s, shared with the FaceTime helper.
//  What is particular to Messages is here: its dispatch, its log, and that inbound-event
//  observation registers before the client connects.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Foundation
import HelperShared

/// Owns the helper for the lifetime of the host process.
public enum BlueBubblesHelper {

  /// The Messages helper's log. Queryable with
  /// `log stream --predicate 'subsystem == "com.bluebubbles.helper"'`; see `HelperLog`.
  static let log = HelperLog(subsystem: "com.bluebubbles.helper")

  /// Called from the dylib constructor.
  public static func start() {
    HelperStartup.start(
      host: HelperHost.messages,
      name: "BlueBubbles helper",
      log: log,
      // Read at handshake time: `EventObservation.start()` in `onLaunch` is what decides
      // it, and it runs after the client exists.
      eventRung: { EventObservation.rung },
      dispatch: { try await HelperDispatch.perform($0) },
      describeError: { HelperDispatch.describe($0) },
      // Started in `onLaunch`, after the observation registers.
      startsClient: false,
      onLaunch: { client in
        // `EventObservation.start` synchronously reaches `IMDaemonController`'s shared
        // instance, the singleton that establishes IMCore's connection to imagent, which
        // is why it waits for launch rather than running from the constructor.
        //
        // The two stay in this ORDER: registration before `client.start()`, so the
        // handshake reports the rung this actually reached rather than racing it. The
        // client already exists, so an event observed during startup has somewhere to go.
        //
        // Rung 2 of the observation ladder: an additional handler on IMCore's own daemon
        // listener, no swizzling. A false return is a reportable capability loss, not a
        // startup failure: the helper's outbound actions are unaffected either way.
        let observing = EventObservation.start { event in
          client.emit(event: event.name, payload: WireObject(strings: event.payload))
        }

        client.start()

        log.info(
          "BlueBubbles helper started; inbound events: "
            + (observing ? "rung 2 (daemon listener)" : "unavailable"))
      }
    )
  }
}

/// The C constructor's target. `@_cdecl` so the symbol name is predictable from C.
@_cdecl("bluebubbles_helper_main")
public func bluebubblesHelperMain() {
  BlueBubblesHelper.start()
}

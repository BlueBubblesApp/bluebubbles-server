//  FaceTimeHelperMain
//  What runs when FaceTime.app loads this dylib.
//
//  The FaceTime peer of the Messages helper's `HelperMain`, and it obeys the same two absolute
//  rules of the load path:
//
//    1. **Never block.** This runs before FaceTime.app has finished launching; connect on a
//       background thread and return immediately.
//    2. **Never throw out of the constructor.** An uncaught error here takes FaceTime.app down,
//       and the user has no idea why. A helper that fails to start simply does not run.
//
//  It provides its own `bluebubbles_helper_main` — the SAME symbol the Messages helper
//  provides. That is not a clash: each helper is a separate dylib, so the bootstrap
//  constructor in each resolves the symbol to its own copy. The two helpers connect to the
//  same server socket and are told apart by the bundle id in their registration handshake
//  (`com.apple.FaceTime` here, `com.apple.MobileSMS` there).

import BBPrivateAPIContract
import Darwin
import Foundation
import HelperShared
import os.log

public enum BlueBubblesFaceTimeHelper {

  nonisolated(unsafe) private static var client: HelperSocketClient?
  nonisolated(unsafe) private static var started = false

  static func defaultSocketPath() -> String {
    SocketLocation.privateAPISocket(for: HelperHost.faceTime)
  }

  /// Called from the dylib constructor. Idempotent.
  public static func start() {
    guard !started else { return }
    started = true

    let path = defaultSocketPath()
    let client = HelperSocketClient(
      socketPath: path,
      // Reported in the registration handshake so the server can route FaceTime actions
      // to THIS connection rather than the Messages helper's.
      bundleIdentifier: "com.apple.FaceTime",
      // FaceTime events (call status, membership) ride the bridge's `emit`, not the
      // observation ladder — there is no daemon-listener rung here.
      eventRung: "facetime",
      log: { Logging.log($0) },
      dispatch: { try await FaceTimeDispatch.perform($0) },
      describeError: { FaceTimeDispatch.describe($0) }
    )
    self.client = client

    // Wire the bridge's event emitter to the socket BEFORE connecting, so a membership
    // change observed during startup has somewhere to go. `emit` is `@Sendable` and the
    // socket client's `emit` is thread-safe, so this is safe from the delegate's queue.
    FaceTimeBridge.emit = { [weak client] event, payload in
      client?.emit(event: event, payload: payload)
    }

    client.start()

    Logging.log("BlueBubbles FaceTime helper loaded; server socket: \(path)")
  }

  /// Logging that survives an injected dylib in a sandboxed host — os_log with a real
  /// subsystem, queryable with `log stream --predicate 'subsystem ==
  /// "com.bluebubbles.facetimehelper"'`. `NSLog` reaches only stderr, which a GUI app
  /// launched by `open` has nowhere readable.
  enum Logging {
    private static let log = OSLog(
      subsystem: "com.bluebubbles.facetimehelper", category: "helper"
    )
    static func log(_ message: String) {
      os_log("%{public}@", log: Self.log, type: .default, message)
    }
  }
}

/// The C constructor's target — a DISTINCT symbol from the Messages helper's
/// `bluebubbles_helper_main`, so both dylibs can be linked into one binary (the test bundle)
/// without a duplicate symbol. `HelperBootstrapFaceTime`'s constructor calls this on load.
@_cdecl("bluebubbles_facetime_helper_main")
public func bluebubblesFaceTimeHelperMain() {
  BlueBubblesFaceTimeHelper.start()
}

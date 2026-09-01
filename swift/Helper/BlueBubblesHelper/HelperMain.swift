//  HelperMain
//  What runs when Messages.app loads this dylib.
//
//  This is the entry point, and it runs on Messages.app's load path — before the application
//  has finished starting. Two rules follow from that, and both are absolute:
//
//    1. **Never block.** Anything slow here delays or deadlocks the launch of an application
//       the user is trying to open. Connect on a background queue and return immediately.
//    2. **Never throw out of the constructor.** An uncaught error on the load path takes
//       Messages.app down, and the user has no idea why their Messages stopped working. A
//       helper that fails to start must simply not run.
//
//  See `.claude/docs/private-api.md`.

import BBPrivateAPIContract
import Darwin
import Foundation
import HelperShared
import os.log

/// Owns the helper for the lifetime of the host process.
public enum BlueBubblesHelper {

  /// Retained deliberately: nothing else holds it, and the process it lives in never asks
  /// for it back.
  nonisolated(unsafe) private static var client: HelperSocketClient?
  nonisolated(unsafe) private static var started = false

  /// The socket the server listens on.
  ///
  /// Read from the environment when present so a development server can be pointed at
  /// somewhere else, and otherwise the same default the server computes. Both sides derive
  /// it rather than negotiating, because there is no channel to negotiate over yet.
  /// Delegates to the shared derivation.
  ///
  /// This used to compute the path itself with `FileManager.urls(for:
  /// .applicationSupportDirectory)`, which inside Messages' sandbox resolves to the
  /// CONTAINER — so the helper connected to a path the server had never created. See
  /// SocketLocation.
  static func defaultSocketPath() -> String {
    SocketLocation.privateAPISocket(for: HelperHost.messages)
  }

  /// Called from the dylib constructor.
  public static func start() {
    guard !started else { return }
    started = true

    // The load path is not a place to be clever. Everything below is either
    // non-throwing or wrapped, and the whole body is deliberately short.
    let path = defaultSocketPath()
    let client = HelperSocketClient(
      socketPath: path,
      eventRung: EventObservation.rung,
      log: { message in
        // os_log rather than a file: writing to disk from inside a sandboxed host
        // lands somewhere surprising, as the observation probe discovered, and a
        // helper should not be inventing log locations inside someone else's app.
        Logging.log(message)
      },
      // The shared socket client is host-agnostic; the Messages dispatch is injected
      // here so the transport serves this helper's action set.
      dispatch: { try await HelperDispatch.perform($0) },
      describeError: { HelperDispatch.describe($0) }
    )
    self.client = client
    client.start()

    // Inbound events. Registered AFTER the client so an event observed during startup has
    // somewhere to go — the client queues until it connects, whereas an emit with no
    // client at all is simply dropped.
    //
    // Rung 2 of the observation ladder: an additional handler on IMCore's own daemon
    // listener, no swizzling. A false return is a reportable capability loss, not a
    // startup failure — the helper's outbound actions are unaffected either way.
    let observing = EventObservation.start { event in
      client.emit(event: event.name, payload: event.payload)
    }

    Logging.log(
      "BlueBubbles helper loaded; server socket: \(path); "
        + "inbound events: \(observing ? "rung 2 (daemon listener)" : "unavailable")"
    )
  }

  /// Logging that survives being inside someone else's sandboxed app.
  ///
  /// `NSLog` was the obvious choice and is the wrong one: from an injected dylib it reaches
  /// **stderr and nothing else**. A GUI app launched by `open` has no stderr anywhere a
  /// person can read, so the helper was silent — and its silence was indistinguishable
  /// from not running at all. Measured directly: injecting into `/bin/echo` printed the
  /// line, while `log show` could not find that same line afterwards.
  ///
  /// `os_log` with a real subsystem is queryable:
  ///
  ///     log show --last 5m --predicate 'subsystem == "com.bluebubbles.helper"'
  ///     log stream --predicate 'subsystem == "com.bluebubbles.helper"'
  ///
  /// This matters more here than anywhere else in the project. The helper runs inside a
  /// process we do not own, cannot attach a debugger to without disrupting the user, and
  /// reaches the server only once the very thing being debugged has already worked.
  enum Logging {
    private static let log = OSLog(subsystem: "com.bluebubbles.helper", category: "helper")

    static func log(_ message: String) {
      // `%{public}@` because os_log REDACTS interpolated strings by default — the
      // message would otherwise read `<private>`, which looks like a logging bug and
      // is the default behaviour. Nothing logged here is user content.
      os_log("%{public}@", log: Self.log, type: .default, message)
    }

    static func error(_ message: String) {
      os_log("%{public}@", log: Self.log, type: .error, message)
    }
  }
}

/// The C constructor's target. `@_cdecl` so the symbol name is predictable from C.
@_cdecl("bluebubbles_helper_main")
public func bluebubblesHelperMain() {
  BlueBubblesHelper.start()
}

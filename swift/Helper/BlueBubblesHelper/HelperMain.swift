//  HelperMain
//  What runs when Messages.app loads this dylib.
//
//  This is the entry point, and it runs on Messages.app's load path: before the application
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
import os
import os.log

/// Owns the helper for the lifetime of the host process.
public enum BlueBubblesHelper {

  /// The helper's one connection, retained deliberately (nothing else holds it, and the
  /// process it lives in never asks for it back) and whether `start` has run. Lock-guarded:
  /// the dylib constructor is not on any actor.
  private struct Session: Sendable {
    var client: HelperSocketClient?
    var started = false
  }

  private static let session = OSAllocatedUnfairLock(initialState: Session())

  /// The socket the server listens on.
  ///
  /// Read from the environment when present so a development server can be pointed at
  /// somewhere else, and otherwise the same default the server computes. Both sides derive
  /// it rather than negotiating, because there is no channel to negotiate over yet.
  /// Delegates to the shared derivation.
  ///
  /// Never derive this with `FileManager.urls(for: .applicationSupportDirectory)`: inside
  /// Messages' sandbox that resolves to the CONTAINER, so the helper would connect to a path
  /// the server never created. See `SocketLocation`.
  static func defaultSocketPath() -> String {
    SocketLocation.privateAPISocket(for: HelperHost.messages)
  }

  /// Called from the dylib constructor.
  public static func start() {
    let alreadyStarted = session.withLock { session in
      defer { session.started = true }
      return session.started
    }
    guard !alreadyStarted else { return }

    // Only inside Messages. The constructor also runs in every process that inherits the
    // injection, and in the test bundle that links this helper: none of which should be
    // connecting to the server's socket. See `HelperHostGuard`.
    guard
      HelperHostGuard.shouldRun(
        host: HelperHostGuard.currentHost, expected: HelperHost.messages)
    else {
      Logging.log(
        "BlueBubbles helper loaded into \(HelperHostGuard.currentHost ?? "an unnamed process"); "
          + "not Messages, so doing nothing")
      return
    }

    // The load path is not a place to be clever. Everything below is either
    // non-throwing or wrapped, and the whole body is deliberately short.
    let path = defaultSocketPath()
    let client = HelperSocketClient(
      socketPath: path,
      // Read at handshake time, not now: `EventObservation.start()` below is what decides
      // it, and it has to run after this client exists.
      eventRung: { EventObservation.rung },
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
    session.withLock { $0.client = client }

    // Inbound events. Registered after the client EXISTS, so an event observed during
    // startup has somewhere to go; the client queues until it connects, whereas an emit
    // with no client at all is simply dropped, and before `start()`, so the registration
    // handshake reports the rung this actually reached rather than racing it.
    //
    // Rung 2 of the observation ladder: an additional handler on IMCore's own daemon
    // listener, no swizzling. A false return is a reportable capability loss, not a
    // startup failure: the helper's outbound actions are unaffected either way.
    let observing = EventObservation.start { event in
      client.emit(event: event.name, payload: WireObject(strings: event.payload))
    }

    client.start()

    Logging.log(
      "BlueBubbles helper loaded; server socket: \(path); "
        + "inbound events: \(observing ? "rung 2 (daemon listener)" : "unavailable")"
    )
  }

  /// Logging that survives being inside someone else's sandboxed app.
  ///
  /// `NSLog` was the obvious choice and is the wrong one: from an injected dylib it reaches
  /// **stderr and nothing else**. A GUI app launched by `open` has no stderr anywhere a
  /// person can read, so a helper logging that way is silent: indistinguishable from not
  /// running at all. Measured directly: injecting into `/bin/echo` printed the
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
      // `%{public}@` because os_log REDACTS interpolated strings by default: the
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

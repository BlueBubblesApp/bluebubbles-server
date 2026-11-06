//  HelperStartup
//  What both helpers do when their dylib is loaded, written once.
//
//  This runs on the host app's load path, from a dyld constructor, before the application
//  has finished starting. Two rules follow, and both are absolute:
//
//    1. **Never block.** Anything slow here delays or deadlocks the launch of an application
//       the user is trying to open. The socket client connects on its own thread; anything
//       that touches the host's frameworks waits for `didFinishLaunching` (`onLaunch`).
//    2. **Never throw out of the constructor.** An uncaught error on the load path takes the
//       host down, and the user has no idea why their Messages stopped working. A helper
//       that fails to start must simply not run.
//
//  The sequence is the same for both helpers: a once-per-process latch, the host guard, the
//  socket client, a hook that runs on the load path and one that runs after launch. What
//  differs is passed in, so the two cannot drift: which app, which dispatch, which log, and
//  what each hook does.
//
//  Named `HelperStartup` rather than `HelperBootstrap` because that is the C target holding
//  the constructors that call this.
//
//  See `.claude/docs/private-api.md`.

import AppKit
import BBPrivateAPIContract
import Foundation
import os

public enum HelperStartup {

  /// The hosts a helper has started for in this process, and each one's connection,
  /// retained deliberately: nothing else holds it, and the process it lives in never asks
  /// for it back. Keyed by host because both helpers link into one test binary, where a
  /// single flag would let whichever started first silence the other.
  private struct Session {
    var started: Set<String> = []
    var clients: [String: HelperSocketClient] = [:]
  }

  private static let session = OSAllocatedUnfairLock(initialState: Session())

  /// Starts the helper written for `host`, once per process.
  ///
  /// - Parameters:
  ///   - host: the bundle identifier of the app this helper is for (`HelperHost`). It
  ///     decides the guard, the socket (inside that app's container; see `SocketLocation`)
  ///     and what the registration handshake reports, which is how the server routes each
  ///     action family to the right connection.
  ///   - name: how the log refers to this helper.
  ///   - onLoad: runs on the LOAD PATH, after the client exists and before it connects, for
  ///     wiring that has to be in place before the first frame (an event emitter). It must
  ///     not touch the host's frameworks.
  ///   - onLaunch: runs once the host has finished launching, on the main actor. Anything
  ///     that reaches IMCore or TelephonyUtilities goes here: forcing them from a dyld
  ///     constructor adds their cost to the host's launch and orders their daemon
  ///     connections ahead of wherever the host intended to make them.
  ///   - startsClient: whether the client connects on the load path (FaceTime, whose
  ///     dispatch needs nothing set up first) or `onLaunch` starts it (Messages, whose
  ///     handshake reports an observation rung that `onLaunch` decides).
  public static func start(
    host: String,
    name helperName: String,
    log: HelperLog,
    eventRung: @escaping @Sendable () -> String,
    dispatch: @escaping HelperSocketClient.Dispatch,
    describeError: @escaping HelperSocketClient.DescribeError,
    startsClient: Bool,
    onLoad: (HelperSocketClient) -> Void = { _ in },
    onLaunch: @escaping @MainActor @Sendable (HelperSocketClient) -> Void
  ) {
    let alreadyStarted = session.withLock { !$0.started.insert(host).inserted }
    guard !alreadyStarted else { return }

    // Only inside the app this helper is for. The constructor also runs in every process
    // that inherits the injection, and in the test bundle that links the helpers: none of
    // which should be connecting to the server's socket. See `HelperHostGuard`.
    guard HelperHostGuard.shouldRun(host: HelperHostGuard.currentHost, expected: host) else {
      log.info(
        "\(helperName) loaded into \(HelperHostGuard.currentHost ?? "an unnamed process"); "
          + "not its app, so doing nothing")
      return
    }

    // The load path is not a place to be clever. Everything below is either non-throwing
    // or wrapped, and the whole body is deliberately short.
    let client = HelperSocketClient(
      socketPath: SocketLocation.privateAPISocket(for: host),
      bundleIdentifier: host,
      // Read at handshake time, not now: the Messages helper's rung is decided in
      // `onLaunch`, after this client exists.
      eventRung: eventRung,
      log: { log.info($0) },
      dispatch: dispatch,
      describeError: describeError
    )
    session.withLock { $0.clients[host] = client }

    onLoad(client)
    if startsClient { client.start() }

    // The observer is never removed: the notification fires once per process, and this
    // dylib lives as long as the process does, so there is no token to keep.
    _ = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { onLaunch(client) }
    }

    log.info("\(helperName) loaded; waiting for its app to finish launching")
  }
}

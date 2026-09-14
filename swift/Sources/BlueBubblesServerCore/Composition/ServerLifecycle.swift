//  ServerLifecycle
//  Stopping, starting and replacing the server, as a thing rather than as a method on the
//  container.
//
//  These three verbs are deliberately NOT on `AppContext`, and `requestFullRestart` is why
//  that matters more than tidiness: it calls `execv` and REPLACES THE PROCESS IMAGE. A
//  dependency container that can do that is not a container any more, and its type no longer
//  tells a reader what it is for. `AppContext` stays what its name says (long-lived
//  references, held once) and everything that ACTS on the server as a whole is here.
//
//  Held by `AppContext` and reachable through `ServerControlling`, so the handlers that offer
//  a restart button are unchanged.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBEvents
import BBInterfaces
import BBPushKit
import BBServiceKit
import BBSystem
import Foundation
import Logging

/// Drives the whole server: full stop/start, and process replacement.
///
/// An actor because the registry is one, and because two restarts arriving at once (a remote
/// one through Firebase and a local one from the UI) must not interleave `stopAll` and
/// `startAll`.
public actor ServerLifecycle {

  /// UNOWNED, and this is the second half of a cycle the context thought it had broken.
  ///
  /// `AppContext.registry` is `weak` and its comment explains at length why. `lifecycle` then
  /// rebuilt the identical cycle strongly: context holds lifecycle, lifecycle holds registry,
  /// registry holds the context as its host. Proved with a probe — a bare context is released
  /// at scope exit and a wired one is not — and the cost is not one object: the app builds a
  /// fresh composition on every Start, so each stop-start leaked the context, the event bus,
  /// the socket server, the tool manager, the settings store AND its open database queue,
  /// which is the handle a second start then has to contend with.
  ///
  /// `unowned` rather than `weak` because the registry cannot outlive this: both are owned by
  /// the context, which releases them together. `ServiceGraphLifetimeTests` keeps it honest.
  private unowned let registry: ServiceRegistry<AppContext>
  private let announcer: ServerAddressAnnouncer
  /// Resolved per announcement rather than captured: push is published by its service once
  /// it starts, and withdrawn when it stops.
  private let pushDelivery: @Sendable () async -> PushService?
  /// Where a whole-graph start failure is reported. Optional because a test builds this
  /// without an alert centre; the log line above is unconditional either way.
  private let alerts: (any AlertRaising)?
  private let logger: Logger

  init(
    registry: ServiceRegistry<AppContext>,
    events: EventBus,
    pushDelivery: @escaping @Sendable () async -> PushService?,
    alerts: (any AlertRaising)? = nil,
    logger: Logger
  ) {
    self.registry = registry
    self.announcer = ServerAddressAnnouncer(events: events, logger: logger)
    self.pushDelivery = pushDelivery
    self.alerts = alerts
    self.logger = logger
  }

  /// Announces a new address for this server, to connected clients over the socket and to
  /// the ones that are not connected through Firebase. See `ServerAddressAnnouncer`.
  public func announce(serverAddress: String) async {
    let push = await pushDelivery()
    await announcer.announce(serverAddress) { address in
      // Forced, because this is only reached when the address CHANGED and the publisher's
      // own "unchanged" memory is about what this process wrote, not about what the
      // document says.
      await push?.publish(serverURL: address, force: true)
    }
  }

  /// Stops every service in reverse dependency order and starts them again.
  ///
  /// A remote restart request arrives through Firebase; honouring it means exactly this, and
  /// only the registry can do it in the right order.
  public func restartServices() async {
    logger.warning("Restart requested")
    await registry.stopAll()
    do {
      try await registry.startAll()
    } catch {
      // NOT `try?`. A per-service failure alerts on its own and is supervised; this throw
      // is the whole graph refusing to resolve — a dependency cycle, or a registered
      // service naming one that is absent — and it leaves the server stopped. Swallowing it
      // meant a remote restart could take the server down with nothing in any log and no
      // notification, from a request the user made and cannot see the answer to.
      logger.error(
        "Restart failed; the server is stopped",
        metadata: ["error": .string(String(describing: error))])
      await alerts?.raise(
        UserAlert(
          severity: .critical,
          title: "The server did not come back after a restart",
          body: DiagnosticText.sentence(for: error),
          source: "lifecycle",
          diagnostics: Diagnostics(
            code: "lifecycle.restart_failed",
            domain: "Lifecycle",
            underlyingDescription: String(describing: error)
          ),
          dedupeKey: "lifecycle.restart_failed"
        )
      )
    }
  }

  /// Replaces the process.
  ///
  /// Two mechanisms, and which one applies is a question about what is watching.
  ///
  /// **With the launcher running**, the app records `.restart` and exits, and the launcher
  /// brings it back. That is strictly better than replacing the image in a GUI process: `execv`
  /// keeps the PID but throws away everything AppKit built on top of it, and the new image
  /// inherits a process that LaunchServices, the window server and Background Task Management
  /// still believe is the old one. A clean exit and a fresh launch leaves all three consistent.
  ///
  /// **Without it** (the CLI, a `swift run` build) `execv` is still the right answer, and
  /// for the reason it always was: the new process inherits the same PID, so whatever is
  /// watching keeps watching the same thing. A spawn-then-exit would look like a death to a
  /// supervisor and race it to the restart.
  ///
  /// Services are stopped first either way, so chat.db and the app database close cleanly. If
  /// `execv` returns at all it FAILED, and the fallback is an ordinary service restart:
  /// degraded, but the server stays up.
  public func replaceProcess() async {
    logger.warning("Full restart requested")
    await registry.stopAll()

    // Asked AFTER the services are down, so a restart that hands over to the launcher and one
    // that replaces the image have done exactly the same shutdown.
    if LauncherSupervision.isActive {
      logger.info("Handing the restart to the launcher")
      LauncherContract.writeIntent(.restart)
      // `exit` rather than `NSApplication.terminate`: the services are already stopped, so
      // AppKit's termination sequence would only re-run the shutdown this method just did:
      // through `applicationShouldTerminate`, which parks for up to eight seconds waiting for
      // a server that is no longer running. Nothing needs unwinding; the launcher is watching
      // for the exit and does not care how tidy it was.
      exit(EXIT_SUCCESS)
    }

    // Drop the single-instance lock BEFORE replacing the image. The descriptor is opened
    // close-on-exec so this is redundant on the ordinary path, and it is kept because the
    // failure it prevents is total: an inherited lock makes the replacement refuse to start
    // and report that the server is already running, naming the pid it has just become.
    SingleInstanceLock.release()

    let executable = CommandLine.arguments.first ?? ProcessInfo.processInfo.arguments[0]
    var arguments = CommandLine.arguments.map { strdup($0) }
    arguments.append(nil)
    defer { for argument in arguments where argument != nil { free(argument) } }

    execv(executable, &arguments)

    logger.error(
      "Could not replace the process; restarting services instead",
      metadata: [
        "errno": .stringConvertible(errno)
      ])
    try? await registry.startAll()
  }

  /// Rebuilds the push service from the credentials as they are now.
  ///
  /// Deliberately `restart` rather than `restartWithDependents`: nothing depends on push, and
  /// taking the socket or the tunnel down because someone imported a Firebase key would
  /// disconnect every client mid-setup.
  public func restartPush() async {
    await registry.restart(BuiltInManifests.ID.push)
  }
}

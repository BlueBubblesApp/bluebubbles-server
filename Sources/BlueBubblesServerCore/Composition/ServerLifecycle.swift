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
  /// Where a whole-graph start failure is reported, and what the announcer this builds raises
  /// through. Optional because a test builds this without an alert centre; the log line beside
  /// each use is unconditional either way.
  ///
  /// The centre itself rather than `any AlertRaising`, because the announcer WITHDRAWS an alert
  /// as well as raising one and withdrawal is not on that protocol. Passing the protocol and
  /// downcasting would compile and then silently never withdraw.
  private let alerts: AlertCenter?
  private let logger: Logger

  /// What a scheduled `.process` restart does. Nil is `replaceProcess`; a test passes a
  /// recorder, because the real one ends the process that runs it.
  private let processReplacement: (@Sendable () async -> Void)?

  init(
    registry: ServiceRegistry<AppContext>,
    events: EventBus,
    pushDelivery: @escaping @Sendable () async -> PushService?,
    alerts: AlertCenter? = nil,
    logger: Logger,
    processReplacement: (@Sendable () async -> Void)? = nil
  ) {
    self.registry = registry
    self.announcer = ServerAddressAnnouncer(events: events, alerts: alerts, logger: logger)
    self.pushDelivery = pushDelivery
    self.alerts = alerts
    self.logger = logger
    self.processReplacement = processReplacement
  }

  /// Announces a new address for this server, to connected clients over the socket and to
  /// the ones that are not connected through Firebase. See `ServerAddressAnnouncer`.
  public func announce(serverAddress: String) async {
    let push = await pushDelivery()
    await announcer.announce(serverAddress) { address in
      // Forced, because this is only reached when the address CHANGED and the publisher's
      // own "unchanged" memory is about what this process wrote, not about what the
      // document says.
      //
      // `?? true` is "there is no push service to publish to", which is not a failure and
      // must not be retried: a server with Firebase switched off would otherwise retry for
      // ever and then alert about an outage it does not have. A push service that IS present
      // and failed answers `false`, and that is the one the announcer keeps chasing.
      await push?.publish(serverURL: address, force: true) ?? true
    }
  }

  /// A restart a caller asked for and did not wait on. See `schedule(_:after:)`.
  private let pendingRestart = OwnedTask()
  /// The restart the pending task performs when it next looks. Set by `schedule`, taken by
  /// `performRequested`, so a request arriving while one is pending can change it.
  private var requested: ServerRestart?
  /// The restart the pending task is performing now.
  private var inFlight: ServerRestart?
  /// Set by `stop`. A restart that began after it would start every service again on a
  /// server its owner has shut down.
  private var isStopped = false

  /// Starts `kind` after `delay` and returns without waiting for it.
  ///
  /// Owned here rather than by whoever asked: the restart outlives the request that asked for
  /// it, and stopping the HTTP service is part of it, so a task held by the request would be
  /// held by the thing being torn down. A request that arrives while one is pending JOINS it
  /// rather than starting a second: two interleaved `stopAll`/`startAll` passes are what this
  /// actor exists to prevent.
  ///
  /// Joining must not drop what was asked for, because the route has already answered 200.
  /// A `.process` restart covers a `.services` one (it stops every service too), so the one
  /// request a pending restart does not already cover is a process replacement behind a
  /// services restart: that upgrades the pending restart if it has not begun, and runs after
  /// it if it has. The upgraded restart keeps the pending one's delay.
  public func schedule(_ kind: ServerRestart, after delay: Duration) {
    guard !isStopped else {
      logger.info("The server is stopping; a restart requested now is not scheduled")
      return
    }
    guard requested == nil, inFlight == nil else {
      if kind == .process, requested != .process, inFlight != .process {
        logger.info("A services restart is pending; this request makes it a process restart")
        requested = .process
      } else {
        logger.info("A restart is already pending; this request joins it")
      }
      return
    }
    requested = kind
    pendingRestart.run { [weak self] in
      // Cancelled by `stop` or by this actor's release, and either way there is nothing left
      // to restart.
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      await self.performRequested()
    }
  }

  /// Performs what was requested, and then anything requested while it ran.
  ///
  /// The state is read and cleared on the actor with no suspension between the last check
  /// and the return, so a request is either seen by this loop or finds nothing pending and
  /// starts a task of its own: never stranded between the two.
  private func performRequested() async {
    while let kind = requested, !isStopped {
      requested = nil
      inFlight = kind
      switch kind {
      case .services: await restartServices()
      case .process:
        if let processReplacement {
          await processReplacement()
        } else {
          await replaceProcess()
        }
      }
      inFlight = nil
    }
  }

  /// Ends the scheduled restart, and refuses any requested after it.
  ///
  /// Called by `RunningServer.stop` before the services stop. A restart still waiting out its
  /// delay is cancelled; one already running is waited for, so its `startAll` lands BEFORE the
  /// stop's `stopAll` rather than after it, which would leave every service running on a
  /// server that reports itself stopped.
  public func stop() async {
    isStopped = true
    requested = nil
    await pendingRestart.stop()
  }

  /// Stops every service in reverse dependency order and starts them again.
  ///
  /// A remote restart request arrives through Firebase; honouring it means exactly this, and
  /// only the registry can do it in the right order.
  public func restartServices() async {
    logger.warning("Restart requested")
    await registry.stopAll()
    await startAfterStop()
  }

  /// Starts every service again after `stopAll`, and says so when they will not start.
  ///
  /// NOT `try?`. A per-service failure alerts on its own and is supervised; this throw is the
  /// whole graph refusing to resolve — a dependency cycle, or a registered service naming one
  /// that is absent — and it leaves the server stopped. Swallowing it meant a restart could
  /// take the server down with nothing in any log and no notification, from a request the
  /// user made and cannot see the answer to. Shared by both restarts, because the copy in
  /// `replaceProcess` was the `try?` this replaced.
  private func startAfterStop() async {
    do {
      try await registry.startAll()
    } catch {
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
  /// **Started by the launch agent**, it exits with `LaunchAgentContract.restartExitCode` and
  /// launchd starts it again. That is strictly better than replacing the image in a GUI
  /// process: `execv` keeps the PID but throws away everything AppKit built on top of it, and
  /// the new image inherits a process that LaunchServices, the window server and Background
  /// Task Management still believe is the old one. A clean exit and a fresh launch leaves all
  /// three consistent.
  ///
  /// **Otherwise** (the CLI, a `swift run` build, a copy run with its own command line)
  /// `execv` is still the right answer: the new process inherits the same PID, so whatever is
  /// watching keeps watching the same thing. A spawn-then-exit would look like a death to a
  /// supervisor and race it to the restart.
  ///
  /// Services are stopped first either way, so chat.db and the app database close cleanly. If
  /// `execv` returns at all it FAILED, and the fallback is an ordinary service restart:
  /// degraded, but the server stays up.
  public func replaceProcess() async {
    logger.warning("Full restart requested")
    await registry.stopAll()

    // Asked AFTER the services are down, so a restart that hands over to launchd and one that
    // replaces the image have done exactly the same shutdown.
    if LaunchAgentContract.isAgentProcess() {
      logger.info("Handing the restart to launchd")
      // `exit` rather than `NSApplication.terminate`: the services are already stopped, so
      // AppKit's termination sequence would only re-run the shutdown this method just did:
      // through `applicationShouldTerminate`, which parks for up to eight seconds waiting for
      // a server that is no longer running. The status is what makes launchd start it again;
      // a 0 here would read as a quit and leave it down.
      exit(LaunchAgentContract.restartExitCode)
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
    await startAfterStop()
  }

  /// Rebuilds the push service from the credentials as they are now.
  ///
  /// Push alone, not its dependents: nothing depends on push, and taking the socket or the
  /// tunnel down because someone imported a Firebase key would disconnect every client
  /// mid-setup.
  public func restartPush() async {
    await registry.restart(BuiltInManifests.ID.push)
  }
}

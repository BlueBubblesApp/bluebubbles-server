//  TailscaleTunnel
//  Tailscale, run as this server's own userspace node and published through Serve or Funnel.
//
//  The other binary tunnels are handed a credential and print a URL. Tailscale is neither of
//  those things. It is a daemon that has to be SIGNED IN (with an auth key, or by a person
//  opening a link in a browser) and once signed in it publishes nothing until told to
//  `serve`, and `serve` over HTTPS needs a certificate feature the tailnet's owner has to
//  switch on once, and Funnel needs a second one. Every one of those steps can be pending on
//  somebody who is not at this Mac, and the daemon has to stay up while they are, because
//  restarting it invalidates the very link they were sent.
//
//  So `connect()` does as little as it can inline: it starts the daemon, and if the node is
//  already signed in it applies the serve configuration and returns the address. Anything
//  slower (signing in, waiting on a person, a feature the tailnet has yet to grant) throws
//  `ProxyError.pending` and carries on in the background, reporting each step through
//  `ProxyObserver.attentionRequired` and the address through `addressChanged` when it has
//  one. `ProxyCoordinator` treats `pending` as "not yet" rather than "failed", which keeps
//  the registry from restarting the service into a fresh daemon with a fresh, different
//  sign-in link, and keeps a slow first start from holding every service behind it.
//
//  Two choices about HOW the daemon runs are the whole reason this works without root:
//    - `--tun=userspace-networking`. On macOS `tailscaled` refuses to start as a normal user
//      unless it is told not to touch the kernel; in userspace mode it needs no TUN device,
//      no system extension and no administrator. Serve and Funnel terminate inside the
//      daemon and forward to loopback, which is exactly a userspace node's job.
//    - Its own state directory and socket. A person who already runs the Tailscale app
//      keeps it: this is a second node on their tailnet, named for this server, and the
//      two never share a socket, a key or a preference.
//
//  See `.claude/docs/performance.md`.

import BBCore
import BBServiceKit
import Foundation
import Logging

/// A Tailscale node, run and published by this server.
public actor TailscaleTunnel: ProxyProviding {

  public nonisolated let identifier = ServiceIdentifier("app.bluebubbles.proxy.tailscale")

  private let daemon: DaemonProcess
  private let cli: TailscaleCLI
  private let options: TailscaleOptions
  private let port: Int
  private let logger: Logger
  private let restartDelay: Duration

  private var address: String?
  private var observer: ProxyObserver?
  /// The background work: bringing the node up, waiting on a person, or watching a running
  /// node. One at a time, identified by generation; see `startBackground`.
  private var background: Task<Void, Never>?
  private var backgroundGeneration = 0
  /// What the person was last told, so they are told once rather than every poll.
  private var lastAttention: TailscaleAttention?
  /// Whether the preferences in `options` have been applied to a signed-in node. Once per
  /// provider: a settings change makes a new provider, so a change is applied exactly once
  /// rather than on every poll.
  private var hasAppliedPreferences = false
  /// Whether the configured auth key has been refused. Once it has, sign-in falls back to
  /// the browser link rather than presenting the same key every poll.
  private var authKeyWasRejected = false
  private var isDisconnecting = false
  /// Whether `connect()` is between starting the daemon and returning, and whether the
  /// daemon died in that window. The same pair `BinaryTunnel` keeps: an exit during the
  /// inline phase is recorded rather than acted on, because acting on it would start a
  /// restart loop behind a `connect()` that then stops the daemon the loop just brought
  /// back and throws without cancelling it.
  private var isConnecting = false
  private var exitedDuringConnect = false

  /// How often to ask the daemon whether the pending step has been taken.
  static let waitingPollInterval: Duration = .seconds(5)
  /// How often to check that a running node is still signed in and still named the same.
  static let monitorInterval: Duration = .seconds(120)

  public init(
    daemonExecutablePath: String,
    cliExecutablePath: String,
    port: Int,
    options: TailscaleOptions,
    logger: Logger = Logger(label: "bluebubbles.proxy.tailscale")
  ) {
    let configuration = DaemonConfiguration(
      name: "tailscaled",
      executablePath: daemonExecutablePath,
      arguments: options.daemonArguments
    )
    self.daemon = DaemonProcess(configuration: configuration, logger: logger)
    self.cli = TailscaleCLI(
      executablePath: cliExecutablePath, socketPath: options.socketPath, logger: logger
    )
    self.options = options
    self.port = port
    self.logger = logger
    self.restartDelay = configuration.restartDelay
  }

  public var currentAddress: String? { address }

  public func observe(_ observer: ProxyObserver) async {
    self.observer = observer
  }

  public func connect() async throws -> String {
    guard options.isFunnelPortAllowed else {
      throw ProxyError.tunnelFailed(
        reason: TailscaleError.funnelPortNotAllowed(port: options.httpsPort).message)
    }

    isDisconnecting = false
    isConnecting = true
    exitedDuringConnect = false
    defer { isConnecting = false }
    lastAttention = nil
    hasAppliedPreferences = false
    authKeyWasRejected = false
    await daemon.onTermination { [weak self] code in
      await self?.handleUnexpectedExit(code: code)
    }

    do {
      try await daemon.start()
      try await cli.waitUntilResponsive(timeout: .seconds(30))
    } catch let error as DaemonError {
      throw ProxyError.tunnelFailed(reason: BinaryTunnel.describe(error))
    } catch let error as TailscaleError {
      await daemon.stop()
      throw ProxyError.tunnelFailed(reason: error.message)
    }

    // Inline only what is quick: a node that is already signed in gets its serve
    // configuration applied and its address returned. Signing in, or anything a person
    // has to do, moves to the background: the registry starts services one after
    // another, and a first start that waits a minute for a browser holds every service
    // behind it.
    let status = try await quickStatus()
    if status.isRunning, !Self.needsPerson(status) {
      do {
        switch try await establish() {
        case .ready(let url):
          address = url
          // It may ALREADY be dead: printed its address and exited a moment later. The
          // exit was recorded rather than acted on while this ran; acted on here, once
          // the address is settled, the way `BinaryTunnel` does.
          if consumeExitDuringConnect() {
            startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: true) }
          } else {
            startBackground { tunnel in await tunnel.monitorLoop() }
          }
          return url
        case .waiting(let attention):
          startBackground { tunnel in
            await tunnel.waitLoop(restartingDaemon: await tunnel.consumeExitDuringConnect())
          }
          throw ProxyError.pending(reason: attention.notice.summary)
        case .startingUp:
          startBackground { tunnel in
            await tunnel.waitLoop(restartingDaemon: await tunnel.consumeExitDuringConnect())
          }
          throw ProxyError.pending(reason: "waiting for Tailscale to finish starting")
        }
      } catch let error as TailscaleError {
        await daemon.stop()
        throw ProxyError.tunnelFailed(reason: error.message)
      }
    }

    startBackground { tunnel in
      await tunnel.waitLoop(restartingDaemon: await tunnel.consumeExitDuringConnect())
    }
    // `Starting` is a signed-in node still coming up (what a normal restart shows for a
    // few seconds) and is reported as that rather than as a sign-in that is not needed.
    throw ProxyError.pending(
      reason: status.needsLogin || status.backendState == "NoState"
        ? "signing in to Tailscale"
        : "waiting for Tailscale to finish starting"
    )
  }

  /// Reads and clears the "it died while connect was running" flag.
  private func consumeExitDuringConnect() -> Bool {
    defer { exitedDuringConnect = false }
    return exitedDuringConnect
  }

  public func disconnect() async {
    isDisconnecting = true
    cancelBackground()
    await daemon.stop()
    address = nil
    lastAttention = nil
  }

  // MARK: - Bringing the node up

  private enum Outcome {
    case ready(String)
    case waiting(TailscaleAttention)
    /// The daemon is between states (`NoState` before the backend starts, `Starting`
    /// while it connects) and nobody has to do anything but ask again shortly.
    case startingUp(state: String)
  }

  /// The daemon's state, or a failure converted for `connect()`.
  private func quickStatus() async throws -> TailscaleStatus {
    do {
      return try await cli.status()
    } catch let error as TailscaleError {
      await daemon.stop()
      throw ProxyError.tunnelFailed(reason: error.message)
    }
  }

  /// Whether a status is one only a person can move on from.
  private static func needsPerson(_ status: TailscaleStatus) -> Bool {
    status.needsMachineAuth || (status.needsLogin && status.authURL != nil)
  }

  /// One pass at getting from "daemon running" to "address published", stopping at the
  /// first step that needs a person.
  private func establish() async throws -> Outcome {
    var status = try await cli.status()

    if status.needsMachineAuth {
      return .waiting(await report(.deviceApprovalRequired))
    }

    // `up` is run when the node is not signed in and has no link to offer yet, and once on
    // a signed-in node to apply the preferences (the machine name and control server)
    // so a change to them takes effect after the restart that follows a settings change.
    // NOT on every poll of a node that already has its link: that would present the same
    // link, or the same refused key, every five seconds.
    let signedOut = !status.isRunning
    let needsUp = signedOut ? status.authURL == nil : !hasAppliedPreferences
    var appliedNow = false
    if needsUp {
      let key: String? = signedOut && !authKeyWasRejected ? options.authKey : nil
      do {
        status = try await cli.up(options: options, authKey: key)
      } catch TailscaleError.invalidAuthKey(let output) {
        // Reported once, then the browser link is offered instead. The key stays as it
        // is on the settings page; a new provider is made when it changes.
        authKeyWasRejected = true
        _ = await report(.authKeyRejected(detail: output))
        status = try await cli.up(options: options, authKey: nil)
      }
      if status.isRunning {
        hasAppliedPreferences = true
        appliedNow = true
      }
    }

    if status.needsMachineAuth {
      return .waiting(await report(.deviceApprovalRequired))
    }
    if !status.isRunning {
      if let link = status.authURL {
        return .waiting(await report(.signInRequired(link)))
      }
      // A daemon that has just been (re)started answers `NoState` until its backend is
      // up and `Starting` until control has answered; `up` has asked it to get there.
      // That is not a failure to report; it is a reason to look again in a moment.
      if status.isTransitional {
        return .startingUp(state: status.backendState)
      }
      throw TailscaleError.commandFailed(
        command: "up",
        output: "the node is \(status.backendState) and Tailscale offered no sign-in link"
      )
    }

    // The preferences were just applied, so the DNS name may still be the previous one.
    // Waited for here, before anything is published, rather than left to the monitor to
    // correct two minutes later.
    if appliedNow,
      !TailscaleCLI.machineName(status.assignedMachineName, matches: options.hostname)
    {
      status = try await cli.waitForMachineName(options.hostname)
    }

    switch try await cli.configureServe(options: options, forwardingTo: port) {
    case .applied:
      break
    case .featureMissing(let after, let link):
      if !after.hasHTTPS {
        return .waiting(await report(.httpsNotEnabled(link: link)))
      }
      return .waiting(await report(.funnelNotEnabled(link: link)))
    }

    guard let dnsName = status.dnsName else { throw TailscaleError.noMagicDNSName }
    lastAttention = nil
    return .ready(options.publishedAddress(dnsName: dnsName))
  }

  /// Tells the person once per distinct step.
  private func report(_ attention: TailscaleAttention) async -> TailscaleAttention {
    if lastAttention != attention {
      lastAttention = attention
      await observer?.attentionRequired(attention.notice)
    }
    return attention
  }

  // MARK: - Background work

  /// Starts the one background task, replacing whatever was running.
  ///
  /// Generations rather than a bare handle, because a cancelled task's clean-up runs
  /// LATER, on its own schedule: a `defer { background = nil }` in a task that was just
  /// replaced would clear the replacement's handle, leaving it running untracked where
  /// `disconnect()` could not reach it and a second crash would start a third loop beside
  /// it. A task only clears the handle if the generation is still its own.
  private func startBackground(_ work: @escaping @Sendable (TailscaleTunnel) async -> Void) {
    cancelBackground()
    backgroundGeneration += 1
    let generation = backgroundGeneration
    background = Task { [weak self] in
      guard let self else { return }
      await work(self)
      await self.finishBackground(generation: generation)
    }
  }

  private func cancelBackground() {
    background?.cancel()
    background = nil
  }

  private func finishBackground(generation: Int) {
    if generation == backgroundGeneration { background = nil }
  }

  /// Brings the daemon back if it died, then polls until the address can be published.
  private func waitLoop(restartingDaemon: Bool) async {
    if restartingDaemon {
      guard await restartDaemon() else { return }
    }

    var consecutiveFailures = 0
    while !Task.isCancelled, !isDisconnecting {
      do {
        switch try await establish() {
        case .ready(let url):
          address = url
          logger.info("Tailscale is publishing this server")
          await observer?.addressChanged(url)
          if !Task.isCancelled { await monitorLoop() }
          return
        case .waiting:
          consecutiveFailures = 0
        case .startingUp(let state):
          consecutiveFailures = 0
          logger.debug("Tailscale is still starting", metadata: ["state": .string(state)])
        }
      } catch {
        consecutiveFailures += 1
        logger.warning(
          "Tailscale setup did not complete yet",
          metadata: ["reason": .string(String(describing: error))])
      }
      // Slower after repeated errors, so a daemon that keeps refusing a command does not
      // fill the log twelve times a minute.
      let interval = consecutiveFailures > 3 ? Self.monitorInterval : Self.waitingPollInterval
      try? await Task.sleep(for: interval)
    }
  }

  /// Restarts a dead daemon within the budget. False when the budget is spent, or the
  /// task was cancelled meanwhile.
  ///
  /// The same budget `BinaryTunnel` spends: a daemon that dies once a day is retried
  /// forever, one that cannot start at all gives up after ten tries. A daemon that starts
  /// and never answers on its socket is STOPPED before the next try, so each slot spent is
  /// a real restart rather than `start()` returning early on a process that still exists.
  private func restartDaemon() async -> Bool {
    while !Task.isCancelled, !isDisconnecting {
      guard await daemon.shouldRestart() else {
        let reason =
          "The Tailscale daemon exited repeatedly, or kept starting without answering, and "
          + "will not be restarted again. Check the server log for what it printed."
        logger.error("Giving up on the tunnel", metadata: ["kind": .string("tailscale")])
        await observer?.failed(reason)
        return false
      }
      try? await Task.sleep(for: restartDelay)
      if Task.isCancelled || isDisconnecting { return false }
      do {
        try await daemon.start()
        try await cli.waitUntilResponsive(timeout: .seconds(30))
        return true
      } catch {
        // A daemon that launched and then died reaches `handleUnexpectedExit`, which
        // replaces this task; one that would not launch, or launched and never answered,
        // is retried here against the same budget.
        logger.warning(
          "The Tailscale daemon did not come back yet",
          metadata: ["reason": .string(String(describing: error))])
        await daemon.stop()
      }
    }
    return false
  }

  /// Watches a running node for the two things that silently take it down: a node key that
  /// expired (the state drops to `NeedsLogin`), and a rename on the tailnet.
  private func monitorLoop() async {
    while !Task.isCancelled, !isDisconnecting {
      try? await Task.sleep(for: Self.monitorInterval)
      if Task.isCancelled || isDisconnecting { return }
      guard let status = try? await cli.status() else { continue }

      if !status.isRunning {
        logger.warning(
          "The Tailscale node is no longer running",
          metadata: ["state": .string(status.backendState)])
        address = nil
        hasAppliedPreferences = false
        startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: false) }
        return
      }
      if let dnsName = status.dnsName {
        let expected = options.publishedAddress(dnsName: dnsName)
        if expected != address {
          logger.info("This Mac's Tailscale name changed; republishing")
          address = expected
          await observer?.addressChanged(expected)
        }
      }
    }
  }

  /// The daemon died without being asked to.
  private func handleUnexpectedExit(code: Int32) async {
    guard !isDisconnecting else { return }
    logger.warning(
      "The Tailscale daemon exited on its own",
      metadata: ["code": .stringConvertible(code)])
    address = nil
    await observer?.disconnected("the Tailscale daemon exited with code \(code)")
    hasAppliedPreferences = false
    // `connect()` is mid-flight and owns the daemon until it returns. Recorded; it picks
    // this up once its own inline work is settled, or fails on the dead socket and stops.
    guard !isConnecting else {
      exitedDuringConnect = true
      return
    }
    startBackground { tunnel in await tunnel.waitLoop(restartingDaemon: true) }
  }
}

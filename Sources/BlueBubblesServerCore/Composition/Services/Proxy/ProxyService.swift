//  ProxyServices
//  One service per connection method, in an exclusive category.
//
//  An enum of connection methods could not say the things the model needs it to say: that
//  these six are the same KIND of thing, that only one may run at a time, that four of them
//  run a program and two do not, or that each has its own configuration. Most importantly it
//  could not be EXTENDED: a third-party tunnel cannot add a case to an enum compiled into
//  this binary, so "plugins" could never include a connection method.
//
//  As six services in an exclusive category, all of that falls out: the registry starts them
//  all, five decline through `canRun`, and the validator reports it if two are somehow enabled
//  at once. Selection is "which service in this category is enabled", which is a question a
//  plugin can answer about itself.
//
//  The shared behaviour lives in `ProxyService<Method>` and each method supplies only a
//  manifest and a provider, deliberately thin, because that pair is the shape a plugin will
//  have.
//
//  It is a GENERIC over a descriptor rather than a base class with overrides, and the
//  difference is not stylistic. An abstract `class var manifest` has to trap when nobody
//  overrides it, so "forgot to override" is a crash at start-up instead of a compile error,
//  and a plugin author is exactly the person who will forget. It also forced every subclass to
//  restate `@unchecked Sendable`, because a non-final class cannot be checked.
//
//  It also has a trap this shape makes unrepresentable: a scope built in a protocol
//  extension resolves `Self.manifest` STATICALLY, against the type that declared the
//  conformance (the abstract base) so every connection method reaching for a core setting
//  crashes at launch. `ProxyHost` carries the manifest as a stored property and
//  `Method.manifest` is a static requirement, so there is no `Self` left to bind wrongly.
//
//  See `.claude/docs/architecture.md` and `docs/EVENTS.md`.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBInterfaces
import BBProxy
import BBServiceKit
import BBSettings
import BBSystem
import BBTooling
import Foundation
import Logging

/// What a connection method supplies. Everything else is `ProxyService`.
///
/// A protocol with two static requirements rather than a class to subclass: a method that
/// forgets one does not compile, where a missing override on a base class traps at start-up.
protocol ProxyMethod: Sendable {
  static var manifest: ServiceManifest { get }

  /// Builds this method's provider, or says why it cannot; see `ProxyStart`.
  static func makeProvider(_ host: ProxyHost) async -> ProxyStart

  /// How fast to try again while the provider's own end is failing. Every method uses
  /// `ProxyRetryPace.standard`; a test supplies a faster one.
  static var retryPace: ProxyRetryPace { get }
}

extension ProxyMethod {
  static var retryPace: ProxyRetryPace { .standard }
}

/// The waits between attempts while a provider is failing: fast while an outage might be a
/// blip, then `steady` for as long as the method is selected.
struct ProxyRetryPace: Sendable {
  let fast: [Duration]
  let steady: Duration

  /// Five minutes once the fast waits are spent: the pace a running tunnel keeps when its
  /// daemon will not stay up (`DaemonConfiguration.dormantRestartDelay`), so a provider
  /// outage is retried alike whether it began before the tunnel first connected or after.
  static let standard = ProxyRetryPace(
    fast: [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(120)],
    steady: .seconds(300))

  var schedule: RetrySchedule { .delays(fast, thenEvery: steady) }
}

/// What a connection method's `makeProvider` decided, and so whether this server tries again.
///
/// Two ways to fail, because they need opposite answers:
///
///   - **Something only a person can fix**: the binary is missing, a token is empty or was
///     rejected, a file cannot be read. Retrying re-raises the same alert and fixes nothing.
///     What does fix it restarts the method on its own: an edit to its settings restarts the
///     service, and a program arriving is followed (`ToolWait`), because installing one
///     writes no setting.
///   - **The provider's own end failed**: zrok's API could not be reached or answered with
///     an error, a tunnel could not connect. Nothing on this Mac is wrong, so this server
///     keeps trying for as long as the method is selected, and comes back when the provider
///     does. The registry's restart budget cannot do this: it ends, and an outage longer
///     than the budget would leave the server unreachable until somebody restarted it.
///
/// Only `.ready` is constructed by a method. Both failures are built by `ProxyHost`, whose
/// doors log and alert as each case needs, so a method cannot decline in silence.
struct ProxyStart: Sendable {
  fileprivate enum Kind: Sendable {
    case ready(any ProxyProviding)
    /// `awaiting` is set when what the person has to do is give this method a program, so
    /// `ProxyService` can try again the moment one appears rather than waiting for an edit
    /// that installing a program never makes.
    case needsPerson(reason: String, awaiting: ToolWait?)
    case providerUnavailable(reason: String, detail: String)
  }

  /// A refusal that a program appearing would answer, and the notice to withdraw when it does.
  struct ToolWait: Sendable, Equatable {
    enum Need: Sendable, Equatable {
      /// The method's declared program itself.
      case executable
      /// A companion that ships beside it, such as Tailscale's `tailscale` beside `tailscaled`.
      case companion(String)
    }

    let need: Need
    let alertKey: String
  }

  fileprivate let kind: Kind

  static func ready(_ provider: any ProxyProviding) -> ProxyStart {
    ProxyStart(kind: .ready(provider))
  }
}

/// What a method is handed to build its provider with.
///
/// The shared helpers are on a value passed IN rather than inherited, which is what lets
/// `makeProvider` be a static on an enum: a method is data plus one function, with no
/// instance and nothing to override.
struct ProxyHost: Sendable {

  /// This service's scoped settings, resolved against the METHOD's manifest.
  ///
  /// Correct by construction: the manifest is a stored property of this value, so there is
  /// no `Self` to bind to the wrong type. See the file header.
  let scoped: ScopedSettings
  let alerts: AlertCenter
  let logger: Logger
  let tools: ToolManager
  /// What a daemon-backed provider records its process to. Passed to every `Tunnels`
  /// factory, which takes no default; see `ServerComposition.SharedServices.daemonLedger`.
  let daemonLedger: DaemonLedger
  let manifest: ServiceManifest
  /// What the method last wrote to each of its own fields; see `writeOwn`.
  let ownWrites: Locked<[String: String]>

  /// This service's own setting, read from its namespace.
  ///
  /// No entitlement needed and none possible to forget: ownership is the key's prefix, so a
  /// method physically cannot reach another's field through this.
  func own(_ field: String) async -> String { await scoped.own(field) }

  func ownFlag(_ field: String) async -> Bool { await scoped.ownFlag(field) }

  /// Stores one of this method's own fields, as the METHOD rather than as a person.
  ///
  /// `ProxyService.apply` restarts on a change to any field it watches, which is right for
  /// an edit and wrong for a value the running method just stored itself: zrok saving the
  /// token of the share it reserved restarted the tunnel while it was still starting. The
  /// value is recorded BEFORE the write, because the change is announced during it, and
  /// `apply` skips a field whose stored value is the one recorded here. A different value
  /// pasted into the same field later is still a person's edit, and still restarts.
  func writeOwn(_ value: String, field: String) async throws {
    ownWrites.withLock { $0[field] = value }
    try await scoped.setOwn(value, field: field)
  }

  /// This service's own setting, or a fallback when it has never been written.
  ///
  /// `seedDefaults` fills a `select` in on first run, so this normally returns the stored
  /// value. It matters on the upgrade path: a field added to a manifest that a user already
  /// has configuration for is unset until the next seed, and an empty string passed on to
  /// cloudflared as `--protocol ''` is worse than the default it was meant to be.
  func ownOrDefault(_ field: String, _ fallback: String) async -> String {
    let value = await own(field).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? fallback : value
  }

  /// The executable for this connection method's declared program.
  ///
  /// One line at each call site, and the resolution behind it (a binary the user pointed at,
  /// then the managed install, then whatever the app bundle happens to ship) is the same for
  /// every service that declares a tool, including one we did not write. That is the whole
  /// reason the tool is declared in the manifest rather than looked up by name here: a
  /// third-party connection method gets this by declaring, not by shipping code.
  func toolExecutable() async -> String? {
    guard let tool = manifest.tools.first else { return nil }
    return await tools.executablePath(for: tool.id)
  }

  /// One of the declared program's companion executables (the CLI that ships beside a
  /// daemon) resolved by the same tool manager, from the same install.
  func companionExecutable(named name: String) async -> String? {
    guard let tool = manifest.tools.first else { return nil }
    return await tools.companionExecutablePath(for: tool.id, named: name)
  }

  /// The port to forward to: a CORE setting, so it goes through the scope and every
  /// connection method has to declare `.readSettings(keys: ["socket_port"])` for it. They all
  /// do; the declaration is what makes that visible on their permissions list.
  func forwardedPort() async -> Int {
    await scoped.valueOrDefault(Settings.socketPort)
  }

  /// Whether the local server speaks TLS, so the tunnel forwards to `https://` rather than
  /// into a port that will not answer in plaintext. A core setting, declared by each method
  /// that reads it, like `socket_port`.
  func originUsesTLS() async -> Bool {
    await scoped.valueOrDefault(Settings.useCustomCertificate)
  }

  /// Declines to start for a reason only a person can fix, and tells them. Not retried.
  ///
  /// **The body must NEVER quote a credential.** An alert is shown on screen, written to the
  /// log and carried in a diagnostic report, which is three more places than a token belongs.
  func needsAttention(title: String, body: String, key: String) async -> ProxyStart {
    await raiseAttention(title: title, body: body, key: key)
    return ProxyStart(kind: .needsPerson(reason: title, awaiting: nil))
  }

  /// Declines because a companion program that ships beside this method's own is missing.
  /// Not retried on a timer, but tried again the moment the tool manager has the companion,
  /// which a reinstall gives it.
  func companionMissing(
    _ name: String, title: String, body: String, key: String
  ) async -> ProxyStart {
    await raiseAttention(title: title, body: body, key: key)
    return ProxyStart(
      kind: .needsPerson(
        reason: title,
        awaiting: ProxyStart.ToolWait(need: .companion(name), alertKey: attentionKey(key))))
  }

  private func attentionKey(_ key: String) -> String { "proxy.\(manifest.id.rawValue).\(key)" }

  private func raiseAttention(title: String, body: String, key: String) async {
    // The log names which check refused, by key; the sentence is the alert's, and a log
    // line is no place for whatever the person typed into the field it names.
    logger.warning(
      "Connection method cannot start",
      metadata: [
        "connectionMethod": .string(manifest.id.rawValue),
        "reason": .string(key),
      ])
    await alerts.raise(
      UserAlert(
        severity: .warning,
        title: title,
        body: body,
        source: "Connection",
        actions: [.openSettings(.settings)],
        dedupeKey: attentionKey(key)
      )
    )
  }

  /// Declines because this method's program is not installed. Not retried on a timer, but
  /// tried again the moment the tool manager has a program: installed from the app or the
  /// API, found by a scan, or a binary the person pointed at.
  ///
  /// The remedy travels with the problem: the program is a managed tool, so the alert offers
  /// to install it rather than describing a state and leaving the user to find the button.
  /// Cloudflare is the DEFAULT method, so a missing binary that said nothing would leave a
  /// connection method selected and a server nobody can reach.
  func toolMissing() async -> ProxyStart {
    let name = manifest.name
    logger.error(
      "The selected connection method has no usable binary",
      metadata: ["connectionMethod": .string(manifest.id.rawValue)]
    )
    let body: String
    let actions: [AlertAction]
    if let tool = manifest.tools.first {
      body =
        "\(name) needs the \(tool.displayName) program, which is not installed "
        + "on this Mac, so no address is being published. Install it and the "
        + "tunnel starts on its own."
      actions = [.installTool(id: tool.id)]
    } else {
      body =
        "This server cannot start \(name) because its program is not installed, "
        + "so no address is being published. Choose a different connection method, "
        + "or install the program and restart."
      actions = [.openSettings(.settings)]
    }
    await alerts.raise(
      UserAlert(
        severity: .error,
        title: "\(name) is selected but not installed",
        body: body,
        source: "Connection",
        actions: actions,
        dedupeKey: Self.toolMissingKey(manifest.id),
        // Re-checked at every start, so the fresh answer replaces this one rather than
        // sitting behind it.
        isDurable: false
      )
    )
    return ProxyStart(
      kind: .needsPerson(
        reason: "\(name) is not installed",
        awaiting: ProxyStart.ToolWait(need: .executable, alertKey: Self.toolMissingKey(manifest.id))
      ))
  }

  static func toolMissingKey(_ id: ServiceIdentifier) -> String {
    "proxy.binary-missing.\(id.rawValue)"
  }

  /// Declines because the provider's own end failed. Retried by `ProxyService` until it
  /// recovers; see `ProxyStart`.
  ///
  /// Logged, not alerted: most outages are over within a retry or two, and a notice for each
  /// one would teach people to ignore the notice. `ProxyService` raises one if the fast
  /// retries are spent.
  ///
  /// - Parameters:
  ///   - reason: one line for the connection row, such as "zrok could not be reached".
  ///   - detail: what the provider said, for the notice raised if the outage lasts. Never a
  ///     credential, for the reason `needsAttention` gives.
  func providerUnavailable(_ reason: String, detail: String) -> ProxyStart {
    logger.warning(
      "The connection method's provider is unavailable; retrying",
      metadata: ["connectionMethod": .string(manifest.id.rawValue)])
    return ProxyStart(kind: .providerUnavailable(reason: reason, detail: detail))
  }
}

/// One connection method, running. Generic over the method so there is nothing to override.
actor ProxyService<Method: ProxyMethod>: Service, ConfigurableService,
  GatedService
{

  static var manifest: ServiceManifest { Method.manifest }

  /// The manifest's own fields and declared reads, plus the selection.
  ///
  /// `connection_method` is added here rather than declared by each method because it is
  /// THIS generic that reads it, in `canRun`: a method's manifest describes the method. It
  /// is what lets switching connection method stop the one that was running.
  static var watchedSettings: Set<String> {
    manifestWatchedSettings.union([Settings.connectionMethod.key])
  }

  /// For a start that throws, which a provider failure does not: `start` retries those itself,
  /// for as long as the method is selected (see `ProxyStart`), because this budget ends. One
  /// tunnel failing must never take the application down.
  static var restartPolicy: RestartPolicy {
    .backoff(base: .seconds(5), max: .seconds(120), attempts: 10)
  }

  /// What a connection method touches, rather than the container that holds it.
  typealias Host = any ScopedSettingsProviding & AlertProviding & LoggerProviding & ToolProviding
    & DaemonLedgerProviding & ClientActivityProviding & HealthChangeReporting
    & NetworkPathProviding

  private let scoped: ScopedSettings
  private let alerts: AlertCenter
  private let logger: Logger
  private let tools: ToolManager
  private let daemonLedger: DaemonLedger
  private let reportHealth: @Sendable () async -> Void
  let coordinator: ProxyCoordinator
  /// Shared with every `ProxyHost` this service hands out; see `ProxyHost.writeOwn`.
  private let ownWrites = Locked<[String: String]>([:])

  /// Why the method is not running when no tunnel is up to say so: what `start` was last
  /// told, cleared when it gets a provider.
  private var declined: Declined?
  /// Retries a start the provider's own end refused. Owned, so `stop` ends it.
  private let retry = OwnedTask()
  /// Waits for the program a refused start was missing (`awaitTool`), or, while the method
  /// runs, for that program to be replaced (`followToolUpdates`).
  private let toolWatch = OwnedTask()
  /// Tells the provider when the network moved; see `followNetwork`.
  private let networkWatch = OwnedTask()
  private let networkPath: NetworkPathObserver

  private enum Declined {
    case needsPerson(reason: String)
    /// `reason` is the connection row's one line; `detail` is what the provider said, for
    /// the notice raised if the outage lasts.
    case providerUnavailable(reason: String, detail: String)
  }

  init(host: Host) {
    let scoped = host.scopedSettings(for: Self.manifest)
    let alerts = host.alerts
    let clientActivity = host.clientActivity
    self.scoped = scoped
    self.alerts = alerts
    self.logger = host.logger
    self.tools = host.tools
    self.daemonLedger = host.daemonLedger
    self.reportHealth = { await host.serviceHealthDidChange(Self.id) }
    self.networkPath = host.networkPath
    let name = Self.manifest.name
    let identifier = Self.manifest.id.rawValue
    let attentionPrefix = ProxyAttentionAlerts.dedupeKeyPrefix(for: Self.manifest.id)
    let gaveUpKey = ProxyAttentionAlerts.gaveUpDedupeKey(for: Self.manifest.id)
    self.coordinator = ProxyCoordinator(
      lastConnectionAt: { clientActivity.last },
      onAddressChanged: { address in
        // An address means every step a person was asked to take has been taken, so the
        // notices asking for them are withdrawn rather than left to be read: a sign-in
        // link that still shows after the sign-in is an instruction to do it again.
        await alerts.dismiss(dedupeKeyPrefix: attentionPrefix)
        // And the same for "it has failed repeatedly", which is now a state a tunnel can
        // come BACK from: the slow retry phase runs for as long as the service does, so a
        // notice saying clients cannot reach this server has to go the moment one can.
        // While giving up was terminal this could be left standing; it no longer is.
        await alerts.dismiss(dedupeKeyPrefix: gaveUpKey)
        // The one place the published address is written. Everything that needs it
        // (Firebase, the UI, server/info) reads it from settings.
        //
        // Through the scope, which is what makes `server_address` on this method's
        // manifest a permission rather than a description, and which records the write as
        // this service: after a daemon crash this runs from the process's termination
        // handler, a task no boundary set an actor on, and the audit record of the new
        // address would otherwise say nobody published it.
        let saved = await scoped.trySet(Settings.serverAddress, to: address)
        guard saved else {
          // The tunnel is up and nobody will be told where. Clients keep the old
          // address; Firebase keeps the old address. That is an outage with no symptom
          // on this side, so it is raised, not logged.
          await alerts.raise(
            UserAlert(
              severity: .error,
              title: "Could not save the server address",
              body:
                "\(name) is running at \(address), but the address could not be written to "
                + "settings, so clients and Firebase will not learn it.",
              source: identifier,
              dedupeKey: "\(identifier).address-not-saved"
            )
          )
          return
        }
      },
      onFailure: { reason in
        // A tunnel that has stopped coming back is not a log line. Every client is now
        // holding an address that resolves to nothing, and nothing else on screen will
        // say so: `health` reports "not connected", which is a state, not a summons.
        await alerts.raise(
          UserAlert(
            severity: .error,
            title: "\(name) has stopped",
            body: reason,
            source: "Connection",
            actions: [.openSettings(.settings)],
            dedupeKey: gaveUpKey,
            // Whether the tunnel is down is re-established the moment it tries again.
            isDurable: false
          )
        )
      },
      onAttention: { attention in
        // A step only a person can take: a sign-in link, a feature to switch on. The
        // same alert for every connection method, built from what the provider said;
        // the link, where there is one, is the action.
        var actions: [AlertAction] = []
        if let link = attention.link { actions.append(.openURL(link)) }
        actions.append(.openSettings(.settings))
        // One pending step at a time. The previous one is withdrawn rather than left
        // beside its successor: "sign in" followed by "enable certificates" means the
        // sign-in is done, and two notices would read as two things still to do.
        await alerts.dismiss(dedupeKeyPrefix: attentionPrefix)
        await alerts.raise(
          UserAlert(
            severity: .warning,
            title: attention.title,
            body: attention.body,
            source: "Connection",
            actions: actions,
            dedupeKey: attentionPrefix + attention.key,
            // Re-raised by the provider whenever the step is still pending after a
            // restart, so the fresh notice replaces this one.
            isDurable: false
          )
        )
      },
      // `health` reads the coordinator's address and pending reason, so the registry's
      // health stream has to be told when either moves: a tunnel reconnecting is the
      // state the Connection row exists to show.
      onStateChanged: { await host.serviceHealthDidChange(Self.id) }
    )
  }

  /// Only the selected connection method runs.
  ///
  /// The exclusive category expressed at runtime: all six are registered, and five decline
  /// here. That is `GatedService`'s existing meaning, so nothing new was needed for it.
  func canRun() async -> Bool {
    await scoped.valueOrDefault(Settings.connectionMethod) == Self.manifest.id.rawValue
  }

  /// What the method is handed to build its provider with.
  var proxyHost: ProxyHost {
    ProxyHost(
      scoped: scoped, alerts: alerts, logger: logger, tools: tools,
      daemonLedger: daemonLedger, manifest: Method.manifest, ownWrites: ownWrites
    )
  }

  func start() async throws {
    retry.cancel()
    toolWatch.cancel()
    followNetwork()
    await begin()
  }

  /// One attempt, handing a provider outage to the retry loop.
  private func begin() async {
    guard await attempt() == .retry else { return }
    retry.run { [weak self] in await self?.retryUntilSettled() }
  }

  private enum Attempt { case settled, retry }

  /// One try at bringing the method up: build the provider, then connect it.
  ///
  /// A connect that throws is counted as the provider's end failing, whatever it says.
  /// `tunnelFailed` carries both (cloudflared that could not reach Cloudflare, an ngrok token
  /// that has expired) and the two cannot be told apart from here, so it is retried at the
  /// pace a running tunnel already retries a daemon that will not stay up. The one exception
  /// is `notConfigured`, which only a person can answer.
  private func attempt() async -> Attempt {
    // Read BEFORE the provider is built, so a program replaced while it is being built is
    // seen as a change rather than taken as the one already running.
    let program = await runningProgram()
    let outcome = await Method.makeProvider(proxyHost)
    switch outcome.kind {
    case .needsPerson(let reason, let awaiting):
      await settle(.needsPerson(reason: reason))
      if let awaiting { awaitTool(awaiting) }
      return .settled
    case .providerUnavailable(let reason, let detail):
      await settle(.providerUnavailable(reason: reason, detail: detail))
      return .retry
    case .ready(let provider):
      // The address it obtains is never logged, here or in the coordinator: the public URL
      // of this server is the one string a pasted log must not carry.
      logger.info(
        "Connection method starting",
        metadata: ["connectionMethod": .string(Self.manifest.id.rawValue)])
      await settle(nil)
      do {
        try await coordinator.start(provider)
        if let program { followToolUpdates(from: program) }
        return .settled
      } catch is CancellationError {
        return .settled
      } catch ProxyError.notConfigured(let detail) {
        await coordinator.stop()
        await settle(.needsPerson(reason: detail))
        return .settled
      } catch {
        logger.warning(
          "The tunnel could not connect; retrying",
          metadata: [
            "connectionMethod": .string(Self.manifest.id.rawValue),
            "error": .string(String(describing: error)),
          ])
        await coordinator.stop()
        await settle(
          .providerUnavailable(
            reason: "could not connect", detail: DiagnosticText.sentence(for: error)))
        return .retry
      }
    }
  }

  /// Tries again on `Method.retryPace` until an attempt connects or needs a person.
  ///
  /// Never gives up: the pace slows to `steady` and stays there, so the method comes back
  /// when its provider does. Told once, when the last fast attempt fails, under the same
  /// notice a running tunnel raises when it slows down, which the first published address
  /// withdraws.
  private func retryUntilSettled() async {
    let pace = Method.retryPace
    // The only error is cancellation, which is `stop`, and there is nothing left to do.
    _ = try? await retrying(pace.schedule, previousFailures: 1) { number in
      // Numbered from the start that failed, so the last fast attempt is `fast.count + 1`.
      let result = await attempt()
      if result == .retry, number == pace.fast.count + 1,
        case .providerUnavailable(_, let detail) = declined
      {
        await raiseStillUnavailable(detail: detail)
      }
      return result
    } until: {
      $0 == .settled
    }
  }

  /// The notice for an outage that outlasted the fast retries. Under the key a running
  /// tunnel's slow phase uses, so there is one "has stopped" per method whichever way it
  /// stopped, and `onAddressChanged` withdraws it.
  private func raiseStillUnavailable(detail: String) async {
    let name = Self.manifest.name
    logger.error(
      "The connection method's provider is still unavailable; slowing down",
      metadata: ["connectionMethod": .string(Self.manifest.id.rawValue)])
    await alerts.raise(
      UserAlert(
        severity: .error,
        title: "\(name) has stopped",
        body: "\(detail) This server will keep trying every few minutes, and the "
          + "address comes back on its own when \(name) does.",
        source: "Connection",
        actions: [.openSettings(.settings)],
        dedupeKey: ProxyAttentionAlerts.gaveUpDedupeKey(for: Self.manifest.id),
        isDurable: false
      )
    )
  }

  /// Tries again the moment the tool manager has the program a refused start was missing.
  ///
  /// The notice that refused the start promised exactly this ("install it and the tunnel
  /// starts on its own"), and nothing else keeps that promise: an install writes none of the
  /// method's settings, so the restart an edit would bring never comes, and a method waiting
  /// on a person is `.inactive`, so a returning network does not either. Following the tool
  /// manager rather than the app's Install button covers every way a program arrives: the
  /// app, the API, a scan that finds a copy already on this Mac, and a binary the person
  /// points at.
  ///
  /// Subscribed BEFORE the program is looked for, and looked for once straight away, so an
  /// install that finished between the refusal and the subscription is not waited on for
  /// ever. Asks only whether the MISSING thing has appeared, so a tool event that does not
  /// answer the refusal (a progress tick, an unrelated update) cannot start a loop.
  private func awaitTool(_ wait: ProxyStart.ToolWait) {
    guard let toolID = Self.manifest.tools.first?.id else { return }
    toolWatch.run { [weak self] in
      guard let self else { return }
      let updates = await self.tools.stream()
      if await self.isAvailable(wait.need, of: toolID) {
        await self.toolArrived(wait)
        return
      }
      for await status in updates where status.id == toolID {
        guard !Task.isCancelled else { return }
        if await self.isAvailable(wait.need, of: toolID) {
          await self.toolArrived(wait)
          return
        }
      }
    }
  }

  /// Which program the method would be handed now: where it is and what version it says it
  /// is. Nil for a method that declares no program, and the path is nil when there is none.
  ///
  /// The path alone would miss a copy replaced where it stands, which is how Homebrew
  /// upgrades: the same path, a new version on the next scan. The version alone would miss a
  /// revert to a build whose version could not be read.
  private struct Program: Equatable {
    let path: String?
    let version: String?
  }

  private func runningProgram() async -> Program? {
    guard let toolID = Self.manifest.tools.first?.id,
      let status = await tools.status(of: toolID)
    else { return nil }
    let version: String? =
      switch status.origin {
      case .managed: status.state.installed?.version
      case .external: status.state.externalProbe?.version
      case .discovered: status.state.discovered?.version
      default: nil
      }
    return Program(path: status.executablePath, version: version)
  }

  /// Restarts the method when the program it runs is replaced: an update, a revert, a copy
  /// the person chose, a newer copy a scan found.
  ///
  /// The tool page tells the person "the tunnel restarts" before an update, and nothing did:
  /// the daemon went on running the old build until something else restarted it, so an
  /// update installed to fix a tunnel did not fix it. Restarting disconnects clients for a
  /// moment, which is the cost the page names.
  ///
  /// Only a program that can be run counts as a replacement. One that has gone (an external
  /// copy cleared, a file deleted) leaves the daemon running on the copy it already has, which
  /// works; the next start is the one that reports it missing. Subscribed before it compares,
  /// for the reason `awaitTool` gives.
  private func followToolUpdates(from program: Program) {
    guard let toolID = Self.manifest.tools.first?.id else { return }
    toolWatch.run { [weak self] in
      guard let self else { return }
      let updates = await self.tools.stream()
      if await self.wasReplaced(program) {
        await self.programReplaced()
        return
      }
      for await status in updates where status.id == toolID {
        guard !Task.isCancelled else { return }
        if await self.wasReplaced(program) {
          await self.programReplaced()
          return
        }
      }
    }
  }

  private func wasReplaced(_ program: Program) async -> Bool {
    guard let now = await runningProgram(), now.path != nil else { return false }
    return now != program
  }

  private func programReplaced() async {
    logger.info(
      "The program this connection method runs was replaced; restarting it",
      metadata: ["connectionMethod": .string(Self.manifest.id.rawValue)])
    retry.cancel()
    await begin()
  }

  private func isAvailable(_ need: ProxyStart.ToolWait.Need, of toolID: String) async -> Bool {
    switch need {
    case .executable:
      await tools.executablePath(for: toolID) != nil
    case .companion(let name):
      await tools.companionExecutablePath(for: toolID, named: name) != nil
    }
  }

  private func toolArrived(_ wait: ProxyStart.ToolWait) async {
    logger.info(
      "The program this connection method was missing is available; starting it",
      metadata: ["connectionMethod": .string(Self.manifest.id.rawValue)])
    // The notice said the program was missing, and it no longer is. Anything still wrong is
    // the next attempt's to say.
    await alerts.dismiss(dedupeKeyPrefix: wait.alertKey)
    await begin()
  }

  /// Hands the provider every settled network change, for the method whose address IS the
  /// network: a LAN address goes with a new DHCP lease or a move between networks, and the
  /// server would otherwise go on publishing one this Mac no longer has.
  ///
  /// Both a change and a return, because a Mac that drops off one network and joins another
  /// reports a return, not a change. Never a loss: there is no address to move to. The
  /// observer has already waited out the burst a wake or a dock produces. Every provider is
  /// told and only one acts; a tunnel's address belongs to its provider, which reconnects on
  /// its own, and restarting it on a route change would manufacture the outage
  /// `NetworkRecoveryService` is careful never to cause.
  private func followNetwork() {
    guard !networkWatch.isRunning else { return }
    networkWatch.run { [weak self] in
      guard let transitions = await self?.networkPath.transitions() else { return }
      for await transition in transitions {
        guard !Task.isCancelled else { return }
        await self?.networkSettled(transition)
      }
    }
  }

  /// One settled transition. Internal rather than private so a test can drive it without a
  /// monitor, as `NetworkRecoveryService.handle` is.
  func networkSettled(_ transition: NetworkTransition) async {
    guard transition.path.isSatisfied else { return }
    await coordinator.networkChanged()
  }

  private func settle(_ state: Declined?) async {
    declined = state
    await reportHealth()
  }

  func stop() async {
    await networkWatch.stop()
    await toolWatch.stop()
    await retry.stop()
    declined = nil
    await coordinator.stop()
    // Nothing is waiting on a person once nothing is running. A method switched away
    // from, or a server shutting down, takes its pending steps with it; a restart that
    // finds the step still pending raises a fresh notice.
    await alerts.dismiss(
      dedupeKeyPrefix: ProxyAttentionAlerts.dedupeKeyPrefix(for: Self.manifest.id))
  }

  /// Restarts on any watched change except a field the method itself just wrote.
  func apply(_ change: SettingsChange) async throws -> ReloadAction {
    var relevant = change.changedKeys.intersection(Self.watchedSettings)
    for (field, written) in ownWrites.value {
      let key = Self.manifest.storageKey(for: field)
      if relevant.contains(key), await scoped.own(field) == written {
        relevant.remove(key)
      }
    }
    return relevant.isEmpty ? .none : .restart
  }

  /// Running once an address is published. Before that, the reason: a tunnel that has come
  /// up and is waiting on a person (Tailscale's sign-in link, say) reports what it is
  /// waiting for rather than a bare "not connected" that reads as a failure.
  /// Three states, and the split between the last two is what lets a dropped tunnel come back.
  ///
  /// **A tunnel that dropped is `.failed`, not `.inactive`.** `.inactive` means deliberately
  /// not running, and `NetworkRecoveryService` skips it precisely because "switched off" is
  /// one of its reasons. Reporting a lost tunnel that way put it in the same bucket as one a
  /// person turned off, so a network outage — or a closed lid — left ngrok, cloudflared or
  /// zrok down until somebody restarted the server. Nothing else covers it: `restartPolicy`
  /// only re-enters `supervise` when `start()` THROWS, and a tunnel that connected and later
  /// dropped never threw; the liveness poll reads `isAlive`, which this service does not
  /// override, so it answers `true` for a tunnel with no connection.
  ///
  /// **Waiting on a PERSON stays `.inactive`.** A sign-in to finish or a token to paste is
  /// not something a returning network fixes, and retrying it on every transition would
  /// re-raise the same alert. `pendingReason` is exactly that distinction and the coordinator
  /// already maintains it: set by `attentionRequired`, cleared when an address arrives.
  ///
  /// **A method that declined says which kind of decline.** One that needs a person is
  /// `.inactive`, for the reason above; one whose provider is failing is `.failed`, so a
  /// returning network restarts it at once rather than at its next retry.
  ///
  /// A method that is not the selected one has no instance at all, so the registry answers for
  /// it, and a start still in flight is reported as `.starting` before this is ever asked.
  var health: ServiceHealth {
    get async {
      if await coordinator.address != nil { return .running }
      if let pending = await coordinator.pendingReason { return .inactive(reason: pending) }
      switch declined {
      case .needsPerson(let reason): return .inactive(reason: reason)
      case .providerUnavailable(let reason, _): return .failed(reason: reason)
      // `.failed`, so a returning network restarts it (`ProxyRecoveryHealthTests`): a tunnel
      // that dropped throws nothing and stays alive, and this is the only signal it gives.
      case nil: return .failed(reason: ServiceHealth.RoutineReason.notConnected)
      }
    }
  }

}

/// Where a connection method's "needs a person" alerts are keyed.
///
/// Public because two sides agree on it: `ProxyService` raises and withdraws under it, and
/// the method's own page in the app filters the drawer by it, so the sign-in link is shown
/// where the method is configured and not only in a drawer somewhere else.
public enum ProxyAttentionAlerts {
  public static func dedupeKeyPrefix(for service: ServiceIdentifier) -> String {
    "proxy.attention.\(service.rawValue)."
  }

  /// The repeated-failure notice, which is raised and withdrawn from two different places
  /// and so cannot be a literal at either of them.
  public static func gaveUpDedupeKey(for service: ServiceIdentifier) -> String {
    "proxy.gave-up.\(service.rawValue)"
  }
}

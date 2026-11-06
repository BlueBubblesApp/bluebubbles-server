//  LaunchAtLoginService
//  Making `auto_start_method` register the launch agent, and keeping its row honest.
//
//  `LaunchAtLogin` wraps `SMAppService.agent`; this service is what calls it when the setting
//  changes. A setting that is stored and does nothing is the worst shape for this particular
//  feature: the user finds out at the next reboot, when the server they expected to be
//  running is not.
//
//  What it does, and each part is about not fighting the user:
//
//    - The registration follows the setting and nothing else: registered when it is on and
//      absent, unregistered when it is off and present, left alone otherwise. An `.enabled`
//      registration is never re-registered; `LaunchAtLogin` says why.
//    - `requiresApproval` is NOT an error. macOS holds a registration there until the user
//      approves it in System Settings, and the only correct response is to say so once.
//    - What an upgraded install left behind is removed on every start, whatever the setting:
//      the retired helper app's login item while launchd still runs it, and the Electron
//      server's launch agent. Left in place, each starts a second copy at login.
//    - Every notice it raised is withdrawn once a reading finds the registration as the
//      setting wants it. While it waits for an approval given in System Settings, and only
//      then, it reads the status again every `approvalRecheckInterval`, which is how that
//      notice clears without a restart. Otherwise it asks once per start: a status read is
//      the same Background Task Management round trip as a registration, and on a busy Mac
//      neither is cheap. A person switching it off in System Settings while the server runs
//      is noticed at the next start.
//
//  **Nothing here is on the start path or the health path, and the row does not say
//  "starting" while macOS answers.** `start()` hands the work to the service's own task and
//  returns, and `health` returns what that work last found. Every `SMAppService` call is an
//  XPC round trip, and on a Mac with little memory and a spinning disk a registration has
//  taken more than ten minutes. That is not startup: nothing waits on it, so until the work
//  finds something to say the service reports what it is (`healthBeforeReconciling`), and a
//  `.starting` that lasted minutes would hold the startup bar open and read as a hang. What
//  it finds that needs a person (approval, a refusal) is raised as a notice when found.
//
//  See `.claude/docs/architecture.md`.

import BBBuiltIns
import BBCore
import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSystem
import Foundation

actor LaunchAtLoginService: Service, ConfigurableService {

  static let manifest = BuiltInManifests.launchAtLogin
  /// Registration either works or is refused by the system for a reason retrying will not
  /// change: a missing plist, or a user who declined.
  static let restartPolicy = RestartPolicy.never

  /// How often the status is read again while the registration waits for approval. Approval
  /// in System Settings raises no event, so this is how that row and its notice move on.
  static let approvalRecheckInterval: Duration = .seconds(60)

  /// What the row says while the registration waits for the person to approve it.
  static let awaitingApproval = ServiceHealth.degraded(
    reason: "waiting for approval in System Settings > Login Items")

  /// What this service touches, rather than the container that holds it.
  typealias Host = any ScopedSettingsProviding & AlertProviding & LoggerProviding
    & HealthChangeReporting
  /// What the reconciliation helpers need: they report, they do not read configuration.
  typealias Reporting = any AlertProviding & LoggerProviding

  /// The prefix every notice this service raises carries, so one call withdraws them all.
  static let alertPrefix = "launch-at-login."

  private let scoped: ScopedSettings
  private let host: Host
  /// The reconciliation, then the approval recheck. See the header on why neither is awaited.
  private let work = OwnedTask()
  /// What the work last found, or `healthBeforeReconciling` until it has found anything.
  private var current: ServiceHealth = .starting

  init(host: Host) {
    self.scoped = host.scopedSettings(for: Self.manifest)
    self.host = host
  }

  func start() async throws {
    let mode = Self.mode(for: try await scoped.get(Settings.autoStartMethod))
    current = Self.healthBeforeReconciling(mode)
    work.run { [weak self, host] in
      await Self.removeLeftovers(context: host)
      let found = await Self.reconcile(mode, context: host)
      await self?.record(found)
      guard found == Self.awaitingApproval else { return }
      // Thrown only by a stop, which ends the recheck with nothing to record.
      _ = try? await retrying(.every(Self.approvalRecheckInterval), previousFailures: 1) { _ in
        await self?.recheckApproval(mode) ?? true
      } until: {
        $0
      }
    }
  }

  /// A registration is persistent system state, not a running resource: unregistering it
  /// because the server is shutting down would disable the very thing that is meant to start
  /// it next time. Only the reconciliation and the refresh stop.
  func stop() async {
    await work.stop()
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth { current }

  private func record(_ health: ServiceHealth) async {
    guard health != current else { return }
    current = health
    await host.serviceHealthDidChange(Self.id)
  }

  /// One reading while the registration waits for approval: what the row shows, and whether
  /// the notices still hold. It never registers; that is the reconciliation's, at the next
  /// start.
  ///
  /// - Returns: whether to stop reading, which is once it no longer waits for approval.
  private func recheckApproval(_ mode: LaunchAtLogin.Mode) async -> Bool {
    // Nil only when cancelled, which is a stop: nothing to record.
    guard let observation = try? await LaunchAtLogin.observe(mode: mode) else { return true }
    let action = LaunchAtLogin.decide(mode: mode, observation)
    if action == .leave {
      await host.alerts.dismiss(dedupeKeyPrefix: Self.alertPrefix)
    }
    await record(Self.health(mode: mode, observation))
    return action != .awaitApproval
  }

  // MARK: - Reconciliation

  /// `AutoStartMethod` is the wire enum and carries an `unset` case the mode does not.
  ///
  /// `unset` means the user has never chosen, which is not the same as choosing "no", but
  /// the action is identical, so it maps to `.none` here rather than being a third branch
  /// everywhere downstream.
  static func mode(for method: AutoStartMethod) -> LaunchAtLogin.Mode {
    switch method {
    case .none, .unset: .none
    case .loginItem: .loginItem
    }
  }

  /// What a row shows before anything has been read from macOS: off when the setting is,
  /// running otherwise. The service IS running, and its work is answering a question nothing
  /// waits for; a problem it finds is reported then, in the row and as a notice.
  static func healthBeforeReconciling(_ mode: LaunchAtLogin.Mode) -> ServiceHealth {
    mode == .none ? .inactive(reason: notSetReason) : .running
  }

  private static let notSetReason = "not set to start at login"

  /// What a row shows for an observation, with no action taken.
  static func health(
    mode: LaunchAtLogin.Mode, _ observation: LaunchAtLogin.Observation
  ) -> ServiceHealth {
    guard mode != .none else { return .inactive(reason: notSetReason) }
    switch LaunchAtLogin.decide(mode: mode, observation) {
    case .leave, .unregister:
      return .running
    case .awaitApproval:
      return awaitingApproval
    case .refuse(let location):
      return .degraded(reason: unsuitableReason(location))
    case .notBundled:
      return .degraded(reason: "this build of BlueBubbles has no launch agent to register")
    case .register:
      return .degraded(reason: "not registered")
    }
  }

  private static func unsuitableReason(_ location: LaunchAtLogin.UnsuitableLocation) -> String {
    switch location {
    case .translocated:
      "cannot start at login until BlueBubbles is moved to the Applications folder"
    case .readOnlyVolume:
      "cannot start at login from a disk image; move BlueBubbles to the Applications folder"
    }
  }

  /// Removes what earlier installs registered, and says what it removed.
  static func removeLeftovers(context: Reporting) async {
    let logger = context.logger
    if await LaunchAtLogin.retiredLauncherIsLoaded() {
      await LaunchAtLogin.removeRetiredLauncher()
      logger.notice("Removed the login item an earlier version registered")
    }
    switch await LaunchAtLogin.removeElectronAgent() {
    case .notPresent, .notOurs:
      break
    case .removed:
      logger.notice("Removed the previous server's launch agent")
    case .removedFileOnly:
      // It started this copy, so it stays loaded until logout; it does not load again.
      logger.notice("Removed the previous server's launch agent, which started this copy")
    case .failed:
      logger.warning("Could not remove the previous server's launch agent")
    }
  }

  /// Brings the registration in line with the setting, and says what it found.
  static func reconcile(_ mode: LaunchAtLogin.Mode, context: Reporting) async -> ServiceHealth {
    let logger = context.logger
    // Nil only when cancelled, which is a stop: there is nothing to reconcile for.
    guard let observation = try? await LaunchAtLogin.observe(mode: mode) else {
      return healthBeforeReconciling(mode)
    }

    switch LaunchAtLogin.decide(mode: mode, observation) {
    case .unregister:
      await LaunchAtLogin.unregister()
      await context.alerts.dismiss(dedupeKeyPrefix: alertPrefix)
      logger.info("Launch at login is off; removed the registration")
      return health(mode: mode, observation)

    case .leave:
      await context.alerts.dismiss(dedupeKeyPrefix: alertPrefix)
      logger.debug("Launch at login is as the setting wants it")
      return health(mode: mode, observation)

    case .awaitApproval:
      await raiseApprovalAlert(context: context)
      return health(mode: mode, observation)

    case .notBundled:
      logger.warning("This build has no launch agent; launch at login cannot be registered")
      return health(mode: mode, observation)

    case .refuse(let location):
      logger.warning(
        "Not registering to launch at login from a location that will not last",
        metadata: ["location": .string(String(describing: location))])
      await context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "Move BlueBubbles to Applications to start it at login",
          body: "BlueBubbles is running from a disk image or from a temporary copy macOS made "
            + "of it, and a registration made from there stops working when that copy goes "
            + "away. Quit BlueBubbles, move it to the Applications folder and open it from there.",
          source: "Launch at Login",
          dedupeKey: alertPrefix + "unsuitable-location"
        )
      )
      return health(mode: mode, observation)

    case .register:
      return await register(context: context)
    }
  }

  private static func register(context: Reporting) async -> ServiceHealth {
    let logger = context.logger
    // Said before the call, because the call can take minutes and a log that goes quiet for
    // that long reads as a hang.
    logger.info("Registering to launch at login; macOS can take several minutes to answer")
    let started = ContinuousClock.now
    let status: LaunchAtLogin.Status
    do {
      status = try await LaunchAtLogin.register()
    } catch is CancellationError {
      // A stop arrived while macOS was answering. The call still lands; whether it took is
      // read again at the next start.
      return .running
    } catch {
      // Reported, never fatal. A server that refuses to start because it could not
      // register itself has turned a convenience into an outage.
      logger.warning(
        "Could not register to launch at login",
        metadata: ["error": .string(String(describing: error))])
      await raiseFailure(DiagnosticText.sentence(for: error), context: context)
      return .degraded(reason: "macOS refused to register it")
    }
    logger.info(
      "Registered to launch at login",
      metadata: [
        "status": .string(status.rawValue),
        "ms": .stringConvertible((ContinuousClock.now - started).milliseconds),
      ])
    if status == .requiresApproval {
      await raiseApprovalAlert(context: context)
      return awaitingApproval
    }
    await context.alerts.dismiss(dedupeKeyPrefix: alertPrefix)
    return .running
  }

  private static func raiseFailure(_ cause: String, context: Reporting) async {
    await context.alerts.raise(
      UserAlert(
        severity: .warning,
        title: "Could not set the server to start at login",
        body: "macOS refused the request: \(cause) The server is running normally, but it "
          + "will not start on its own after a restart.",
        source: "Launch at Login",
        actions: [.openSettings(.features)],
        dedupeKey: alertPrefix + "failed"
      )
    )
  }

  /// One alert, deduped, because this state persists until a person acts on it.
  private static func raiseApprovalAlert(context: Reporting) async {
    await context.alerts.raise(
      UserAlert(
        severity: .info,
        title: "Approve BlueBubbles in Login Items",
        body: "macOS needs you to allow BlueBubbles to open at login. Open System "
          + "Settings > General > Login Items and switch it on.",
        source: "Launch at Login",
        dedupeKey: alertPrefix + "requires-approval"
      )
    )
  }
}

//  LaunchAtLoginService
//  Making `auto_start_method` actually install a login item.
//
//  `LaunchAtLogin` wraps `SMAppService` and was called from nowhere, so the setting was
//  offered in the UI, stored, migrated from the Electron config — and did nothing. A user who
//  turned it on got no login item and no indication that nothing had happened, which is the
//  worst shape for this particular feature: they find out at the next reboot, when the server
//  they expected to be running is not.
//
//  Two behaviours here are deliberate and both are about not fighting the user:
//
//    - `requiresApproval` is NOT an error. macOS puts a newly registered login item in that
//      state until the user approves it in System Settings, and the only correct response is
//      to say so once. Retrying registration does not clear it and re-registering on every
//      launch would put the entry back after they removed it.
//    - Turning the setting off unregisters. Leaving a stale registration behind means the
//      app keeps launching at login after the user switched it off, which reads as the
//      setting being broken.
//
//  See `.claude/docs/architecture.md`.

import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSystem
import Foundation

actor LaunchAtLoginService: ContextualService, ConfigurableService {

  static let manifest = BuiltInManifests.launchAtLogin
  static let watchedSettings: Set<String> = [Settings.autoStartMethod.key]
  /// Registration either works or is refused by the system for a reason retrying will not
  /// change — a missing bundle, or a user who declined.
  static let restartPolicy = RestartPolicy.never

  let context: AppContext

  init(host: AppContext) { self.context = host }

  func start() async throws {
    let requested = await context.settings.get(Settings.autoStartMethod)
    await Self.reconcile(requested, context: context)
  }

  /// Deliberately empty. A login item is persistent system state, not a running resource:
  /// unregistering it because the server is shutting down would disable the very thing that
  /// is meant to start it next time.
  func stop() async {}

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async {
      let mode = Self.mode(for: await context.settings.get(Settings.autoStartMethod))
      guard mode != LaunchAtLogin.Mode.none else {
        return .inactive(reason: "not set to start at login")
      }
      switch LaunchAtLogin.status(mode: mode) {
      case .enabled: return .running
      case .requiresApproval:
        return .degraded(reason: "waiting for approval in System Settings > Login Items")
      case .notRegistered, .notFound, .unknown:
        return .degraded(reason: "not registered")
      }
    }
  }

  // MARK: - Reconciliation

  /// `AutoStartMethod` is the wire enum and carries an `unset` case the mode does not.
  ///
  /// `unset` means the user has never chosen, which is not the same as choosing "no" — but
  /// the action is identical, so it maps to `.none` here rather than being a third branch
  /// everywhere downstream.
  static func mode(for method: AutoStartMethod) -> LaunchAtLogin.Mode {
    switch method {
    case .none, .unset: .none
    case .loginItem: .loginItem
    case .launchAgent: .launchAgent
    }
  }

  static func reconcile(_ method: AutoStartMethod, context: AppContext) async {
    let mode = mode(for: method)
    let logger = context.logger

    guard mode != .none else {
      // Unregister rather than no-op: the setting having been on before is exactly the
      // case where there is something to remove.
      try? LaunchAtLogin.unregister(mode: .loginItem)
      logger.debug("Launch at login is off")
      return
    }

    // Already registered — including already awaiting approval. Re-registering would put
    // the entry back after the user removed it in System Settings.
    let existing = LaunchAtLogin.status(mode: mode)
    guard existing != .enabled else {
      logger.debug("Already registered to launch at login")
      return
    }
    if existing == .requiresApproval {
      await raiseApprovalAlert(context: context)
      return
    }

    do {
      let status = try LaunchAtLogin.register(mode: mode)
      logger.info(
        "Registered to launch at login",
        metadata: [
          "mode": .string(mode.rawValue),
          "status": .string(status.rawValue),
        ])
      if status == .requiresApproval {
        await raiseApprovalAlert(context: context)
      }
    } catch {
      // Reported, never fatal. A server that refuses to start because it could not
      // install a login item has turned a convenience into an outage.
      logger.warning(
        "Could not register to launch at login",
        metadata: [
          "mode": .string(mode.rawValue),
          "error": .string(String(describing: error)),
        ])
      await context.alerts.raise(
        UserAlert(
          severity: .warning,
          title: "Could not set the server to start at login",
          body: "macOS refused the request: \(error). The server is running "
            + "normally, but it will not start on its own after a restart.",
          source: "Launch at Login",
          actions: [.openSettings(section: "features")],
          dedupeKey: "launch-at-login.failed"
        )
      )
    }
  }

  /// One alert, deduped, because this state persists until a person acts on it.
  private static func raiseApprovalAlert(context: AppContext) async {
    await context.alerts.raise(
      UserAlert(
        severity: .info,
        title: "Approve BlueBubbles in Login Items",
        body: "macOS needs you to allow BlueBubbles to open at login. Open System "
          + "Settings > General > Login Items and switch it on.",
        source: "Launch at Login",
        dedupeKey: "launch-at-login.requires-approval"
      )
    )
  }
}

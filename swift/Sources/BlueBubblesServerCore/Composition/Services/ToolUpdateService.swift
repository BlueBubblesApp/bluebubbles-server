//  ToolUpdateService
//  Asking, on a schedule, whether the programs this server runs have newer versions.
//
//  It only ever ASKS. Nothing here installs anything, and the reason is worth restating where
//  the timer lives rather than only where the installer does: the program most likely to be
//  updated is the tunnel, the tunnel is the only route to this Mac, and an automatic update
//  that breaks it breaks the connection its owner would need in order to notice. They are not
//  at the machine — being away from the machine is what the tunnel is for.
//
//  So this service produces one thing: a notice with a version number on it. What happens next
//  is a person's decision, made while they are sitting in front of the Mac, with the previous
//  version still on disk and one click away.
//
//  See `.claude/docs/imessage.md`.

import BBDiagnostics
import BBInterfaces
import BBServiceKit
import BBSettings
import BBTooling
import Foundation

actor ToolUpdateService: ContextualService, GatedService, ConfigurableService {

  static let manifest = BuiltInManifests.toolUpdates
  static let watchedSettings: Set<String> = [Settings.checkForUpdates.key]
  /// A failed check is a network failure, and the timer will come round again. Restarting
  /// the service would just make the same request sooner.
  static let restartPolicy = RestartPolicy.never

  /// Once a day. These vendors publish every few weeks; anything more frequent is traffic
  /// nobody asked for, in exchange for hearing about a release some hours earlier.
  private static let interval = Duration.seconds(24 * 60 * 60)
  /// Long enough after launch that the check is never competing with the server coming up —
  /// and long enough that a machine rebooting repeatedly does not check on every boot.
  private static let initialDelay = Duration.seconds(120)

  let context: AppContext
  /// The shared one from `Services.swift`: every polling service in this module uses it,
  /// and a second implementation here would be a second place for the cancellation bug.
  private var checks: Task<Void, Never>?

  init(host: AppContext) { self.context = host }

  /// Gated on the same setting as the app's own update check.
  ///
  /// It defaults to OFF, so nothing here reaches the network until someone asks for it —
  /// and the Check button on an integration's page works regardless, because that is a
  /// person asking directly rather than a schedule deciding for them.
  func canRun() async -> Bool {
    await context.settings.get(Settings.checkForUpdates)
  }

  func start() async throws {
    let tools = context.tools
    checks?.cancel()
    checks = Task {
      try? await Task.sleep(for: Self.initialDelay)
      while !Task.isCancelled {
        await tools.checkAllForUpdates()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  func stop() async {
    checks?.cancel()
    checks = nil
  }

  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }

  var health: ServiceHealth {
    get async { checks != nil ? .running : .stopped }
  }
}

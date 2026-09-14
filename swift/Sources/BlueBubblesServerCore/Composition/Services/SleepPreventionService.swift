//  SleepPreventionService
//  Holds a power assertion while `auto_caffeinate` is on.

import BBBuiltIns
import BBInterfaces
import BBServiceKit
import BBSettings
import BBSystem

actor SleepPreventionService: Service, ConfigurableService, GatedService {
  static let manifest = BuiltInManifests.sleepPrevention

  /// The one thing this service touches, rather than the container that holds it.
  typealias Host = any SettingsProviding

  /// Reads go through the scope, so `auto_caffeinate` being on this service's manifest is
  /// what permits them rather than merely describing them.
  private let scoped: ScopedSettings
  private let prevention = SleepPrevention()

  init(host: any SettingsProviding) {
    self.scoped = ScopedSettings(
      store: host.settings, manifest: Self.manifest, secretKeys: Settings.secretKeys
    )
  }

  func canRun() async -> Bool {
    // `canRun` cannot throw, and a refusal would be a manifest bug rather than a
    // configuration state, so it is reported rather than swallowed.
    await scoped.valueOrDefault(Settings.autoCaffeinate)
  }

  func start() async throws { await prevention.begin() }
  func stop() async { await prevention.end() }
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }
  var health: ServiceHealth { get async { .running } }
}

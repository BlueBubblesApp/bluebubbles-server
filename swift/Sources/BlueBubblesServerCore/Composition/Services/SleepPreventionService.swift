//  SleepPreventionService
//  Holds a power assertion while `auto_caffeinate` is on.

import BBServiceKit
import BBSettings
import BBSystem

actor SleepPreventionService: ContextualService, ConfigurableService, GatedService {
  static let manifest = BuiltInManifests.sleepPrevention
  static let watchedSettings: Set<String> = [Settings.autoCaffeinate.key]

  let context: AppContext
  private let prevention = SleepPrevention()

  init(host: AppContext) { self.context = host }

  func canRun() async -> Bool {
    await context.settings.get(Settings.autoCaffeinate)
  }

  func start() async throws { await prevention.begin() }
  func stop() async { await prevention.end() }
  func apply(_ change: SettingsChange) async throws -> ReloadAction { .restart }
  var health: ServiceHealth { get async { .running } }
}

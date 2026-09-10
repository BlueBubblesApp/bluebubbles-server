//  IntegrationsModel
//  Which services are on: the selected connection method, and the additive switches.

import BBBuiltIns
import BBServiceKit
import BBSettings
import Foundation
import Observation

@Observable
@MainActor
final class IntegrationsModel {

  /// Which service the exclusive category has selected, and which additive ones are off.
  ///
  /// Kept as observable state rather than read per row: SwiftUI evaluates `isEnabled` for
  /// every visible service on every redraw, and an `await` per row would make the list
  /// flicker as each resolved.
  private(set) var selectedConnectionMethod: String = ""
  private(set) var disabledServices: Set<String> = []

  /// A write the store refused, with what the person was trying to do.
  var onFailure: (@MainActor (any Error, String) async -> Void)?

  private var store: SettingsStore?
  private var changesTask: Task<Void, Never>?

  /// The two keys this model is a view of.
  private static let watchedKeys: Set<String> = [
    Settings.connectionMethod.key, Settings.disabledServicesKey,
  ]

  /// Async so the subscription exists when this returns: a write that lands between
  /// attaching and a task getting round to subscribing would otherwise be missed, and the
  /// list would show the previous choice until the next one.
  func attach(_ store: SettingsStore) async {
    self.store = store
    // Re-read on ANY write to these keys, not only the ones made through `select` and
    // `toggle`. The Connection settings page, onboarding and the command line all write
    // `connection_method` directly, and a model refreshed only by its own methods would go
    // on showing "Use This" for the method that is already running.
    changesTask?.cancel()
    let changes = await store.changes()
    changesTask = Task { [weak self] in
      for await change in changes where change.intersects(Self.watchedKeys) {
        await self?.refresh()
      }
    }
  }

  func detach() {
    changesTask?.cancel()
    changesTask = nil
    store = nil
    selectedConnectionMethod = ""
    disabledServices = []
  }

  /// Whether a service is currently enabled.
  ///
  /// Two different questions behind one word, which is why this branches. In an EXCLUSIVE
  /// category "enabled" means "this is the one selected": there is a single value naming a
  /// winner. Everywhere else it is an independent switch with its own stored flag.
  func isEnabled(_ manifest: ServiceManifest) -> Bool {
    if manifest.category.isExclusive {
      return selectedConnectionMethod == manifest.id.rawValue
    }
    // The server's own answer, so the switch on screen and the service that is running
    // agree, including for the services `alwaysOn` refuses to switch off.
    return ServiceEnablement.isEnabled(manifest.id, disabled: disabledServices)
  }

  /// A service this one needs that is switched off, if there is one.
  ///
  /// DIRECT dependencies only, and that is enough here rather than a simplification: the
  /// only chains the built-in graph has are one deep once Permissions is discounted, and
  /// Permissions cannot be switched off. A deeper chain would be reported by the registry
  /// as inactive anyway; what this adds is the NAME, which the registry deliberately does
  /// not put in a sentence bound for a screen.
  func disabledDependency(of manifest: ServiceManifest) -> ServiceManifest? {
    for id in manifest.dependencies {
      guard let dependency = IntegrationCatalog.manifest(id) else { continue }
      if !isEnabled(dependency) { return dependency }
    }
    return nil
  }

  /// Picks a service within an exclusive category.
  func select(_ manifest: ServiceManifest) async {
    guard let store, manifest.category.isExclusive else { return }
    do {
      try await store.set(Settings.connectionMethod, to: manifest.id.rawValue)
    } catch {
      await onFailure?(error, "change the connection method")
    }
    await refresh()
  }

  /// Turns an additive service on or off.
  func toggle(_ manifest: ServiceManifest) async {
    guard let store else { return }
    var disabled = disabledServices
    let turningOff = !disabled.contains(manifest.id.rawValue)
    if turningOff {
      disabled.insert(manifest.id.rawValue)
    } else {
      disabled.remove(manifest.id.rawValue)
    }
    do {
      try await store.set(
        ServiceEnablement.serialized(disabled),
        forKey: Settings.disabledServicesKey,
        isSecret: false
      )
    } catch {
      await onFailure?(error, "turn \(manifest.name) \(turningOff ? "off" : "on")")
    }
    await refresh()
  }

  /// Re-reads what is enabled.
  func refresh() async {
    guard let store else { return }
    selectedConnectionMethod = await store.get(Settings.connectionMethod)
    // Parsed by the server's own rule. A second parser here is how the app and the server
    // came to disagree about a hand-edited value with a space in it.
    disabledServices = ServiceEnablement.disabledIdentifiers(
      in: await store.string(forKey: Settings.disabledServicesKey) ?? ""
    )
  }
}

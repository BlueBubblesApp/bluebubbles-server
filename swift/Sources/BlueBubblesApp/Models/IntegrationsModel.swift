//  IntegrationsModel
//  Which services are on: the selected connection method, and the additive switches.

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

  func attach(_ store: SettingsStore) {
    self.store = store
  }

  func detach() {
    store = nil
    selectedConnectionMethod = ""
    disabledServices = []
  }

  /// Whether a service is currently enabled.
  ///
  /// Two different questions behind one word, which is why this branches. In an EXCLUSIVE
  /// category "enabled" means "this is the one selected" — there is a single value naming a
  /// winner. Everywhere else it is an independent switch with its own stored flag.
  func isEnabled(_ manifest: ServiceManifest) -> Bool {
    if manifest.category.isExclusive {
      return selectedConnectionMethod == manifest.id.rawValue
    }
    return !disabledServices.contains(manifest.id.rawValue)
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
        disabled.sorted().joined(separator: ","),
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
    disabledServices = Set(
      (await store.string(forKey: Settings.disabledServicesKey) ?? "")
        .split(separator: ",")
        .map(String.init)
    )
  }
}

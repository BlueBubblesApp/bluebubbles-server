//  IntegrationsModel
//  Which services are on: the selected connection method, and the additive switches.
//
//  FOLLOWED for the life of the server, never asked for. Every write to the two keys this is
//  a view of goes through the one `SettingsStore` the server runs on, whoever makes it (the
//  Integrations page, a page's own switched-off notice, the Connection settings page,
//  onboarding, an API client, the server seeding its defaults), and the store announces each
//  one on `changes()`. So `attach` subscribes and then seeds, in that order, and nothing else
//  has to read: `refresh` is private, which is what stops a page polling it on every visit.
//  See "Live state is followed, never polled" in `Sources/BlueBubblesApp/CLAUDE.md`.

import BBBuiltIns
import BBCore
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
  private let changesTask = OwnedTask()

  /// Whether there is a store to answer from. False before the server starts and after it
  /// stops, when `isEnabled` would answer from an empty disabled set, which reads as every
  /// service being on. The sidebar asks this before it believes an answer.
  var isAttached: Bool { store != nil }

  /// The two keys this model is a view of.
  private static let watchedKeys: Set<String> = [
    Settings.connectionMethod.key, Settings.disabledServicesKey,
  ]

  /// Follows the store: subscribes, then seeds.
  ///
  /// Async so the subscription exists when this returns: a write that lands between
  /// attaching and a task getting round to subscribing would otherwise be missed, and the
  /// list would show the previous choice until the next one. The seed comes AFTER the
  /// subscription for the same reason, so no write falls between the two. Without a seed the
  /// model starts with an empty disabled set, and every service renders as enabled until
  /// something writes one of the keys.
  func attach(_ store: SettingsStore) async {
    self.store = store
    // Re-read on ANY write to these keys, not only the ones made through `select` and
    // `toggle`. The Connection settings page, onboarding and the command line all write
    // `connection_method` directly, and a model refreshed only by its own methods would go
    // on showing "Use This" for the method that is already running.
    changesTask.cancel()
    let changes = await store.changes()
    changesTask.run { @MainActor [weak self] in
      for await change in changes where change.intersects(Self.watchedKeys) {
        await self?.refresh()
      }
    }
    await refresh()
  }

  func detach() {
    changesTask.cancel()
    store = nil
    intendedDisabled = nil
    selectedConnectionMethod = ""
    disabledServices = []
  }

  /// Whether a service is enabled.
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

  /// Whether this service's OWN switch is off.
  ///
  /// NOT `isEnabled`, and the difference is the whole reason this exists. In an exclusive
  /// category `isEnabled` answers "is this the one selected", which is true of the selected
  /// connection method by construction, whatever its switch says. The registry reads the
  /// switch, so anything asking "why is the registry not running this" has to ask the same
  /// question the registry did.
  func isSwitchedOff(_ manifest: ServiceManifest) -> Bool {
    !ServiceEnablement.isEnabled(manifest.id, disabled: disabledServices)
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
    guard manifest.category.isExclusive else { return }
    do {
      let store = try store.orServerNotRunning()
      try await asOperator {
        try await store.set(Settings.connectionMethod, to: manifest.id.rawValue)
      }
    } catch {
      await onFailure?(error, "change the connection method")
    }
    await refresh()
  }

  /// What the switches say while a write of them is in flight, ahead of the store. Nil at
  /// rest. See `toggle`.
  private var intendedDisabled: Set<String>?
  /// How many writes of `disabled_services` are in flight.
  private var togglesInFlight = 0

  /// Turns an additive service on or off.
  ///
  /// Every switch is ONE stored list, so a toggle is a read-modify-write of the whole list,
  /// and two quick toggles raced: the second read the list before the first's write had
  /// been read back, and wrote it without the first change. So a toggle starts from what the
  /// switches already say (`intendedDisabled`), not from the last read; and whichever write
  /// finishes LAST writes what the switches say if its own list is no longer it, because two
  /// writes are not promised to land in the order they were made.
  func toggle(_ manifest: ServiceManifest) async {
    guard let store else {
      await onFailure?(ServerNotRunning(), "turn \(manifest.name) on or off")
      return
    }
    var disabled = intendedDisabled ?? disabledServices
    let turningOff = !disabled.contains(manifest.id.rawValue)
    if turningOff {
      disabled.insert(manifest.id.rawValue)
    } else {
      disabled.remove(manifest.id.rawValue)
    }
    intendedDisabled = disabled
    togglesInFlight += 1
    var written = disabled
    var failed = false
    while true {
      do {
        try await writeDisabled(written, to: store)
      } catch {
        failed = true
        await onFailure?(error, "turn \(manifest.name) \(turningOff ? "off" : "on")")
      }
      guard !failed, togglesInFlight == 1, let intended = intendedDisabled, intended != written
      else { break }
      written = intended
    }
    togglesInFlight -= 1
    // Let go once nothing is in flight: the store is the answer again, and a refused write
    // snaps the switches back to it beside the error saying why.
    if togglesInFlight == 0 { intendedDisabled = nil }
    await refresh()
  }

  private func writeDisabled(_ disabled: Set<String>, to store: SettingsStore) async throws {
    try await asOperator {
      try await store.set(
        ServiceEnablement.serialized(disabled),
        forKey: Settings.disabledServicesKey,
        isSecret: false
      )
    }
  }

  /// Re-reads what is enabled.
  ///
  /// Private: the change stream calls it, and `select` and `toggle` call it so their own
  /// write shows without waiting for the broadcast. A caller outside this type would be a
  /// page polling state that is already followed.
  private func refresh() async {
    guard let store else { return }
    selectedConnectionMethod = await store.get(Settings.connectionMethod)
    // Parsed by the server's own rule. A second parser here is how the app and the server
    // came to disagree about a hand-edited value with a space in it.
    disabledServices = ServiceEnablement.disabledIdentifiers(
      in: await store.string(forKey: Settings.disabledServicesKey) ?? ""
    )
  }
}

//  IntegrationsModelTests
//  The integrations list follows the store, not only the app's own writes.
//
//  `connection_method` is written from three places the model does not own (the Connection
//  settings page, onboarding, and the command line) and a model refreshed only by its own
//  `select` went on offering "Use This" for the method that was already running.

import BBBuiltIns
import BBPersistence
import BBSettings
import BBTestSupport
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Integrations model")
@MainActor
struct IntegrationsModelTests {

  @Test("A connection method chosen elsewhere shows as selected here")
  func followsExternalWrites() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    #expect(!model.isEnabled(BuiltInManifests.tailscale))

    // Written straight to the store, the way the Connection page does it.
    try await store.set(Settings.connectionMethod, to: BuiltInManifests.tailscale.id.rawValue)

    // The change arrives on a stream; give it a moment, but not a long one.
    try await waitUntil("Tailscale to read as enabled", timeout: .seconds(2)) {
      model.isEnabled(BuiltInManifests.tailscale)
    }
    #expect(model.isEnabled(BuiltInManifests.tailscale))
    #expect(!model.isEnabled(BuiltInManifests.cloudflare))

    model.detach()
  }

  /// No page asks: `refresh` is private, so what `attach` reads is all a page will ever see
  /// before the first write. A model that only subscribed would show every service as on.
  @Test("Attaching seeds what is already stored")
  func attachSeeds() async throws {
    let store = try await TestSettings.store()
    try await store.set(
      ServiceEnablement.serialized([BuiltInManifests.webhooks.id.rawValue]),
      forKey: Settings.disabledServicesKey, isSecret: false)

    let model = IntegrationsModel()
    await model.attach(store)
    #expect(!model.isEnabled(BuiltInManifests.webhooks))
    #expect(model.isEnabled(BuiltInManifests.contacts))

    model.detach()
  }

  /// The four pages that used to re-read on every visit (Contacts, Audit Log, API &
  /// Webhooks, Firebase) rely on this instead: a switch flipped anywhere reaches them.
  @Test("A service switched off elsewhere shows as off here")
  func followsEnablement() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    #expect(model.isEnabled(BuiltInManifests.contacts))

    try await store.set(
      ServiceEnablement.serialized([BuiltInManifests.contacts.id.rawValue]),
      forKey: Settings.disabledServicesKey, isSecret: false)

    try await waitUntil("Contacts to read as disabled", timeout: .seconds(2)) {
      !model.isEnabled(BuiltInManifests.contacts)
    }
    #expect(!model.isEnabled(BuiltInManifests.contacts))

    model.detach()
  }

  /// Every switch is one stored list, so a toggle is a read-modify-write of the whole list.
  /// Two quick toggles used to race: the second wrote the list without the first change.
  @Test("Two quick toggles both land")
  func quickTogglesBothLand() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)

    async let first: Void = model.toggle(BuiltInManifests.webhooks)
    async let second: Void = model.toggle(BuiltInManifests.contacts)
    _ = await (first, second)

    let stored = ServiceEnablement.disabledIdentifiers(
      in: await store.string(forKey: Settings.disabledServicesKey) ?? "")
    #expect(stored.contains(BuiltInManifests.webhooks.id.rawValue))
    #expect(stored.contains(BuiltInManifests.contacts.id.rawValue))
    #expect(!model.isEnabled(BuiltInManifests.webhooks))
    #expect(!model.isEnabled(BuiltInManifests.contacts))

    model.detach()
  }
}

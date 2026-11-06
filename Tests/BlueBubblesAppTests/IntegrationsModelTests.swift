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

  /// The one setting is the only state there is. Written anywhere, it shows here.
  @Test("A service controlled by a setting is whatever that setting says")
  func settingControlFollowsTheSetting() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    #expect(!model.isEnabled(BuiltInManifests.messageSearch))

    try await store.set(Settings.searchIndexEnabled, to: true)
    try await waitUntil("Message Search to read as on", timeout: .seconds(2)) {
      model.isEnabled(BuiltInManifests.messageSearch)
    }

    try await store.set(Settings.searchIndexEnabled, to: false)
    try await waitUntil("Message Search to read as off", timeout: .seconds(2)) {
      !model.isEnabled(BuiltInManifests.messageSearch)
    }
    await model.detach()
  }

  /// Start at Login is a picker, and two of its values mean off.
  @Test("A setting that is not a Bool reads through its own rule")
  func settingControlForAPicker() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    #expect(!model.isEnabled(BuiltInManifests.launchAtLogin))

    try await store.set(Settings.autoStartMethod, to: .loginItem)
    try await waitUntil("Start at Login to read as on", timeout: .seconds(2)) {
      model.isEnabled(BuiltInManifests.launchAtLogin)
    }
    await model.detach()
  }

  /// A name in `disabled_services` is the second on/off state this exists to prevent.
  @Test("Toggling a service controlled by a setting writes no second state")
  func toggleWritesNothing() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)

    await model.toggle(BuiltInManifests.messageSearch)

    let disabled = await store.string(forKey: Settings.disabledServicesKey) ?? ""
    #expect(!disabled.contains(BuiltInManifests.messageSearch.id.rawValue))
    #expect(await store.get(Settings.searchIndexEnabled) == false)
    await model.detach()
  }

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

    await model.detach()
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

    await model.detach()
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

    await model.detach()
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

    await model.detach()
  }

  /// A read keyed on the method alone cannot see a field being filled in, which left setup's
  /// gate saying "Address is required" over an address the person had just saved. Written
  /// straight to the store, because the form is not the only writer: the API and `--set`
  /// write the same keys.
  @Test("The selected method's blank fields follow every write to its namespace")
  func followsTheSelectedMethodsFields() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    let method = BuiltInManifests.dynamicDNS
    let address = method.storageKey(for: "address")

    try await store.set(Settings.connectionMethod, to: method.id.rawValue)
    try await waitUntil("the address to read as blank", timeout: .seconds(2)) {
      model.missingFields(of: method).map(\.key) == ["address"]
    }

    try await store.set("https://example.com:1234", forKey: address, isSecret: false)
    try await waitUntil("the address to read as filled in", timeout: .seconds(2)) {
      model.missingFields(of: method).isEmpty
    }

    try await store.set("", forKey: address, isSecret: false)
    try await waitUntil("the address to read as blank again", timeout: .seconds(2)) {
      !model.missingFields(of: method).isEmpty
    }

    await model.detach()
    #expect(model.missingFields(of: method).isEmpty)
  }

  /// A method not in use has nothing waiting on it, and the screens ask by method.
  @Test("Only the selected method reports blank fields, and the choice moving moves them")
  func answersOnlyForTheSelectedMethod() async throws {
    let store = try await TestSettings.store()
    let model = IntegrationsModel()
    await model.attach(store)
    let ngrok = BuiltInManifests.ngrok
    let custom = BuiltInManifests.dynamicDNS

    await model.select(ngrok)
    #expect(model.missingFields(of: ngrok).map(\.key) == ["auth_token"])
    #expect(model.missingFields(of: custom).isEmpty)

    await model.select(custom)
    #expect(model.missingFields(of: custom).map(\.key) == ["address"])
    #expect(model.missingFields(of: ngrok).isEmpty)

    await model.detach()
  }
}

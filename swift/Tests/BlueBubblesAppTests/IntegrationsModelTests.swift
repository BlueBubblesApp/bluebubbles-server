//  IntegrationsModelTests
//  The integrations list follows the store, not only the app's own writes.
//
//  `connection_method` is written from three places the model does not own (the Connection
//  settings page, onboarding, and the command line) and a model refreshed only by its own
//  `select` went on offering "Use This" for the method that was already running.

import BBBuiltIns
import BBPersistence
import BBSettings
import Foundation
import Testing

@testable import BlueBubblesApp

@Suite("Integrations model")
@MainActor
struct IntegrationsModelTests {

  @Test("A connection method chosen elsewhere shows as selected here")
  func followsExternalWrites() async throws {
    let store = try await SettingsStore(
      database: try AppDatabase.inMemory(contributors: [SettingsSchema.self]),
      secrets: InMemorySecretStore()
    )
    let model = IntegrationsModel()
    await model.attach(store)
    await model.refresh()
    #expect(!model.isEnabled(BuiltInManifests.tailscale))

    // Written straight to the store, the way the Connection page does it.
    try await store.set(Settings.connectionMethod, to: BuiltInManifests.tailscale.id.rawValue)

    // The change arrives on a stream; give it a moment, but not a long one.
    for _ in 0..<40 where !model.isEnabled(BuiltInManifests.tailscale) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.isEnabled(BuiltInManifests.tailscale))
    #expect(!model.isEnabled(BuiltInManifests.cloudflare))

    model.detach()
  }
}

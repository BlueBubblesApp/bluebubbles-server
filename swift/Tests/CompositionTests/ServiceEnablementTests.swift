//  ServiceEnablementTests
//  Reading `disabled_services`, and the services it is not allowed to touch.
//
//  The value is reachable from the settings API and the CLI as well as from the Integrations
//  screen, so it arrives hand-typed as often as not — and a core service named in it must be
//  refused rather than honoured, because honouring it is how a headless server ends up with
//  no way back onto the network.

import BBPersistence
import BBServiceKit
import BBSettings
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Service enablement")
struct ServiceEnablementTests {

  @Test("A disabled identifier is read out of the stored list")
  func parsesTheStoredValue() {
    let disabled = ServiceEnablement.disabledIdentifiers(
      in: "app.bluebubbles.sink.webhooks,app.bluebubbles.sink.push"
    )
    #expect(disabled.count == 2)
    #expect(disabled.contains(BuiltInManifests.ID.webhooks.rawValue))

    #expect(
      !ServiceEnablement.isEnabled(
        BuiltInManifests.ID.webhooks, disabled: disabled
      ))
    #expect(
      ServiceEnablement.isEnabled(
        BuiltInManifests.ID.scheduledMessages, disabled: disabled
      ))
  }

  @Test("Hand-typed spacing and empties are tolerated")
  func parsingIsForgiving() {
    // What a `--set disabled_services="a, b"` produces, and what an empty setting — the
    // overwhelmingly common case — produces.
    let spaced = ServiceEnablement.disabledIdentifiers(
      in: " app.bluebubbles.sink.webhooks , app.bluebubbles.sink.push ,, "
    )
    #expect(
      spaced == [
        BuiltInManifests.ID.webhooks.rawValue, BuiltInManifests.ID.push.rawValue,
      ])
    #expect(ServiceEnablement.disabledIdentifiers(in: "").isEmpty)
    #expect(ServiceEnablement.disabledIdentifiers(in: "   ").isEmpty)
  }

  @Test("A core service stays on however the setting is written")
  func coreServicesCannotBeDisabled() {
    // The whole list, written by someone who meant it. Every one of these must still run.
    let disabled = ServiceEnablement.disabledIdentifiers(
      in: BuiltInManifests.alwaysOn.map(\.rawValue).joined(separator: ",")
    )
    for id in BuiltInManifests.alwaysOn {
      #expect(
        ServiceEnablement.isEnabled(id, disabled: disabled),
        "\(id.rawValue) must stay enabled"
      )
    }
  }

  @Test("The screen offers exactly the switches the server honours")
  func catalogAgreesWithTheServer() {
    // Two lists of "which services are core" is how a screen ends up offering a switch
    // that the thing behind it ignores. This is the test that keeps them one list.
    #expect(BuiltInManifests.alwaysOn.contains(BuiltInManifests.ID.socket))
    #expect(!BuiltInManifests.alwaysOn.contains(BuiltInManifests.ID.webhooks))
    // The HTTP API is switchable ON PURPOSE — an operator may want the server to stop
    // serving, and the app keeps working because it talks to the interfaces in-process.
    #expect(!BuiltInManifests.alwaysOn.contains(BuiltInManifests.ID.http))
  }

  @Test("Switching off the HTTP API is honoured")
  func httpCanBeDisabled() {
    let disabled = ServiceEnablement.disabledIdentifiers(in: BuiltInManifests.ID.http.rawValue)
    #expect(
      !ServiceEnablement.isEnabled(
        BuiltInManifests.ID.http, disabled: disabled
      ))
    // And the socket beside it is not collateral: they are separate switches.
    #expect(
      ServiceEnablement.isEnabled(
        BuiltInManifests.ID.socket, disabled: disabled
      ))
  }

  // MARK: - The seam between the app and the server

  @Test("What the Integrations screen writes is what the server reads")
  func roundTripsThroughTheStore() async throws {
    // The one seam in this feature: the app WRITES this value and the server READS it,
    // through two accessors that only agree by convention. A stored value is not a bare
    // string on disk — an encoding difference between the two sides would show up as a
    // switch that visibly moves and changes nothing, which is the exact bug this whole
    // change exists to fix.
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(
      database: database, secrets: InMemorySecretStore()
    )
    let webhooks = BuiltInManifests.ID.webhooks

    // Untouched: every service runs. This is the state of a fresh install, and it is
    // also what an empty stored value must mean.
    #expect(await ServiceEnablement.isEnabled(webhooks, settings: store))

    // Written exactly as `AppModel.toggle` writes it.
    try await store.set(
      BuiltInManifests.ID.webhooks.rawValue,
      forKey: Settings.disabledServicesKey,
      isSecret: false
    )
    #expect(await !ServiceEnablement.isEnabled(webhooks, settings: store))

    // And switched back on, which is the half that had no reader at all.
    try await store.set("", forKey: Settings.disabledServicesKey, isSecret: false)
    #expect(await ServiceEnablement.isEnabled(webhooks, settings: store))
  }

  @Test("Every reverse proxy depends on the HTTP API")
  func proxiesDependOnHTTP() {
    // This is what makes switching HTTP off take the proxies down with it rather than
    // leaving a public address that resolves, connects, and fails. If a proxy ever stops
    // declaring the dependency, the registry has no way to know to stop it.
    let proxies = BuiltInManifests.all.filter { $0.category == .reverseProxy }
    #expect(!proxies.isEmpty)
    for proxy in proxies {
      #expect(
        proxy.dependencies.contains(BuiltInManifests.ID.http),
        "\(proxy.id.rawValue) must declare its dependency on the HTTP API"
      )
    }
  }
}

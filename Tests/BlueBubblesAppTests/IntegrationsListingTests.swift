//  IntegrationsListingTests
//  What the Integrations screen lists, and what it asks before switching a service off.
//
//  `IntegrationCatalog` is an app type, so these assertions live with the app's tests rather
//  than in `CompositionTests`, which does not link the SwiftUI app.

import BBBuiltIns
import BBSettings
import Testing

@testable import BlueBubblesApp

@Suite("What the Integrations screen shows")
struct IntegrationsListingTests {

  @Test("Every listed service falls into a category the screen renders")
  func everyManageableCategoryIsRendered() {
    // The failure this catches is the one that keeps recurring: a manifest is written, is
    // valid, is started by the registry, and appears on no screen, because its category
    // was never added to the list the view iterates. Adding `.networking` is exactly the
    // change that could have caused it.
    for manifest in IntegrationCatalog.manageable {
      #expect(
        IntegrationCatalog.categories.contains(manifest.category),
        "\(manifest.id) is in a category the Integrations screen never renders"
      )
    }
  }

  @Test("Services that only carry out a setting are not listed")
  func settingBackedServicesAreHidden() {
    // Keep Awake and Start at Login do nothing except act on a settings row, and
    // Permissions reports what macOS granted. Listing them gave each a second switch next
    // to the real one, and the two could disagree.
    let hidden = [
      BuiltInManifests.ID.sleepPrevention,
      BuiltInManifests.ID.launchAtLogin,
      BuiltInManifests.ID.permissions,
    ]
    let listed = Set(IntegrationCatalog.manageable.map(\.id))
    for id in hidden {
      #expect(!listed.contains(id), "\(id) should not be an integration")
    }
  }

  @Test("Each hidden setting-backed service still has the settings row that controls it")
  func hiddenServicesKeepTheirControl() {
    // The other half. Hiding them from Integrations is only correct because the setting
    // is the control: if that row were also missing, the feature would be unreachable.
    let keys = Set(Settings.renderable.map(\.key))
    #expect(keys.contains("auto_caffeinate"))
    #expect(keys.contains("auto_start_method"))
  }

  @Test("The networking category holds the two interfaces clients talk to")
  func networkingCategory() {
    let networking = Set(
      BuiltInManifests.all.filter { $0.category == .networking }.map(\.id)
    )
    #expect(networking == [BuiltInManifests.ID.http, BuiltInManifests.ID.socket])

    // The HTTP API CAN be switched off, and that is a deliberate reversal: an operator
    // may want the server to stop serving, the app keeps working either way because it
    // talks to the interfaces in-process, and a headless install can undo it with
    // `--set disabled_services=`. The switch asks first; see `disableWarning`.
    #expect(IntegrationCatalog.canDisable(BuiltInManifests.http))
    #expect(IntegrationCatalog.disableWarning(for: BuiltInManifests.http) != nil)

    // The socket is switchable too, and used not to be: on the grounds that it is how a
    // connected client is told anything at all. True, and not a reason: a REST-only server
    // is a real deployment, and the API the socket depends on has always been switchable.
    // "Off" leaves a working server that answers over HTTP and pushes nothing.
    #expect(IntegrationCatalog.canDisable(BuiltInManifests.socket))
    // No confirmation, because the consequence IS visible from the switch: the manifest's
    // own details say what stops and what does not. The HTTP API asks because its
    // consequence (clients cannot reach this server at all) is not.
    #expect(IntegrationCatalog.disableWarning(for: BuiltInManifests.socket) == nil)

    // Nothing else asks before switching off. A dialog on every toggle is a dialog
    // everyone learns to dismiss.
    for manifest in IntegrationCatalog.manageable where manifest.id != BuiltInManifests.ID.http {
      #expect(
        IntegrationCatalog.disableWarning(for: manifest) == nil,
        "\(manifest.id) should switch off without a confirmation"
      )
    }
  }

  @Test("Start at Login is off by default")
  func startAtLoginDefaultsOff() {
    // A server that silently registers a login item after an install is a surprise, and
    // an unwelcome one on a Mac someone else also uses. Onboarding asks; nothing assumes.
    #expect(Settings.autoStartMethod.defaultValue == .none)
  }
}

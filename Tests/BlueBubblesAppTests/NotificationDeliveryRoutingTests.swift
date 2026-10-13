//  NotificationDeliveryRoutingTests
//  Where each notification route's configuration lives.
//
//  Two failures worth guarding, and the second is the one that was actually shipped for a
//  few minutes. A route can render a button leading nowhere — routed to a manifest form it
//  has no fields for, so Configure opens an empty sheet. And the LIST can be wrong: the page
//  was built from `manifests(in: .eventSink)`, which put webhooks on a page about
//  notifications, because being an event sink is a capability any integration can hold and
//  not a statement about who reads what it delivers.

import BBBuiltIns
import BBServiceKit
import Testing

@testable import BlueBubblesApp

@Suite("Notification delivery routing")
struct NotificationDeliveryRoutingTests {

  @Test("Every listed route has somewhere to configure it")
  func everyRouteIsConfigurable() {
    let routes = NotificationDeliveryRouting.routes
    #expect(!routes.isEmpty, "no routes found; this suite would pass vacuously")
    for manifest in routes {
      #expect(
        NotificationDeliveryRouting.hasSomethingToConfigure(manifest),
        "\(manifest.name) routes to a form with no fields, so Configure opens an empty sheet"
      )
    }
  }

  /// The rule the page is actually about: a notification somebody READS.
  ///
  /// Webhooks is the case that makes it a rule rather than a coincidence. It is an event
  /// sink — same `receiveEvents` entitlement, same category — and what it delivers is a JSON
  /// body to a machine. Selecting by category put it on this page, which is how the wrong
  /// question showed up as a wrong answer.
  @Test("Webhooks is an event sink and is deliberately NOT a notification route")
  func webhooksIsNotANotificationRoute() {
    #expect(BuiltInManifests.webhooks.category == .eventSink)
    #expect(!NotificationDeliveryRouting.routes.contains { $0.id == BuiltInManifests.ID.webhooks })
  }

  /// Firebase setup is a guided run of several minutes, not a settings form, and
  /// reproducing it as one on a second screen is the drift this routing avoids.
  @Test("Push goes to the page it already has")
  func pushGoesToFirebase() {
    #expect(
      NotificationDeliveryRouting.destination(for: BuiltInManifests.push) == .page(.firebase))
  }

  /// ntfy is the case the default exists for: its configuration IS its manifest, which is
  /// the whole point of moving it out of the four core `ntfy_*` settings.
  @Test("A sink configured by its manifest gets the form")
  func manifestDrivenSinksGetTheForm() {
    #expect(
      NotificationDeliveryRouting.destination(for: BuiltInManifests.ntfy) == .configurationForm)
    #expect(!BuiltInManifests.ntfy.fields.isEmpty)
  }

  /// Resolved through the catalog, so a route named here but absent from this build is
  /// simply not listed rather than crashing the page.
  @Test("The listed routes are push and ntfy, resolved through the catalog")
  func routesResolveThroughTheCatalog() {
    #expect(
      NotificationDeliveryRouting.routes.map(\.id)
        == [BuiltInManifests.ID.push, BuiltInManifests.ID.ntfy])
    for id in NotificationDeliveryRouting.identifiers {
      #expect(IntegrationCatalog.manifest(id) != nil, "\(id.rawValue) is named but not built")
    }
  }

  /// The fields ntfy's service reads by name. A typo on either side reads as "not
  /// configured" rather than as an error, which is the quietest way for this to break.
  @Test("ntfy declares exactly the fields its service reads")
  func ntfyFieldsMatchTheService() {
    let declared = Set(BuiltInManifests.ntfy.fields.map(\.key))
    #expect(declared == ["topic", "server", "token", "events"])
    // The token is the one that must be stored as a secret: carried across as a plain
    // value it would be a downgrade in storage nobody asked for.
    #expect(BuiltInManifests.ntfy.fields.first { $0.key == "token" }?.isSecret == true)
    // The events field is why `FieldKind.eventSubscription` was added while the manifest
    // surface is frozen: a `multiSelect` cannot express "and whatever a later version adds".
    #expect(BuiltInManifests.ntfy.fields.first { $0.key == "events" }?.kind == .eventSubscription)
  }
}

//  NotificationDeliveryRouting
//  Where each notification route's configuration actually lives.
//
//  The Notifications settings page used to be the ntfy form and nothing else: four settings,
//  no mention of Firebase or webhooks, and no way to tell from it that this server has three
//  ways of delivering an event. ntfy is an integration of its own now, so those four settings
//  went with it, and what is left is the honest shape of the page — a list of the delivery
//  routes, and a way into each one's configuration.
//
//  ## Why this is a list and not a category query
//
//  It was `IntegrationCatalog.manifests(in: .eventSink)`, and that is the wrong question.
//  Being an event sink is a CAPABILITY — the `receiveEvents` entitlement — and any
//  integration can hold one whatever its category says it is for. Webhooks is the proof and
//  is why the category query was visibly wrong: it is an event sink, and what it delivers is
//  a JSON body to a machine. Nobody reads it, nothing buzzes, and it does not belong on a
//  page about notifications.
//
//  What this page is about is narrower than a category: the routes that put a notification in
//  front of a PERSON. Two of them today, named here, because there is no way to declare it —
//  the manifest surface is frozen, and a property meaning "this delivers to a human" is
//  exactly the kind of field the freeze exists to keep out until plugins are real. When they
//  are, this becomes a manifest flag and the list goes away.
//
//  Routing is then a decision rather than a constant, because one of the two has a page.
//  Firebase setup is a guided run that takes minutes, not a settings form, and reproducing it
//  as one on a second screen is the drift this avoids. ntfy's configuration IS its manifest,
//  so it gets the same sheet Configure ngrok opens.
//
//  Off the view so the invariant below is testable: see `Sources/BlueBubblesApp/CLAUDE.md`.

import BBBuiltIns
import BBServiceKit

/// Where a delivery route is configured.
enum NotificationDeliveryDestination: Equatable {
  /// A page of its own. The button navigates there.
  case page(Destination)
  /// The manifest's own form, in a sheet.
  case configurationForm
}

enum NotificationDeliveryRouting {

  /// The routes that deliver a notification somebody reads, in the order the page shows
  /// them: push first, because it is the one most installs use and the one clients expect.
  ///
  /// Through the catalog, never `BuiltInManifests.all` directly, so a route that is not in
  /// this build simply is not listed rather than crashing the page.
  static let identifiers: [ServiceIdentifier] = [
    BuiltInManifests.ID.push,
    BuiltInManifests.ID.ntfy,
  ]

  static var routes: [ServiceManifest] {
    identifiers.compactMap { IntegrationCatalog.manifest($0) }
  }

  /// Where this one is configured.
  ///
  /// The default is the form, not a page: a sink that arrives without this file being edited
  /// is one whose configuration IS its manifest, which is what a manifest is for. A page has
  /// to be claimed by id, because a page is something somebody wrote.
  static func destination(for manifest: ServiceManifest) -> NotificationDeliveryDestination {
    switch manifest.id {
    case BuiltInManifests.ID.push: .page(.firebase)
    default: .configurationForm
    }
  }

  /// Whether pressing Configure will show this route anything.
  ///
  /// The failure it names is the one this page invites: a sink with no page and no declared
  /// fields routes to a form with nothing in it, so the button opens an empty sheet. Asked
  /// here rather than discovered by clicking, and asserted for every built-in sink by
  /// `NotificationDeliveryRoutingTests`.
  static func hasSomethingToConfigure(_ manifest: ServiceManifest) -> Bool {
    switch destination(for: manifest) {
    case .page: true
    case .configurationForm: !manifest.fields.isEmpty
    }
  }
}

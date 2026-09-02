//  IntegrationCatalog
//  Which services the Integrations screen shows, and in what order.
//
//  Off the view for the same reason `AlertActionRouting` and `NetworkAddressChoices` are:
//  touching a SwiftUI `View` type from a test process traps, so policy that deserves a test
//  cannot live as a static on the view that uses it.
//
//  And this policy does deserve one. The recurring failure in this project is a component that
//  is written, valid, started — and rendered by nothing; a manifest whose category is missing
//  from `categories` is exactly that, and it is a one-line omission when adding a category.
//
//  See `docs/EVENTS.md` and `.claude/docs/architecture.md`.

import BBInterfaces
import BBServiceKit
import BlueBubblesServerCore

enum IntegrationCatalog {

  /// What belongs on the Integrations screen.
  ///
  /// Keep Awake, Start at Login and Permissions are services but not integrations. Two of
  /// them exist only to act on a settings row, and the third reports what macOS granted —
  /// listing them put a second switch beside the real one, and the two could disagree.
  static var manageable: [ServiceManifest] {
    BuiltInManifests.all.filter(\.isUserManageable)
  }

  /// Ordered as someone setting up would work through them, not alphabetically.
  ///
  /// Networking is late deliberately: the HTTP API and the socket are what the server IS
  /// rather than things anyone chooses, so they belong below the choices.
  static let categories: [ServiceCategory] = [
    .reverseProxy, .eventSink, .messaging, .messageSource, .contacts, .integration,
    .networking, .system,
  ]

  static func manifests(in category: ServiceCategory) -> [ServiceManifest] {
    manageable.filter { $0.category == category }.sorted { $0.name < $1.name }
  }

  static func manifest(_ id: ServiceIdentifier) -> ServiceManifest? {
    manageable.first { $0.id == id }
  }

  /// The integration page to send someone to for a given external program.
  ///
  /// Alerts about a program name the TOOL, not a service — the program is what needs
  /// attention, and more than one service may declare the same one. This is where that is
  /// resolved into somewhere to navigate.
  static func manifestDeclaring(tool toolID: String) -> ServiceManifest? {
    manageable.first { $0.tools.contains { $0.id == toolID } }
  }

  /// Core services that cannot be switched off from here.
  ///
  /// Disabling the HTTP API would take the server off the network with no way to reach the
  /// screen that turns it back on, so it is not offered — better than offering it and
  /// refusing, or offering it and honouring it.
  ///
  /// Reads the SERVER's list rather than repeating it. The server enforces the same set
  /// when it decides what to start, and two copies of "which services are core" is how a
  /// screen ends up offering a switch that the thing behind it ignores.
  static func canDisable(_ manifest: ServiceManifest) -> Bool {
    !BuiltInManifests.alwaysOn.contains(manifest.id)
  }

  /// What to say before switching something off, when the consequence is not visible from
  /// the switch.
  ///
  /// Only for the ones where "off" means something stops working for someone ELSE — a
  /// client on a phone that will simply fail to connect, with nothing on this screen
  /// showing it. Everything else switches off without ceremony; a dialog on every toggle
  /// teaches people to dismiss the dialog.
  static func disableWarning(for manifest: ServiceManifest) -> String? {
    guard manifest.id == BuiltInManifests.ID.http else { return nil }
    return "Clients will not be able to reach this server: the REST API stops listening, "
      + "and any reverse proxy that depends on it stops with it. This window keeps "
      + "working, and you can switch it back on here. On a server with no screen, the "
      + "way back is `bluebubbles-server --set disabled_services=` from the command line."
  }
}

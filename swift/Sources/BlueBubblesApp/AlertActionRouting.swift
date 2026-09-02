//  AlertActionRouting
//  Where an alert's `.openSettings(_:)` actually goes.
//
//  Extracted from the view so it can be asserted without a SwiftUI host. The destination is
//  an enum declared beside the alert, so this switch is exhaustive: a case added there does
//  not compile until it lands on a page here, which is the failure this file was extracted to
//  prevent — a button that appears to work and does not.
//
//  See `docs/AUTH.md`.

import BBDiagnostics

enum AlertActionRouting {

  /// Where a remedy button lands: a page, and optionally a tab within it.
  ///
  /// The tab exists because Permissions stopped being a page. "Open Permissions" that lands
  /// on Settings/General is a button that appears to work and does not.
  struct Route: Equatable {
    var destination: Destination
    var settingsTab: SettingsTab?
  }

  static func route(for destination: AlertDestination) -> Route {
    switch destination {
    case .settings: Route(destination: .settings)
    case .security: Route(destination: .settings, settingsTab: .security)
    case .features: Route(destination: .settings, settingsTab: .general)
    case .permissions: Route(destination: .settings, settingsTab: .permissions)
    case .webhooks: Route(destination: .webhooks)
    case .push: Route(destination: .firebase)
    }
  }
}

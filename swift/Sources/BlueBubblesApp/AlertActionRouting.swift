//  AlertActionRouting
//  Where an alert's `.openSettings(section:)` actually goes.
//
//  Extracted from the view so it can be asserted without a SwiftUI host. The section strings
//  are written by whoever raises the alert — free text, in a different module — so the mapping
//  is the one place they and the sidebar have to agree, and the one place worth a test.
//
//  See `docs/AUTH.md`.

enum AlertActionRouting {

  /// Where a remedy button lands: a page, and optionally a tab within it.
  ///
  /// The tab exists because Permissions stopped being a page. "Open Permissions" that lands
  /// on Settings/General is a button that appears to work and does not — the same failure
  /// this file was extracted to prevent.
  struct Route: Equatable {
    var destination: Destination
    var settingsTab: SettingsTab?
  }

  /// The route for a section name, or nil if it names nothing.
  ///
  /// Callers fall back to Settings rather than doing nothing: a button that appears and then
  /// does nothing is worse than one that lands somewhere approximately right.
  static func route(forSection section: String) -> Route? {
    switch section.lowercased() {
    case "security": Route(destination: .settings, settingsTab: .security)
    case "webhooks", "api": Route(destination: .webhooks)
    case "permissions": Route(destination: .settings, settingsTab: .permissions)
    // "notifications" means push setup here; the alert LIST is a popover now
    // and is not a destination at all.
    case "notifications", "firebase", "push": Route(destination: .firebase)
    case "contacts": Route(destination: .contacts)
    case "devices": Route(destination: .devices)
    case "logs": Route(destination: .logs)
    case "guides": Route(destination: .guides)
    case "settings": Route(destination: .settings)
    default: nil
    }
  }
}

//  SettingsTabs
//  How the settings screen is divided.
//
//  One scrolling page of eleven sections was a page nobody read to the bottom of. Splitting it
//  means deciding what belongs together, which is a judgement this file states once rather than
//  leaving implicit in the order settings happen to be declared in.
//
//  Permissions live here rather than in the sidebar. They ARE settings (the answer to "what is
//  this app allowed to do on this Mac") and a top-level page for them put a permanent row in
//  the sidebar for something most people touch once during setup.
//
//  Deliberately NOT a View, so the mapping can be asserted from a test process. Touching a
//  SwiftUI `View` type from a test traps; the same reason `AlertActionRouting` is its own file.
//
//  See `.claude/docs/architecture.md` and `docs/AUTH.md`.

import BBSettings

/// No raw value: the case is the identity, and the title is a label that can be reworded
/// without renaming what a tab is selected or routed by.
enum SettingsTab: CaseIterable, Identifiable, Hashable {
  case general
  case connection
  case privateAPI
  case notifications
  case security
  case permissions
  case advanced

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .connection: "Connection"
    case .privateAPI: "Private API"
    case .notifications: "Notifications"
    case .security: "Security"
    case .permissions: "Permissions"
    case .advanced: "Advanced"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .connection: "network"
    case .privateAPI: "wand.and.rays"
    case .notifications: "bell"
    case .security: "lock.shield"
    case .permissions: "hand.raised"
    case .advanced: "wrench.and.screwdriver"
    }
  }

  /// The registry sections this tab shows, in the order it shows them.
  ///
  /// Named explicitly rather than derived, because the grouping is editorial: the three
  /// helper-backed sections sit on the Private API tab not because of anything in their
  /// declarations but because that is what someone looking for them would consider them
  /// part of. `SettingSection` cases, so a section the registry adds is a compile error
  /// here until it is placed; `SettingsTabTests` proves every case is claimed once.
  var sections: [SettingSection] {
    switch self {
    case .general: [.features, .updates]
    case .connection: [.connection]
    // Grouped by the APP each block configures, not by the mechanism they share. Every
    // setting here does the same thing under the hood (inject a dylib and talk to it) so
    // a "Private API" section listing all of them told the user nothing about which app a
    // toggle affected. New hosts get a section of their own rather than another line in a
    // shared list.
    // Find My belongs here for the same reason the other two do: its routes require the
    // helper, so it is a third app whose Private API surface is configured, not a separate
    // kind of setting.
    case .privateAPI: [.messages, .faceTime, .findMy]
    case .notifications: [.notifications]
    case .security: [.security]
    // Native grants, not stored settings: this tab has no registry sections at all.
    case .permissions: []
    // The helper dylib paths are every member of `.privateAPI`, all internal, so that
    // section never renders; it is placed here so the placement is stated rather than
    // falling through.
    case .advanced: [.advanced, .debug, .privateAPI]
    }
  }

  /// The tab a section belongs to.
  ///
  /// Still TOTAL, with Advanced as the fallback, even though `SettingsTabTests` proves every
  /// case is claimed: a section added to the registry and forgotten here would otherwise
  /// vanish from the app entirely (a setting that exists, is saved, is read by the server,
  /// and has no screen) and the test only runs once someone runs it.
  static func containing(section: SettingSection) -> SettingsTab {
    allCases.first { $0.sections.contains(section) } ?? .advanced
  }
}

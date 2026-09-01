//  SettingsTabs
//  How the settings screen is divided.
//
//  One scrolling page of eleven sections was a page nobody read to the bottom of. Splitting it
//  means deciding what belongs together, which is a judgement this file states once rather than
//  leaving implicit in the order settings happen to be declared in.
//
//  Permissions live here rather than in the sidebar. They ARE settings — the answer to "what is
//  this app allowed to do on this Mac" — and a top-level page for them put a permanent row in
//  the sidebar for something most people touch once during setup.
//
//  Deliberately NOT a View, so the mapping can be asserted from a test process. Touching a
//  SwiftUI `View` type from a test traps; the same reason `AlertActionRouting` is its own file.
//
//  See `.claude/docs/architecture.md` and `docs/AUTH.md`.

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
  case general = "General"
  case connection = "Connection"
  case privateAPI = "Private API"
  case notifications = "Notifications"
  case security = "Security"
  case permissions = "Permissions"
  case advanced = "Advanced"

  var id: String { rawValue }

  var title: String { rawValue }

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
  /// Named explicitly rather than derived, because the grouping is editorial: "Private API"
  /// and "Database" sit under Messages not because of anything in their declarations but
  /// because that is what someone looking for them would consider them part of.
  var sections: [String] {
    switch self {
    case .general: ["Features", "Updates"]
    case .connection: ["Connection"]
    // Grouped by the APP each block configures, not by the mechanism they share. Every
    // setting here does the same thing under the hood — inject a dylib and talk to it — so
    // a "Private API" section listing all of them told the user nothing about which app a
    // toggle affected. New hosts get a section of their own rather than another line in a
    // shared list.
    // Find My belongs here for the same reason the other two do: its routes require the
    // helper, so it is a third app whose Private API surface is configured, not a separate
    // kind of setting. Dropping it from this list is what the "every section belongs to a
    // tab" test caught.
    case .privateAPI: ["Messages", "FaceTime", "Find My"]
    case .notifications: ["Notifications"]
    case .security: ["Security"]
    // Native grants, not stored settings — this tab has no registry sections at all.
    case .permissions: []
    case .advanced: ["Advanced", "Debug"]
    }
  }

  /// The tab a section belongs to.
  ///
  /// TOTAL on purpose. A section added to the registry and forgotten here would otherwise
  /// vanish from the app entirely — a setting that exists, is saved, is read by the server,
  /// and has no screen. That exact failure (code complete, connected to nothing) has turned
  /// up in every phase of this migration, so the fallback puts strays somewhere visible
  /// instead of nowhere.
  static func containing(section: String) -> SettingsTab {
    allCases.first { $0.sections.contains(section) } ?? .advanced
  }
}

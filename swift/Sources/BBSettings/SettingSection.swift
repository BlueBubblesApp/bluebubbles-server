//  SettingSection
//  The groups the settings screen is divided into.
//
//  A type rather than a string on each declaration. As strings, the section name was the
//  join between three places (the registry, the tab that shows the section, and the
//  sentence under the section's header) and nothing checked the join: rename one and the
//  subtitle vanished silently, or the rows fell through to the Advanced tab. As a case, a
//  renamed section is a compile error in every place that names it, and the app's
//  `SettingSectionCoverageTests` can walk `allCases` to prove each one has a tab.
//
//  The title is computed, not the raw value: the case is the identity and the words are a
//  label that can be reworded without renaming anything switched on.

/// A group of settings, as the settings screen shows them.
public enum SettingSection: CaseIterable, Sendable, Hashable {
  case connection
  case security
  /// Private API for Messages.app. Named for the app rather than the mechanism; see
  /// `SettingsTab` in the app for why the three helper-backed sections are per app.
  case messages
  case faceTime
  case findMy
  /// The helper dylib paths. Every member is internal, so this never renders; it exists so
  /// the two declarations have a section that is theirs rather than borrowing one.
  case privateAPI
  case notifications
  case features
  case updates
  case advanced
  case debug

  /// The header over the group.
  public var title: String {
    switch self {
    case .connection: "Connection"
    case .security: "Security"
    case .messages: "Messages"
    case .faceTime: "FaceTime"
    case .findMy: "Find My"
    case .privateAPI: "Private API"
    case .notifications: "Notifications"
    case .features: "Features"
    case .updates: "Updates"
    case .advanced: "Advanced"
    case .debug: "Debug"
    }
  }

  /// One sentence under the header, so it says what the group is FOR.
  ///
  /// Written here rather than on each setting because it describes the group, and repeating
  /// it on every member would be noise. Every case has one: a section with no explanation
  /// used to be the silent outcome of a rename, and the type exists so that cannot happen.
  public var summary: String {
    switch self {
    case .connection: "How clients reach this server, and what it listens on."
    case .security: "Passwords, encryption, and who is allowed to connect."
    // Both sit on the Private API tab, so each subtitle names the APP it configures rather
    // than repeating the mechanism the page header already explains.
    case .messages: "Reactions, editing, unsending, typing indicators and group management."
    case .faceTime: "Answering, generating links, and handing calls to a client."
    case .findMy: "Reading locations, and sharing this Mac's location out."
    case .privateAPI: "Where the helper libraries are loaded from."
    case .notifications: "Delivery to clients that are not currently connected."
    case .features: "Optional behaviour."
    case .updates: "How this server updates itself."
    case .advanced: "Settings most installs never need to change."
    case .debug: "Diagnostics and logging."
    }
  }
}

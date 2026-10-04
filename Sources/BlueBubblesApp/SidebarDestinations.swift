//  SidebarDestinations
//  Which pages the sidebar offers, and where the selection goes when one of them leaves.
//
//  Every page but one is always there. The Audit Log is the exception: it is a view of a
//  feature that ships switched off, and a row for an empty table that says "turn the feature
//  on" is a row most installs would see for ever. So the row appears when the audit log is
//  on and goes when it is off, and this type is the rule for both, off the view so a test can
//  assert it without touching SwiftUI.
//
//  Two decisions worth stating. Unknown is HIDDEN: before the server has started nothing has
//  read the switch, and a row that appears on launch and vanishes when the server reads its
//  settings is worse than one that appears once the answer is known. And a selected page that
//  leaves falls back to Home rather than to the nearest row, because "nearest" depends on an
//  order the person did not choose.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import Foundation

enum SidebarDestinations {

  /// The rows, in sidebar order.
  ///
  /// - Parameter auditLogEnabled: Whether the audit log is switched on, or nil when nothing
  ///   has read the switch yet (the server is not running).
  static func visible(auditLogEnabled: Bool?) -> [Destination] {
    Destination.allCases.filter { destination in
      switch destination {
      case .auditLog: auditLogEnabled == true
      default: true
      }
    }
  }

  /// Where the selection goes once the rows have changed: unchanged while its row is still
  /// there, Home otherwise.
  static func resolvedSelection(_ current: Destination, visible: [Destination]) -> Destination {
    visible.contains(current) ? current : .home
  }

  /// The pages ⌘1 to ⌘9 reach, in order. Settings is excluded BY NAME rather than by
  /// falling off the end: it has ⌘, already, and when a row leaves the list a `prefix(9)` on
  /// its own would quietly hand Settings a second shortcut.
  static func shortcutPages(visible: [Destination]) -> [Destination] {
    Array(visible.filter { $0 != .settings }.prefix(9))
  }
}

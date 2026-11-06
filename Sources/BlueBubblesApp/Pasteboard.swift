//  Pasteboard
//  The one door to the general pasteboard.
//
//  Four places wrote `clearContents()` then `setString(_:forType:)` by hand (the copyable
//  value, the menu bar's address, the log viewer, a diagnostic report). Both halves are
//  needed: `setString` without the clear APPENDS a representation to whatever another app
//  put there, and the paste that follows can pick the other app's. One function, so no copy
//  forgets the clear. `SharedComponentPolicyTests` refuses `NSPasteboard` anywhere else.

import AppKit

enum Pasteboard {
  /// Replaces the general pasteboard's contents with `text`.
  ///
  /// Copying an empty string looks like it worked and pastes nothing, so a caller with
  /// nothing to copy disables its control rather than calling this; see `CopyableValue`.
  @MainActor
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

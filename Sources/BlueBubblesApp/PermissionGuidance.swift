//  PermissionGuidance
//  What the Permissions page calls each state, and what it tells someone to do about it.
//
//  The guidance is deliberately SPECIFIC rather than generic. "Grant this permission" tells
//  someone nothing they had not worked out; "macOS will not prompt for this one, add the app
//  yourself" is the fact that unsticks Full Disk Access, and it is the difference between a
//  page that helps and a page that restates the problem.
//
//  Both were `private var`s on a row inside `PermissionsSettings`, so neither the wording nor
//  the one state-dependent branch in it had a test.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBSystem

enum PermissionGuidance {

  static func statusLabel(_ status: PermissionStatus) -> String {
    switch status {
    case .granted: "Granted"
    case .denied: "Denied"
    case .restricted: "Restricted"
    case .notDetermined: "Not set"
    // Distinct from "not set": the probe could not determine the answer at all, which for
    // Automation means Messages.app was not found.
    case .unknown: "Unknown"
    }
  }

  /// What to actually do, per permission and per state.
  ///
  /// Takes the whole permission, not just its id: the fallback is the manifest's own `why`
  /// sentence, which is the one a service author wrote for it.
  static func guidance(
    for permission: Permission, status: PermissionStatus
  ) -> String {
    switch permission.id {
    case .fullDiskAccess:
      return """
        macOS will not prompt for this one. Open System Settings, click +, and add \
        BlueBubbles yourself, then relaunch, because the grant only takes effect \
        when the app next starts.
        """
    case .automationMessages:
      // The one branch that depends on the state: once denied, macOS never asks again, so
      // "allow the prompt" is advice for a prompt that will not come.
      return status == .denied
        ? """
        Previously denied. macOS will not ask again, so this has to be re-enabled \
        by hand under Privacy & Security → Automation.
        """
        : "Needed to send messages when the Private API is not available."
    case .systemIntegrityProtection:
      return """
        Read-only. Disabling System Integrity Protection is done from Recovery and \
        is your decision; without it the server still runs, sends and receives; \
        reactions, edit and unsend, typing indicators and group management do not.
        """
    default:
      // Same "macOS will not ask again" rule as Automation, over whatever the manifest
      // says this permission is for.
      return status == .denied
        ? "Previously denied. macOS will not ask again; re-enable it in System Settings."
        : permission.why
    }
  }
}

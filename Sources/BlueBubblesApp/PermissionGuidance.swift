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

import BBServiceKit
import BBSystem

enum PermissionGuidance {

  /// What a service declares and does not have, for the page that offers to fix it.
  ///
  /// `.feature` is left out: it is needed for one named thing, and listing it would put a
  /// System Integrity Protection row on a page that runs without it. A status not yet read or
  /// a probe that could not run says nothing about what is missing, so neither counts; that is
  /// why this asks `isDefiniteRefusal` rather than `!= .granted`.
  static func unmet(
    by manifest: ServiceManifest, in list: [Permission],
    statuses: [PermissionID: PermissionStatus]
  ) -> [Permission] {
    let wanted = manifest.permissions.filter { declared in
      switch declared.requirement {
      case .required, .recommended: true
      case .feature: false
      }
    }.map(\.id)
    return list.filter { permission in
      wanted.contains(permission.id) && statuses[permission.id]?.isDefiniteRefusal == true
    }
  }

  /// Whether a permission this service cannot start without is what it is waiting for.
  ///
  /// Asked of the declaration and the probe, never of the sentence in `inactive(reason:)`.
  static func isAwaitingRequired(
    _ manifest: ServiceManifest, statuses: [PermissionID: PermissionStatus]
  ) -> Bool {
    manifest.permissions.contains { declared in
      declared.requirement.isRequired && statuses[declared.id]?.isDefiniteRefusal == true
    }
  }

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
        BlueBubbles yourself. The server picks it up as soon as macOS reports it. If \
        this still says Denied afterwards, macOS is holding it until the app next \
        starts: relaunch BlueBubbles.
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

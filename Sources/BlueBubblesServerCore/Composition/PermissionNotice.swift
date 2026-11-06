//  PermissionNotice
//  What is said about a permission that has not been answered, and the keys of every notice
//  that says one is missing.
//
//  `UnansweredContacts` is the whole of the decision about when Contacts is asked for. It sits
//  here rather than in `ContactsService`, because the point of it is that the service does not
//  ask, and off `RunningServer` so it can be asserted: no test can drive the real TCC prompt.
//
//  The keys are one list because raising a notice and withdrawing it happen in different files,
//  and a key written by hand at a raise site is a notice nothing withdraws.

import BBDiagnostics
import BBServiceKit
import BBSystem

enum PermissionNotice {

  enum Key {
    /// A required permission taken away, raised by `PermissionsMonitorService`.
    static func revokedRequired(_ id: PermissionID) -> String {
      "permission.revoked.\(id.rawValue)"
    }

    /// Any other permission taken away, raised through `ServerComposition.revocationAlert`.
    static func revoked(_ id: PermissionID) -> String { "permission.\(id.rawValue)" }

    /// One nobody has been asked for, raised through `UnansweredContacts.notice`.
    static func unanswered(_ id: PermissionID) -> String { "permission.unanswered.\(id.rawValue)" }

    /// Every notice a grant makes untrue.
    static func missing(_ id: PermissionID) -> [String] {
      [revokedRequired(id), revoked(id), unanswered(id)]
    }
  }
}

/// When a Contacts permission nobody has answered gets asked.
///
/// `.notDetermined` means macOS has never shown the dialog. It shows once, and an app can put it
/// up only by asking, so a launch that never asks leaves someone with phone numbers for ever and
/// nothing on screen saying why. **Every launch below has a way to reach the dialog**:
///
/// | Launch | What happens |
/// |---|---|
/// | A fresh install, in the app | The onboarding permissions step's row has Request Access, and nothing asks until it is pressed. Setup finishing without it raises the notice (`RunningServer.setupFinished`), since a server Mac may not start again for weeks |
/// | An install past onboarding or migrated, in the app | Never interrupted: a launch at login has nobody in front of it. A notice leads to the Permissions tab, whose row has Request Access |
/// | No window (`--headless`, or the CLI) | Asked once as the server starts. There is no page and no button, ever, so nothing else would |
/// | `contact/refresh`, or the Contacts page's Refresh, on any of these | Asks, because somebody just asked for the address book (`ContactInterface.refresh`) |
///
/// The dialog is bounded and nothing waits on it at start. A headless server on a Mac nobody is
/// logged in to never has it answered, runs on phone numbers as `.recommended` promises, and is
/// asked again at its next start.
enum UnansweredContacts {

  enum Decision: Equatable {
    /// The walkthrough has the permissions step still to come, whose button asks.
    case leaveToOnboarding
    case ask
    case notify
  }

  /// What a server finishing its start does, given that Contacts has never been asked for.
  ///
  /// `hasWindow` first: a headless launch shows no onboarding whatever the stored flag says, so
  /// "not complete" there would wait for a step that can never appear.
  static func onStart(hasWindow: Bool, isOnboardingComplete: Bool) -> Decision {
    guard hasWindow else { return .ask }
    return isOnboardingComplete ? .notify : .leaveToOnboarding
  }

  /// Quiet, because running without Contacts is a supported configuration. Not durable, because
  /// the check at every start raises it again, and `PermissionsMonitorService` withdraws it the
  /// moment the question is answered.
  static var notice: UserAlert {
    UserAlert(
      severity: .info,
      title: "Contacts access has not been asked for",
      body:
        "Messages show phone numbers instead of names until BlueBubbles can read your address "
        + "book. Choose Request Access beside Contacts on the Permissions tab.",
      source: "Permissions",
      actions: [.openSettings(.permissions)],
      dedupeKey: PermissionNotice.Key.unanswered(.contacts),
      isDurable: false
    )
  }
}

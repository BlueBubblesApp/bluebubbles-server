//  FirebaseSetupPrompt
//  Which panel a guided Firebase setup run is parked on, and the words its two questions are
//  asked in.
//
//  Off the view so it can be asserted: touching a SwiftUI `View` type from a test process
//  traps. The key-decision text is the part that most needs it. It is precise about the
//  blast radius of each option because the intuitive guess is wrong in both directions, and
//  a sentence that drifted into "this will invalidate connected devices" would frighten
//  people away from the safe option and leave them relaxed about the one that breaks
//  something.
//
//  `FirebaseSetupPrompts` (the view modifier) presents what this decides; `FirebaseView`
//  applies it.

import BBCore
import BBPushKit

enum FirebaseSetupPrompt {

  /// Which panel setup is waiting on a person for.
  ///
  /// Derived from the model rather than stored, so navigating away and back re-presents
  /// whatever the run is still parked on instead of stranding it.
  enum Sheet: Identifiable, Equatable {
    case projects
    case billing(projectId: String)

    var id: String {
      switch self {
      case .projects: "projects"
      case .billing(let projectId): "billing-\(projectId)"
      }
    }
  }

  /// The panel for the model's state, or nil when the run is waiting on nobody.
  ///
  /// The project list first: a run asks which project before it can discover that the
  /// project needs billing, so the two are never both pending, and if they were the earlier
  /// question is the one to answer.
  static func sheet(isChoosingProject: Bool, pendingBillingProject: String?) -> Sheet? {
    if isChoosingProject { return .projects }
    if let projectId = pendingBillingProject { return .billing(projectId: projectId) }
    return nil
  }

  /// What each key option actually does.
  ///
  /// Deleting a key does NOT disconnect anybody's phone: FCM registrations are scoped to the
  /// Firebase project, so they survive any number of key changes. What a deletion breaks is
  /// any OTHER server or script still holding one of those keys: a second BlueBubbles
  /// install on the same project, typically.
  static func keyDecisionExplanation(_ plan: ProjectAdoptionPlan) -> String {
    var lines: [String] = []
    if let email = plan.serviceAccountEmail {
      lines.append("Project \(plan.projectId) uses \(email).")
    }
    if plan.canReuseHeldKey {
      lines.append(
        "This server already has a working key for this project, so it does not need "
          + "a new one."
      )
    }
    if plan.existingUserManagedKeys > 0 {
      // Phrased around the verb, so the count goes through `counted` with no "is"/"are"
      // to agree with it.
      lines.append(
        "This account has \(plan.existingUserManagedKeys.counted("existing key")). "
          + "Creating a new one leaves them working; deleting them "
          + "stops any OTHER server or script that uses them from sending "
          + "notifications."
      )
      // The obvious question this dialog raises, answered before it is asked. Google
      // hands over a key's private half exactly once, at creation, so an existing key
      // cannot be fetched back from the account: not by this server and not by
      // Google's own console. If the user still has the JSON, importing it is the way
      // to reuse it.
      if !plan.canReuseHeldKey {
        lines.append(
          "An existing key cannot be downloaded again; Google only ever releases "
            + "the private half once, when the key is created. If you still have "
            + "that JSON file, cancel and drop it onto this page instead."
        )
      }
    }
    lines.append(
      "Your registered devices are not affected either way; they are tied to the "
        + "Firebase project, not to a key."
    )
    return lines.joined(separator: " ")
  }

  /// Why importing credentials for a different project should clear the registered devices.
  static func projectChangeExplanation(from: String, to: String) -> String {
    """
    These credentials belong to \(to), but this server is set up with \
    \(from). Registered devices hold notification tokens issued by \
    \(from), which \(to) cannot deliver to, so they should be \
    cleared and your clients re-registered. Keep them only if you are \
    restoring the same project under a new key.
    """
  }
}

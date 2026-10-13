//  MigrationStepPresentation
//  What one step of the migration wizard says about itself: its name, what it will do, the
//  button that does it, and how it went.
//
//  Off the view so the sentences and the button rules can be asserted; they were `private
//  var`s on `MigrationStepRow`, which no test can reach. The sentence that matters most is
//  whether the old copy survives, because it differs by step and decides whether a person
//  can go back to the previous version.

import BlueBubblesServerCore

struct MigrationStepPresentation: Equatable {

  let step: MigrationStep
  /// How the step went, once it has run or been skipped. Nil while it is still an offer.
  let state: MigrationStepState?

  var title: String {
    switch step {
    case .settings: "Settings and password"
    case .pushCredentials: "Firebase credentials"
    case .savedRecords: "Devices, webhooks and scheduled messages"
    case .certificates: "TLS certificate"
    case .plaintextSecrets: "Remove old copies of your password & tokens"
    }
  }

  /// Says what will actually happen, in the user's terms.
  ///
  /// Adopting settings leaves `config.db` untouched, moving Firebase credentials and the TLS
  /// certificate deletes the originals, and the last step exists to delete things on purpose.
  /// A user deciding whether they can go back needs each of those said plainly.
  var explanation: String {
    switch step {
    case .settings:
      """
      Your port, password, tunnel provider and the rest, copied across. The password moves \
      into the Keychain. Your old configuration file is left exactly where it is.
      """
    case .pushCredentials:
      """
      Your Firebase service account, moved from a plain file into the Keychain. The \
      plaintext copy is deleted once it is safely stored.
      """
    case .savedRecords:
      """
      The phones registered for notifications, the webhook endpoints you registered, and \
      any messages you scheduled, copied across. Your old configuration file is left \
      exactly where it is. A scheduled message whose time has already passed is brought \
      over as a record rather than sent.
      """
    case .certificates:
      """
      Your TLS certificate, moved into the Keychain. The files are removed once it is \
      safely stored. Optional; if you skip it, the server does the same thing the next \
      time it starts.
      """
    case .plaintextSecrets:
      """
      The previous version stored your password and tunnel tokens as readable text. Now that \
      they are in the Keychain, the old copies can go. This cannot be undone, and it means \
      the previous version would no longer have its credentials if you went back to it.
      """
    }
  }

  var isFailed: Bool { state == .failed }

  /// The button that runs the step: "Try Again" once it has failed.
  var primaryTitle: String {
    if isFailed { return "Try Again" }
    switch step {
    case .certificates: return "Move"
    case .plaintextSecrets: return "Remove"
    case .settings, .pushCredentials, .savedRecords: return "Bring Across"
    }
  }

  /// Whether pressing the button asks first. Only the step that DELETES files does, and
  /// only the first time: a retry is a person who has already said yes.
  var confirmsFirst: Bool { step == .plaintextSecrets && !isFailed }

  /// What Skip says it does.
  var skipHelp: String {
    if step.isBlocking && !isFailed {
      return "Start without this. Your old settings stay where they are."
    }
    return step.isBlocking
      ? "Start without this. You can bring it across later." : "Leave this as it is."
  }

  var symbol: String {
    switch state {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .declined: "minus.circle"
    case .pending, nil:
      switch step {
      // Not a download arrow: this one takes something away.
      case .plaintextSecrets: "trash"
      default: step.isBlocking ? "arrow.down.circle" : "arrow.down.circle.dotted"
      }
    }
  }

  /// The glyph's tone once the step has an outcome; nil while it is still an offer, which
  /// is drawn in the accent colour.
  var tone: StatusTone? {
    switch state {
    case .completed: .good
    case .failed: .problem
    case .declined: .informational
    case .pending, nil: nil
    }
  }
}

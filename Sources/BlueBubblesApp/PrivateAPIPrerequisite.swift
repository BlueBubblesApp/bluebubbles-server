//  PrivateAPIPrerequisite
//  What the Private API tab and the onboarding step say about System Integrity Protection.
//
//  Off the view so each answer can be asserted. Not knowing is one of them: until the server has
//  started, `PermissionsModel.systemIntegrity` holds nothing, and the probe can report that it
//  could not run. Folding that into "enabled" tells somebody who has already been through
//  Recovery to go and do it again; folding it into "disabled" promises a prerequisite nobody has
//  checked.
//
//  Part of SIP off is a recommendation and not a refusal: the features stay on offer, because a
//  subset works for some people and which one has not been measured. `SIPConfiguration` has the
//  reasoning, and `permissionStatus` there is what the start gate reads.
//
//  NOTHING HERE RE-READS, AND THE PAGES OFFER NO RE-CHECK, on purpose. `csrutil disable` is
//  only available in Recovery and applies at the next boot, so one process only ever sees one
//  answer, and a button or a focus observer would ask a question that cannot have a new answer.
//  The read itself is already in hand: `PermissionsMonitorService.start` runs `checkAll` before
//  the phase reaches `.running`, `PermissionsService.stream` seeds whoever subscribes after
//  that, and `.unknown` is replaced by the monitor's own loop whenever a later probe can run.
//  That is also why these pages do not take `permissionsLiveUpdates`: it would spend a probe
//  every two seconds on the one status that cannot move.

import BBSystem

enum PrivateAPIPrerequisite: Equatable, Sendable {
  /// All of SIP is off. Only the prerequisite: nothing is claimed about the helper, which
  /// `PrivateAPIStatusSummary` reports.
  case met
  /// Some of SIP is off and these are still on. The registry starts the Private API service
  /// anyway, and whether the helper loads is the status card's to report. Never empty.
  case partial(stillOn: [SIPProtection])
  /// All of SIP is on, so the registry will not start the Private API service.
  case unmet
  /// Not read yet, or the check could not run.
  case unknown

  /// - Parameter configuration: what the model holds, or nil when it has not been read.
  init(configuration: SIPConfiguration?) {
    guard let configuration else {
      self = .unknown
      return
    }
    let stillOn = configuration.stillEnforced
    if stillOn.isEmpty {
      self = .met
    } else if configuration.isFullyEnabled {
      self = .unmet
    } else {
      self = .partial(stillOn: stillOn)
    }
  }

  /// Whether the Private API tab draws this beside a helper in the given state.
  ///
  /// The confirmation always, because whether SIP is disabled is what somebody came to the
  /// page to find out. Anything else stops once the helper is answering: a helper that is
  /// answering settles the question, and "these features need SIP disabled" above features
  /// that plainly work would be the page contradicting itself. So somebody whose subset works
  /// is not told to change it on every visit.
  func isShown(alongside presence: PrivateAPIPresence) -> Bool {
    self == .met || presence != .connected
  }

  var title: String {
    switch self {
    case .met: "System Integrity Protection is disabled"
    case .partial: "We recommend disabling all of System Integrity Protection"
    case .unmet: "These features need System Integrity Protection disabled"
    case .unknown: "System Integrity Protection status is not known yet"
    }
  }

  var detail: String {
    switch self {
    case .met:
      "SIP will not block the helper these features inject into Apple's apps."
    case .partial(let stillOn):
      "This Mac still enforces \(stillOn.map(\.title).formatted(.list(type: .and))), and some "
        + "of these features may not work until they are off too. If everything you use "
        + "works, nothing needs to change. To turn off the rest, run csrutil disable from "
        + "Recovery."
    case .unmet:
      "Everything on this page works by injecting a helper into Apple's apps, which "
        + "macOS blocks while SIP is on. The rest of the server (sending, receiving, "
        + "attachments) works normally without it."
    case .unknown:
      "These features need SIP disabled, and this updates on its own once the server has "
        + "read it. The rest of the server (sending, receiving, attachments) works normally "
        + "either way."
    }
  }

  var symbol: String {
    switch self {
    case .met: "checkmark.shield"
    case .unmet: "exclamationmark.shield"
    case .partial, .unknown: "shield"
    }
  }

  /// `.good` rather than nothing, since the confirmation is the one place this is stated
  /// outside the Permissions tab; `.informational` for a recommendation, which may be working
  /// fine as it is, and for the state that makes no judgement.
  var tone: StatusTone {
    switch self {
    case .met: .good
    case .unmet: .attention
    case .partial, .unknown: .informational
    }
  }

  /// Only where there is something to go and do.
  var showsSetupGuide: Bool {
    switch self {
    case .partial, .unmet: true
    case .met, .unknown: false
    }
  }
}

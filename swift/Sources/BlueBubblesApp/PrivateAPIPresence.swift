//  PrivateAPIPresence
//  The three states of the Private API that the settings page draws differently.
//
//  `PrivateAPIRuntime.StartOutcome` has five cases and the page needs three, but the useful
//  part is WHICH three. The tempting split is connected / not connected, and it is wrong:
//  it throws away the difference between "switched off" and "switched on and broken", which
//  are the two states with opposite needs. Somebody who has not turned it on does not need a
//  connection diagnostic — there is no connection to diagnose, and a card explaining that
//  nothing has been injected is noise on a page whose job right then is to say what turning
//  it on would get them. Somebody whose helper timed out needs exactly that card.
//
//  Deliberately not a View and not tied to one, so both the features card and the page that
//  decides what to render agree on one answer rather than polling for two.

import BBPrivateAPI

enum PrivateAPIPresence: Hashable, Sendable {
  /// The helper is injected and answering.
  case connected
  /// Switched on, but not working — injected and silent, timed out, or failed. This is the
  /// state the status card exists for.
  case enabledButNotWorking
  /// Off, or the server is not running. Nothing to diagnose.
  case notEnabled

  init(outcome: PrivateAPIRuntime.StartOutcome?, isConnected: Bool) {
    switch outcome {
    case .running: self = isConnected ? .connected : .enabledButNotWorking
    case .timedOut, .failed: self = .enabledButNotWorking
    case .disabled, .notStarted, .none: self = .notEnabled
    }
  }

  /// Whether the features card should list what works rather than what is missing.
  var showsAvailableFeatures: Bool { self == .connected }

  /// Whether the connection status card is worth showing.
  ///
  /// Not `!= .connected`: a working setup still benefits from seeing that it is working, and
  /// hiding the card the moment it turns green would make it look like the page had lost
  /// track of it.
  var showsStatusCard: Bool { self != .notEnabled }

  /// Whether the SIP prerequisite is the thing standing in the way.
  var showsPrerequisiteNote: Bool { self != .connected }
}

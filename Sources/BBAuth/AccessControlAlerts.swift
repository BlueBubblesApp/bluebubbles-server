//  AccessControlAlerts
//  What the access controller tells the operator, as values the alert centre derives from.
//
//  Every automatic decision the controller takes is one an operator has to hear about: a
//  block is either an attack worth knowing about or a false positive somebody needs to undo,
//  and throttling or ignoring a proxy's forwarding header means the server has stopped being
//  able to tell clients apart. These are `BBError`s rather than hand-built `UserAlert`s so the
//  title, the body, the code and the dedupe key are one value with one derivation
//  (`UserAlert.init(_:actions:)`), the same one every other subsystem's alert goes through.
//
//  The remedy travels as the alert's actions, which the caller supplies: a block offers to
//  undo itself for the address it names.

import BBCore
import BBDiagnostics
import Foundation

enum AccessControlAlert: BBError {
  /// One client failed `failureCount` times and is blocked until `until`.
  case blocked(address: String, failureCount: Int, offenceCount: Int, until: Date)
  /// Failures from clients nobody can tell apart crossed the global threshold.
  case throttled(failureCount: Int)
  /// One proxy forwarded failures claiming `distinctAddresses` different clients.
  case forwardedChurn(distinctAddresses: Int)

  var code: String {
    switch self {
    case .blocked: "access_control.blocked"
    case .throttled: "access_control.throttled"
    case .forwardedChurn: "access_control.forwarded_churn"
    }
  }

  var domain: String { "AccessControl" }
  var severity: Severity { .warning }
  var isUserFacing: Bool { true }

  /// Per ADDRESS for a block. A block is the one alert about a subject among many, and it
  /// carries that subject's unblock button: deduped on the code alone, a second address's
  /// block would be folded into an alert naming the first, and its own remedy lost.
  var dedupeKey: String {
    switch self {
    case .blocked(let address, _, _, _): "\(code).\(address)"
    case .throttled, .forwardedChurn: code
    }
  }

  var title: String {
    switch self {
    case .blocked: "Blocked a client after repeated failed logins"
    case .throttled: "Throttling failed logins from an unidentified source"
    case .forwardedChurn: "Ignoring forwarded client addresses"
    }
  }

  /// Names the address on a block: it is what the person unblocks. Names none on the other
  /// two: the only address available is the proxy's, which on the default policy is loopback
  /// and names nothing, and the forwarded ones are the attacker's invention.
  var body: String {
    switch self {
    case .blocked(let address, let failureCount, _, let until):
      "\(address) failed to authenticate \(failureCount) times and is blocked "
        + "until \(Self.formatter.string(from: until)). If this is you, unblock it."
    case .throttled(let failureCount):
      "\(failureCount) failed login attempts arrived through a proxy that "
        + "does not identify its clients, so none of them can be blocked "
        + "individually. If you run your own reverse proxy, add it under "
        + "Trusted Reverse Proxies so attempts can be attributed."
    case .forwardedChurn(let distinct):
      "Failed logins arrived claiming \(distinct) different client addresses "
        + "through one proxy, which is how an attacker avoids being blocked. Those "
        + "claims are being ignored and the attempts are now rate-limited together. "
        + "If you run your own reverse proxy and this is legitimate traffic, raise the "
        + "limit under Security."
    }
  }

  var context: [String: DiagnosticValue] {
    switch self {
    case .blocked(let address, let failureCount, let offenceCount, _):
      [
        "address": .string(address),
        "failure_count": .int(failureCount),
        "offence_count": .int(offenceCount),
      ]
    case .throttled(let failureCount): ["failure_count": .int(failureCount)]
    case .forwardedChurn(let distinct): ["distinct_addresses": .int(distinct)]
    }
  }

  /// The remedy beside the problem. A block offers to lift itself, so a false positive is
  /// one click in the notification rather than a hunt through Settings.
  var actions: [AlertAction] {
    switch self {
    case .blocked(let address, _, _, _): [.unblock(address: address), .openSettings(.security)]
    case .throttled, .forwardedChurn: [.openSettings(.security)]
    }
  }

  /// How an expiry reads, in the alert and in the log line beside it.
  static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()
}

extension AlertRaising {
  /// Raises an access-control alert with the remedy it carries.
  func raise(_ alert: AccessControlAlert) async {
    await raise(alert, actions: alert.actions)
  }
}

//  ActionOutcome
//  What a one-off action did, said under the button that ran it.
//
//  A maintenance button (clear FaceTime links, install a Shortcut, send a test) has no page
//  state to change, so its only report is a sentence. Two sections each kept a summary
//  string and an `isFailure` flag beside it and drew them two ways, and both had to remember
//  to clear the flag when the next attempt started. The three outcomes are a value here, and
//  `ActionOutcomeLine` is how one is drawn.
//
//  Not a View, so what an action reports can be asserted; touching a SwiftUI `View` type
//  from a test process traps.

import BBFaceTime
import Foundation

enum ActionOutcome: Equatable, Sendable {
  /// It worked, or there was nothing to do: either way, nothing more is asked.
  case done(String)
  /// Handed to somebody else to finish (a system sheet, another app). Not a success, and
  /// claiming one would be wrong whenever the person declines.
  case waiting(String)
  /// It did not work, and the sentence says why.
  case failed(String)

  var text: String {
    switch self {
    case .done(let text), .waiting(let text), .failed(let text): text
    }
  }

  var tone: StatusTone {
    switch self {
    case .done, .waiting: .informational
    case .failed: .problem
    }
  }

  var symbol: String {
    switch self {
    case .done: "checkmark.circle"
    case .waiting: "hourglass"
    case .failed: "exclamationmark.triangle.fill"
    }
  }

  var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}

extension ActionOutcome {

  /// What a FaceTime cleanup pass did.
  static func faceTimeCleanup(_ result: FaceTimeCoordinator.CleanupResult) -> ActionOutcome {
    faceTimeCleanup(
      links: result.links.count, calls: result.calls.count, alerts: result.alerts,
      failure: result.failure)
  }

  /// The same, from the counts. A failure and "nothing to do" look identical from the
  /// outside (no links, no calls), so the sentence says which.
  static func faceTimeCleanup(
    links: Int, calls: Int, alerts: Int, failure: String?
  ) -> ActionOutcome {
    guard links > 0 || calls > 0 || alerts > 0 else {
      return failure.map { .failed("Nothing cleared: \($0)") } ?? .done("Nothing to clear.")
    }
    var parts = ["Cleared \(links.counted("link"))"]
    if calls > 0 { parts.append("left \(calls.counted("call"))") }
    if alerts > 0 { parts.append("dismissed a blocking alert") }
    return .done(parts.joined(separator: ", ") + ".")
  }
}

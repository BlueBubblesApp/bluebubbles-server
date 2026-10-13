//  BlockedClientSummary
//  The one line under a blocked address on the Security page.
//
//  Why it was blocked and for how long. The remaining time matters most: an automatic block
//  always expires, so the common accidental case resolves itself, and knowing that is the
//  difference between waiting four minutes and filing a bug.
//
//  Off the view for the usual reason, and for one specific to this sentence: it is a
//  function of the CLOCK, and a rule that reads the clock itself can only be tested by
//  waiting. `now` is a parameter here, which is what makes the boundary — a block with
//  seconds left, and one that has just lapsed — something a test can state.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import BBAuth
import Foundation

enum BlockedClientSummary {

  /// Why it was blocked and for how long, in one line.
  ///
  /// The row leaves the list when the service says the block has lapsed, so "expired" is
  /// never shown against an entry that is still here; a block whose expiry has passed while
  /// the row is still on screen reads as "expires in 0 seconds" rather than going negative.
  static func describe(_ client: BlockedClient, now: Date = Date()) -> String {
    var parts = [client.failureCount.counted("failed attempt"), client.reason]
    if let expiresAt = client.expiresAt {
      parts.append("expires in \(remaining(until: expiresAt, now: now))")
    } else {
      parts.append("permanent")
    }
    if client.offenceCount > 1 { parts.append("blocked \(client.offenceCount) times before") }
    return parts.joined(separator: " · ")
  }

  /// How long is left, floored at zero.
  ///
  /// Whole seconds, because `.units` renders a fraction as its own component and "expires in
  /// 4 minutes, 0 seconds" is worse than "4 minutes". The floor is not cosmetic: a lapsed
  /// block would otherwise format a NEGATIVE duration, which reads as time added rather than
  /// time left.
  static func remaining(until expiresAt: Date, now: Date) -> String {
    let seconds = max(0, expiresAt.timeIntervalSince(now))
    return Duration.seconds(Int(seconds))
      .formatted(.units(allowed: [.hours, .minutes, .seconds]))
  }
}

/// What the allowlist's Add field says about an entry it will not take.
enum AllowlistEntry {

  /// Why `entry` cannot be added, or nil when it can.
  ///
  /// VALIDATED before it is written, against the same parser the matcher uses: the service
  /// appends whatever it is given and reports nothing, so a typo went into the list looking
  /// active, matched nothing, and the field cleared as though it had worked. An allowlist
  /// entry that silently protects nobody is worse than a refused one.
  ///
  /// Plain text: the line it lands in renders a `String`, where backticks are printed as
  /// backticks rather than as code.
  static func problem(with entry: String) -> String? {
    guard !CIDR.isValidPattern(entry) else { return nil }
    return "“\(entry)” is not an address or a CIDR range, so nothing would ever match it. "
      + "Use a form like 192.168.1.10 or 192.168.1.0/24."
  }
}

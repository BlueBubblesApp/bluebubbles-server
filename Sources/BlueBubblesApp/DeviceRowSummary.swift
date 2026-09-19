//  DeviceRowSummary
//  What the registered-devices page says about a push registration.
//
//  "Never connected" rather than a formatted epoch zero. A device that registered and never
//  came back is the interesting case, and 1 January 1970 obscures it — which is exactly what
//  a nil-coalescing default would have produced.
//
//  Takes the VALUES rather than the record, so the rules can be asserted without building a
//  database row, and so a second kind of device (the token-auth enrolments, if they ever get
//  a screen again) reuses them rather than growing a second spelling.
//
//  See `Sources/BlueBubblesApp/CLAUDE.md`.

import Foundation

enum DeviceRowSummary {

  static func lastSeen(_ lastActive: Date?) -> String {
    guard let lastActive else { return "Never connected" }
    return "Last seen \(lastActive.formatted(.relative(presentation: .named)))"
  }

  /// Whether the row will say "never", which is the branch worth asserting without pinning
  /// the locale's wording of the other one.
  static func hasNeverConnected(_ lastActive: Date?) -> Bool {
    lastActive == nil
  }

  /// What the codec tag says.
  ///
  /// A device listing no codecs is on legacy-v1 by definition: the column is null until a
  /// client advertises something, and the negotiator's floor is legacy-v1. That is a
  /// DEFAULT, not a missing value, so the tag states it rather than going blank.
  static func codec(_ supportedCodecs: String?) -> String {
    let advertised = (supportedCodecs ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return advertised.first ?? "legacy-v1"
  }

  /// How much of the push token a row shows.
  ///
  /// Enough to tell two phones apart and to match a row against a log or a Firebase console,
  /// and not the whole thing. A registration token is the address a notification is
  /// delivered to: it is why `LogRedactionPolicyTests` refuses to let one near a log line,
  /// and a screenshot of this page pasted into a support thread is the same exposure by a
  /// slower route. Shown whole it is also unreadable — they run past 150 characters.
  ///
  /// A token too short to abbreviate is returned as it is. The boundary is where the
  /// elision starts paying for itself: at `ends * 2 + 1` characters it hides exactly one
  /// and spends a character saying so, which is the same width on screen, one character
  /// less of the token, and a reader told there is more than there is.
  static func shortToken(_ identifier: String, keeping ends: Int = 6) -> String {
    guard identifier.count > ends * 2 + 1 else { return identifier }
    return "\(identifier.prefix(ends))…\(identifier.suffix(ends))"
  }
}

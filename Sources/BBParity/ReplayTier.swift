//  ReplayTier
//  How far a recorded fixture reaches when it is replayed, and therefore what has to be
//  true before it is allowed to run.
//
//  The corpus was recorded against a real Mac, and replaying a recording means MAKING THE
//  CALL AGAIN FOR REAL. That is not a theoretical hazard: the first run of this harness
//  locked this developer's Mac and restarted Messages, over a remote session, because
//  `mac/lock` and `mac/imessage/restart` are in the corpus. The answer at the time was a
//  flat deny-list, which was right and is still the floor — but it also refused a large
//  number of routes that cannot reach the machine at all, and those went unverified for the
//  same reason as the ones that can.
//
//  **The distinction the deny-list could not draw is what this type exists for.** In the
//  in-process harness the server is already sandboxed in two of the three directions: its
//  `app.db` is in memory and its `chat.db` is a temporary copy. What is NOT sandboxed is
//  anything that leaves the process — AppleScript into Messages.app, the system calls behind
//  `mac/lock`, FindMy on the real account. And the Private API is a third case again: the
//  harness publishes a `FailingPrivateAPI` double, a pure in-memory value with no socket and
//  no IMCore, so a route gated on `requires: .privateAPI` reaches the double and stops there.
//
//  So there are three questions, not one, and they ladder:
//
//    1. Does it reach anything outside the harness?          -> `.harness`
//    2. Does it reach anything beyond the Private API double? -> `.privateAPIDouble`
//    3. Does it reach the real Mac?                            -> `.realMac`
//
//  `.never` is the floor that does not move: no setting, variable or flag admits it.
//
//  **The default is `.harness`, which is exactly what the deny-list did before this
//  existed.** Nothing widens on its own; see `FixtureReplay.isDestructive`, which still
//  answers the default-tier question and is what the two safety suites assert against.

import Foundation

/// How far a fixture reaches, and how far a run is willing to let one reach.
///
/// Ordered, so a run states one ceiling and everything at or below it is admitted.
public enum ReplayTier: Int, Sendable, Comparable, CaseIterable {

  /// Reaches nothing outside the harness: the in-memory `app.db`, the temporary `chat.db`
  /// copy, and the response. Every GET but an admin one nobody has acknowledged as a read,
  /// the four read-only POSTs, and the writes named as touching only the server's own
  /// database (a webhook, a theme, a contact). Which routes those are is the caller's
  /// classification, derived from the route table; see `RouteReach`.
  ///
  /// This is what has always been replayed, and it is the default.
  case harness = 1

  /// Reaches the published Private API double and stops there.
  ///
  /// Every other write carrying `requires: .privateAPI`. `FailingPrivateAPI` has no socket and no
  /// IMCore — it is a struct whose members throw unless a closure is supplied — so the call
  /// cannot arrive anywhere. What makes these worth admitting is that the response is still
  /// the server's own: the envelope, the status, the error translation and (where the double
  /// is taught to answer) the serialized body are all produced by the real handler.
  ///
  /// Not enabled by default, because admitting them without teaching the double to answer
  /// turns sixty routes into sixty identical refusals, and because widening what a test
  /// suite does should be something somebody asked for.
  case privateAPIDouble = 2

  /// Reaches the real Mac: AppleScript into Messages.app, FindMy on the signed-in account,
  /// the system. Also every write the classification does not place lower, so a route
  /// nobody has looked at lands here rather than on the floor.
  ///
  /// **Not implemented.** The classification is here because the ladder is only honest if
  /// the dangerous rung is named rather than merely absent — a run that asks for this gets
  /// told it does not exist, instead of silently getting the tier below and reporting a pass
  /// over routes it never touched.
  case realMac = 3

  /// Never replayed, at any tier. Locks the screen, restarts the process, installs a build;
  /// and any path no route in the table serves, since nothing has classified it.
  case never = 4

  public static func < (lhs: ReplayTier, rhs: ReplayTier) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The spelling `BB_PARITY_TIER` accepts, and what the skip messages name.
  public var name: String {
    switch self {
    case .harness: "harness"
    case .privateAPIDouble: "stub"
    case .realMac: "live"
    case .never: "never"
    }
  }

  /// The ceiling a run was asked for, or nil when the value is not one we admit.
  ///
  /// `live` and `never` parse and are then REFUSED by the caller rather than being rejected
  /// here, so the error can say "that rung is not built" instead of "unknown value", which
  /// are different problems with different fixes.
  public static func named(_ raw: String) -> ReplayTier? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return allCases.first { $0.name == trimmed }
  }

  /// The environment variable that raises the ceiling.
  ///
  /// An environment variable rather than a command-line flag, and that is forced rather than
  /// preferred: `swift test` parses its own arguments and REFUSES an unknown one, with or
  /// without a `--` separator, so there is no flag to read. A compile-time `-D` would work
  /// and costs a rebuild on every change of mind. A file would work and can be committed by
  /// accident, which matters more here than it usually would — the corpus is scanned by
  /// `TestDataPolicyTests` precisely because a real address must never reach the tree.
  ///
  /// It is also already how this repository gates its other opt-in suites:
  /// `BB_LIVE_TOOL_INSTALL=1` for the real-registry download and `BB_BENCH=1` for the
  /// read-concurrency benchmark.
  public static let environmentKey = "BB_PARITY_TIER"

  /// What the environment asks for, or `.harness` when it asks for nothing.
  public static func requested(
    from environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RequestedTier {
    guard let raw = environment[environmentKey], !raw.isEmpty else { return .ceiling(.harness) }
    guard let tier = named(raw) else { return .unrecognised(raw) }
    switch tier {
    case .harness, .privateAPIDouble: return .ceiling(tier)
    case .realMac, .never: return .notBuilt(tier)
    }
  }

  /// The answer to "what did the environment ask for", including the two ways it can be
  /// wrong. A malformed request must never silently become the default: that is how a run
  /// reports a pass over routes it did not replay.
  public enum RequestedTier: Sendable, Equatable {
    case ceiling(ReplayTier)
    /// A rung that is named but not built.
    case notBuilt(ReplayTier)
    case unrecognised(String)

    /// The ceiling to run at, or nil when the caller should fail instead.
    public var ceiling: ReplayTier? {
      if case .ceiling(let tier) = self { return tier }
      return nil
    }

    /// What to tell somebody who asked for something we will not do.
    public var refusal: String? {
      switch self {
      case .ceiling: nil
      case .notBuilt(let tier):
        """
        \(ReplayTier.environmentKey)=\(tier.name) is not built. Replaying these fixtures \
        would drive Messages.app, FindMy or the machine itself for real, against whatever \
        account this Mac is signed in to. Supported values: \
        \(ReplayTier.harness.name), \(ReplayTier.privateAPIDouble.name).
        """
      case .unrecognised(let raw):
        """
        \(ReplayTier.environmentKey)=\(raw) is not a tier. Supported values: \
        \(ReplayTier.harness.name), \(ReplayTier.privateAPIDouble.name).
        """
      }
    }
  }
}

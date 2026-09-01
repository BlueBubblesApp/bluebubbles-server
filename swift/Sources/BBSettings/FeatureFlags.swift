//  FeatureFlags
//  Capabilities that ship switched off.
//
//  WHY THIS IS NOT JUST `Setting<Bool>`
//  It is one underneath — a flag is a boolean setting with a `feature_` key, stored, layered
//  and overridable exactly like every other. What the wrapper adds is three things a bare
//  setting cannot express:
//
//    1. THEY ARE ENUMERABLE. `Features.all` is the list, so the server can report which
//       capabilities exist and which are on without anyone maintaining a second copy. A
//       client that wants to explain "location sharing is available but disabled" needs that
//       list; deriving it by grepping the settings registry for a prefix would work right up
//       until someone names a setting `feature_` for another reason.
//
//    2. THEY CARRY A REASON. Not help text for a form — the reason a capability is off, in a
//       sentence a person can act on. It is shown in the settings UI, returned by the
//       capability endpoint, and put into the error when a route refuses. Those three
//       explanations agreeing is the whole point: a flag whose "why" lives only in a code
//       comment gets turned on by someone who never read it.
//
//    3. THEY ARE ALL DEFAULT-OFF, AND THAT IS CHECKED. `FeatureFlagTests` asserts it. A flag
//       that shipped on by accident is indistinguishable from a feature, and the default
//       route table has to stay identical to the Node server's.
//
//  A flag is NOT a settings toggle by another name. Use one when a capability is complete but
//  should not be reachable yet — because it is unproven, because it changes what the API
//  exposes, or because it does something the user needs to consent to knowingly. Anything a
//  user is expected to configure as part of ordinary setup is a plain setting and belongs in
//  `SettingsRegistry`.

import Foundation

/// One capability that can be switched on.
public struct FeatureFlag: Sendable, Hashable, Identifiable {

  /// Stable identifier, without the `feature_` prefix. This is what appears in the
  /// capability report, so it is API and must not be renamed.
  public let id: String

  /// One line: what turning this on gives you.
  public let summary: String

  /// Why it is off. Written for the person deciding whether to turn it on, and surfaced
  /// verbatim when a route refuses — so it has to read as an explanation, not a scold.
  public let rationale: String

  /// The section the settings UI files it under.
  public let section: String

  public init(id: String, summary: String, rationale: String, section: String = "Features") {
    self.id = id
    self.summary = summary
    self.rationale = rationale
    self.section = section
  }

  /// The persisted key. Prefixed so a flag is recognisable in an exported config and in a
  /// support conversation without cross-referencing anything.
  public var key: String { "feature_\(id)" }

  /// The backing setting.
  ///
  /// Built here rather than stored so a flag cannot be declared with a default of `true`:
  /// there is no parameter for it. That is the constraint the tests assert, expressed in
  /// the type instead of only in a test.
  public var setting: Setting<Bool> {
    Setting<Bool>(
      key, default: false,
      presentation: .init(
        label: summary,
        help: rationale,
        section: section,
        control: .toggle
      )
    )
  }

  public static func == (lhs: FeatureFlag, rhs: FeatureFlag) -> Bool { lhs.id == rhs.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Every flag, declared once.
public enum Features {

  /// The FindMy surface that goes beyond what the previous server had: status, per-person
  /// refresh, and asking someone to share.
  ///
  /// Off by default for the same reason every additive group is — a default-configured
  /// server's route table has to match the Node server's exactly, and these paths are
  /// visible to anyone who probes for them.
  public static let findMy = FeatureFlag(
    id: "findmy_enhanced",
    summary: "Enhanced Find My",
    rationale: "Adds Find My status, per-person location refresh, and location-share "
      + "requests. Off by default because it adds endpoints the previous server did "
      + "not have, which a client can detect.",
    section: "Find My"
  )

  /// Sharing THIS MAC's location out.
  ///
  /// Off by default, and this one is not about route parity. The position IMCore shares is
  /// the Mac's, because the Mac is the device speaking — not the position of whichever
  /// phone or laptop asked the server to start sharing. A user who taps "share my location"
  /// in a client reasonably expects to share where THEY are, and would instead be sharing
  /// where their Mac is, indefinitely, with someone they may only have meant to tell for an
  /// hour. That gap is why it is opt-in rather than merely additive: turning it on should be
  /// a decision someone made on purpose, having read what it does.
  ///
  /// Requires `findMy` as well: the sharing routes live inside the same group.
  public static let findMyLocationSharing = FeatureFlag(
    id: "findmy_location_sharing",
    summary: "Find My location sharing",
    rationale: "Lets clients start and stop sharing a location with a conversation. The "
      + "location shared is THIS MAC's, not the location of the device that asked — "
      + "so a phone asking to share its location would instead share the Mac's. Leave "
      + "off unless that is what you want.",
    section: "Find My"
  )

  /// FaceTime beyond availability checks: minting links, placing calls, and handing a call
  /// off to a client (Flows A and B — see docs/headers/FACETIME.md).
  ///
  /// Off by default like every additive capability, and additionally because it drives a
  /// SECOND injected app (FaceTime.app) that has to be kept alive and supervised — a real
  /// operational cost, not just a route. It also initiates calls, which is a side effect a
  /// user should switch on deliberately.
  public static let all: [FeatureFlag] = [
    findMy, findMyLocationSharing,
  ]

  public static func flag(id: String) -> FeatureFlag? {
    all.first { $0.id == id }
  }

  /// Keys for the settings registry's migration list.
  public static var allKeys: [String] { all.map(\.key) }
}

// MARK: - Reading

extension SettingsStore {

  /// Whether a capability is switched on.
  ///
  /// Reads through the ordinary settings layers, so a flag can be forced on for one run
  /// from the command line without persisting it — which is how these are meant to be
  /// tried before being committed to.
  public func isEnabled(_ flag: FeatureFlag) -> Bool {
    get(flag.setting)
  }

  /// Every flag with its current state, for the capability report.
  public func featureStates() -> [FeatureFlag: Bool] {
    Dictionary(uniqueKeysWithValues: Features.all.map { ($0, get($0.setting)) })
  }
}

//  ReplayTierSelection
//  Which tier this run replays at, and how far every route reaches.
//
//  Two jobs that both have to be right, and only one of them is interesting.
//
//  The dull one is reading `BB_PARITY_TIER`. The interesting one is classifying every route,
//  because THAT is what decides whether a replay is a request against an in-memory database
//  or an AppleScript send to a real person. Getting it wrong in one direction withholds a
//  route that could have been replayed; getting it wrong in the other drives the real Mac.
//
//  So it is DERIVED, from `RouteCatalog.routes` — every route this server can mount, v1 and
//  v2 — and it FAILS CLOSED. A route reaches a lower rung only for a reason the route table
//  itself states:
//
//    - the deny-list puts it at `.never`, whatever else is true;
//    - a GET is `.harness`, unless it is an admin GET nobody has acknowledged as a read (the
//      reference restarts the server on a GET, so the verb alone is not evidence);
//    - a write is `.harness` only when its HANDLER is in `serverLocalWrites`, by typed
//      `HandlerID`, so the list cannot name a route that does not exist;
//    - a remaining write carrying `requires: .privateAPI` reaches the published double and
//      stops there, so `.privateAPIDouble`;
//    - anything else is `.realMac`, which no run admits.
//
//  The failure this prevents is the one a list of DANGEROUS paths has: everything not on it
//  counts as safe. Keyed on "sending" path prefixes, a write outside them was server-local
//  by default, so a prefix nobody added (`/api/v2/icloud/`, `/api/v2/sticker`) made a FindMy
//  share request on the real account replayable. Here a new route starts at the top of the
//  ladder until someone says why it belongs lower, and `FixtureReplay` answers `.never` for
//  any path the table does not serve.
//
//  `BBParity` takes the result as an argument rather than computing it, because it has no
//  dependencies on purpose and reaching into `BBHTTPAPI` to classify fixtures would invert
//  that. See `RouteReach`.

import BBAuth
import BBHTTPAPI
import BBOpenAPI
import BBParity
import BBTestSupport
import Foundation

/// Spelled once here so the selection below reads as a list of operations rather than a
/// list of deeply-qualified names.
typealias FailingPrivateAPIOperation = FailingPrivateAPI.VoidOperation

enum ReplayTierSelection {

  /// Every route the server can mount, keyed by template, with the tier it needs.
  static let routeReach = RouteReach(tiers)

  /// The table `routeReach` is built from: `"POST /api/v1/chat/:guid/read"` to its tier.
  ///
  /// When two groups mount the same template, the more restrictive classification wins.
  static var tiers: [String: ReplayTier] {
    var tiers: [String: ReplayTier] = [:]
    for entry in RouteCatalog.routes {
      let template = "\(entry.route.method.rawValue) \(entry.path)"
      let tier = Self.tier(of: entry.route, at: template)
      tiers[template] = max(tiers[template] ?? tier, tier)
    }
    return tiers
  }

  /// How far one route reaches, from its own metadata. See the header for the ladder.
  ///
  /// The Private API gate is the ROUTE's, not its group's, on purpose. The v1 FaceTime group
  /// is gated as a whole; counting that would admit its three writes at
  /// `BB_PARITY_TIER=stub`, and no run has yet checked that they stop at the double. They
  /// stay `.realMac` until one has.
  static func tier(of route: RouteDefinition, at template: String) -> ReplayTier {
    if FixtureReplay.destructiveRoutes.contains(template) { return .never }
    if route.method == .get {
      let unacknowledgedAdmin = route.scope == .serverAdmin && !adminReads.contains(route.handlerID)
      return unacknowledgedAdmin ? .realMac : .harness
    }
    if serverLocalWrites.contains(route.handlerID) { return .harness }
    if route.requirements.contains(.privateAPI) { return .privateAPIDouble }
    return .realMac
  }

  /// Non-GET routes that touch nothing but the server's own database, or only read.
  ///
  /// In the in-process harness that database is in memory, so a write here does not outlive
  /// the run. Each entry was checked against its interface; a handler belongs here only when
  /// it reaches neither Messages, FaceTime, FindMy, the helper nor the file system outside
  /// the harness. `attachment.upload` is NOT here: it stages a file under the real
  /// Application Support directory, so it stays at its Private API gate.
  static let serverLocalWrites: Set<HandlerID> = [
    // Reads that happen to be POSTs.
    .messageQuery, .chatQuery, .handleQuery, .contactQuery,
    // `app.db`: the alert list, the device registry, the contact index, the two backup
    // blobs and the webhook table.
    .serverMarkAlertRead, .fcmRegisterDevice,
    .contactCreate, .contactUpdate, .contactDelete, .contactImportVCF,
    .backupCreateTheme, .backupDeleteTheme, .backupCreateSettings, .backupDeleteSettings,
    .webhookCreate, .webhookDelete,
  ]

  /// Admin-scoped GETs acknowledged as reads.
  ///
  /// The scope is what makes a GET suspect: the reference's two restart routes are admin
  /// GETs, and an admin GET added tomorrow is the shape of a third. These four read state and
  /// change nothing.
  static let adminReads: Set<HandlerID> = [
    .serverLogs, .serverCheckUpdate, .fcmClientConfig, .webhookList,
  ]

  /// The ceiling this run was asked for.
  ///
  /// Refuses rather than falls back. A malformed or unbuilt request that quietly became
  /// `.harness` would report a pass over a tier it never touched, which is the one outcome
  /// this whole ladder exists to prevent.
  static func ceiling() throws -> ReplayTier {
    let requested = ReplayTier.requested()
    if let refusal = requested.refusal { throw TierRefusal(message: refusal) }
    // `refusal` is nil exactly when a ceiling is present.
    return requested.ceiling ?? .harness
  }

  struct TierRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  /// What the double is allowed to answer at the Private API tier.
  ///
  /// **Only the operations whose fixture recorded a 200.** The reason is the one the
  /// `ReplayServer` header already gives for its five read closures: three of the recorded
  /// helper fixtures are 500s FROM THE REFERENCE, and a double that succeeded there would
  /// manufacture agreement instead of finding a difference. `leaveChat` is the sharp case —
  /// the corpus holds both a 200 and a 500 for it — so it is left throwing and its 200 sits
  /// in the baseline where it can be read.
  ///
  /// `notifyAnyways` is deliberately NOT here even though its fixture records a 200. The
  /// route does not merely call the helper: it then WAITS for a column on the row to move,
  /// which is what `FailingPrivateAPI.onNotify` exists to fake. Letting the plain set admit
  /// it made the call succeed and the wait run to its timeout, so the fixture failed as a
  /// harness error rather than a comparison. `edit` and `unsend` have the same shape.
  ///
  /// Empty at `.harness`, so the default run is byte-for-byte the run it always was.
  static func succeedingOperations(at ceiling: ReplayTier) -> Set<FailingPrivateAPIOperation> {
    guard ceiling >= .privateAPIDouble else { return [] }
    return [
      .markRead, .markUnread,
      .startTyping, .stopTyping,
      .setDisplayName, .updateGroupPhoto,
      .addParticipant, .removeParticipant,
      .shareNickname, .modifyActiveAlias,
      .deleteChat,
    ]
  }
}

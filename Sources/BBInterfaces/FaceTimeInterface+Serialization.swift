//  FaceTimeInterface+Serialization
//  The FaceTime routes' wire shapes, projected from the typed values `FaceTimeInterface`
//  returns.
//
//  Here rather than in the handlers so the app and a test reach the same projection the
//  routes send, and so the handler stays parse, call, serialize. The inherited routes and the
//  additive ones use DIFFERENT shapes for a link; `inheritedLinkPayload` says why.

import BBCore
import BBFaceTime
import BBPrivateAPIContract
import BBSystem
import Foundation

extension FaceTimeInterface {

  /// The inherited routes' shape, which is NOT the same as the additive routes'.
  ///
  /// Node answers `session` and `answer` with `data.link`: a bare URL STRING:
  ///
  ///     new Success(ctx, { data: { link } })      // link is session.url
  ///
  /// Answering with `data.url` instead gives an existing client reading `data.link`
  /// `undefined` on the two routes it already depends on.
  ///
  /// `link` is the compatibility contract; `url`/`group_uuid` ride along because extra keys
  /// are harmless to a client that ignores them, and the group UUID is what a client needs
  /// to admit joiners.
  public static func inheritedLinkPayload(_ link: FaceTimeLink) -> JSONValue {
    guard case .object(var fields) = linkObject(link) else {
      return .object(["link": .string(link.url)])
    }
    fields["link"] = .string(link.url)
    return .object(fields)
  }

  /// What `facetime/call` answers with: the call that is now ringing, and the link.
  ///
  /// Named rather than an object literal, for the reason `ResponseBodies` documents: a hand-written schema is testimony, and until something executes the
  /// serializer nothing cross-examines it. `FaceTimeResponseShapeTests` holds this against
  /// the declaration, including which fields survive when the optional halves are absent,
  /// which is the part a literal makes impossible to check.
  public static func placedCallPayload(link: FaceTimeLink, call: FaceTimeCall) -> JSONValue {
    .object([
      "link": linkObject(link),
      "call": callObject(call),
    ])
  }

  /// What `facetime/:group_uuid/admit` answers with.
  ///
  /// `admitted` is always true: a refusal is an error response, not a `false` here. Stated
  /// rather than omitted so a client has something positive to branch on.
  public static func admittedPayload(address: String) -> JSONValue {
    .object(["admitted": .bool(true), "address": .string(address)])
  }

  public static func linkObject(_ link: FaceTimeLink) -> JSONValue {
    var fields: [String: JSONValue] = ["url": .string(link.url)]
    if let group = link.groupUUID { fields["group_uuid"] = .string(group) }
    if let name = link.name { fields["name"] = .string(name) }
    if let expires = link.expiresAt {
      fields["expiration"] = .int(Int(expires.epochMilliseconds(rounded: .toNearestOrAwayFromZero)))
    }
    return .object(fields)
  }

  public static func callObject(_ call: FaceTimeCall) -> JSONValue {
    var fields: [String: JSONValue] = [
      "call_uuid": .string(call.callUUID),
      "status": .string(call.status.name),
      "is_video": .bool(call.isVideo),
    ]
    if let handle = call.handle { fields["address"] = .string(handle.value) }
    if let group = call.groupUUID { fields["group_uuid"] = .string(group) }
    return .object(fields)
  }

  /// One call-log entry, in the shape the rest of the FaceTime API uses.
  ///
  /// The database's vocabulary is NOT the wire's, and the mapping is deliberate:
  ///
  ///   - `ZUNIQUE_ID` is the call's UUID (the same value `TUCall.callUUID` reports) so it
  ///     goes out as `call_uuid`, matching `callObject`. A client can correlate a recents
  ///     entry with a live call it already holds.
  ///   - `ZSERVICE_PROVIDER` is a bundle id (`com.apple.FaceTime`). Everywhere else in this
  ///     API `service` is a NAME a client displays ("iMessage", "SMS") so it is mapped to
  ///     "FaceTime"/"Phone" rather than leaking Apple's identifier.
  ///   - `participants` are handle OBJECTS, because `chat.participants` are, and a client
  ///     that already renders those should not need a second code path for bare strings.
  ///   - Times are milliseconds, like every other time value the API returns. `duration`
  ///     included, so `date_created + duration` is meaningful rather than a unit trap.
  ///
  /// `is_missed` is derived rather than stored: the log records direction and answer
  /// separately, and an unanswered OUTGOING call is not a missed call.
  public static func callRecordObject(_ call: CallRecord) -> JSONValue {
    var fields: [String: JSONValue] = [
      "call_uuid": .string(call.id),
      "date_created": .int(Int(call.date.epochMilliseconds(rounded: .toNearestOrAwayFromZero))),
      "duration": .int(Int((call.duration * 1000).rounded())),
      "is_outgoing": .bool(call.isOutgoing),
      "is_answered": .bool(call.isAnswered),
      "is_missed": .bool(call.isMissed),
      "is_video": .bool(call.isVideo),
      "participants": .array(
        call.participants.map { address in
          .object(["address": .string(address)])
        }),
    ]
    if let address = call.address { fields["address"] = .string(address) }
    if let name = call.displayName { fields["display_name"] = .string(name) }
    if let service = call.service { fields["service"] = .string(serviceName(service)) }
    if let group = call.groupUUID { fields["group_uuid"] = .string(group) }
    return .object(fields)
  }

  /// The provider bundle id, as a name a client can show.
  ///
  /// Falls through to the raw value rather than guessing: a provider we have not seen is
  /// better reported verbatim than flattened into "Phone" and quietly mislabelled.
  public static func serviceName(_ provider: String) -> String {
    switch provider {
    case "com.apple.FaceTime": "FaceTime"
    case "com.apple.Telephony", "com.apple.telephony": "Phone"
    default: provider
    }
  }

  public static func memberObject(_ member: FaceTimeMember) -> JSONValue {
    var fields: [String: JSONValue] = [
      "address": .string(member.handle.value),
      // The authority on presence: roster membership is not presence, see
      // FaceTimeMember.isActive.
      "is_active": .bool(member.isActive),
      "is_lightweight": .bool(member.isLightweight),
      "is_pending": .bool(member.isPending),
      // Both surfaced deliberately: "is_pending" alone cannot distinguish "never
      // knocked" from "knocked and was admitted", and that distinction is what the
      // hand-off decision rests on.
      "is_waiting_to_be_let_in": .bool(member.isWaitingToBeLetIn),
      "joined_from_let_me_in": .bool(member.joinedFromLetMeIn),
    ]
    if let name = member.handle.displayName { fields["display_name"] = .string(name) }
    if let nickname = member.nickname { fields["nickname"] = .string(nickname) }
    return .object(fields)
  }

  /// What `facetime/cleanup` answers with.
  ///
  /// `failure` is surfaced rather than swallowed: an empty result is otherwise
  /// indistinguishable from "there was nothing to clean up".
  public static func cleanupPayload(_ result: FaceTimeCoordinator.CleanupResult) -> JSONValue {
    var fields: [String: JSONValue] = [
      "invalidated_links": .array(result.links.map(JSONValue.string)),
      "left_calls": .array(result.calls.map(JSONValue.string)),
      "dismissed_alerts": .int(result.alerts),
      "count": .int(result.links.count + result.calls.count),
    ]
    if let failure = result.failure { fields["failure"] = .string(failure) }
    return .object(fields)
  }
}

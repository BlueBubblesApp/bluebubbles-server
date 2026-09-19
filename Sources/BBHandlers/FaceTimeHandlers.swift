//  FaceTimeHandlers
//  Controllers for FaceTime: the three inherited routes and the additive flows.
//
//  Three flows (docs/headers/FACETIME.md), all gated behind `enable_ft_private_api`:
//    A. Mint a link, hand it back.                          → `link`, and `session` (inherited)
//    B. Dial the person, hand back a link.                  → `call`
//    C. Answer an incoming call, hand back a link, drop.    → `handoff`, and `answer` (inherited)
//
//  Every operation is `FaceTimeInterface`; these parse the request, apply the setting gates,
//  and project the typed result onto the wire. The one decision made HERE is how a call that
//  was placed without a link is reported (an error carrying the call) because that is a
//  wire shape, not a meaning.

import BBFaceTime
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSettings
import BBSystem
import Foundation

public enum FaceTimeHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & SettingsProviding
  ) {
    registerInherited(into: &registry, context: context)
    registerEnhanced(into: &registry, context: context)
  }

  // MARK: - Inherited routes (facetime/session, answer, leave)
  //
  // These sit in the DEFAULT route table for Node parity, so they are always mounted, but
  // they drive the same experimental FaceTime helper, so they are gated on the flag too and
  // answer 403 with the flag's reason until it is enabled. That is better than the 501
  // placeholder they replace: a client is told what to turn on.

  private static func registerInherited(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & SettingsProviding
  ) {
    registry.register(.facetimeNewSession) { _ in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let link = try await context.faceTimeInterface().mintLink()
      return .data(inheritedLinkPayload(link))
    }

    registry.register(.facetimeAnswer) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let link = try await context.faceTimeInterface().answer(
        callUUID: try request.requirePathParameter("call_uuid")
      )
      return .data(inheritedLinkPayload(link))
    }

    registry.register(.facetimeLeave) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      try await context.faceTimeInterface().leave(
        callUUID: try request.requirePathParameter("call_uuid")
      )
      // The inherited route replies 201 "No Data"; asserted by the parity harness.
      return .noData
    }
  }

  // MARK: - Additive routes

  private static func registerEnhanced(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & SettingsProviding
  ) {

    // Flow A: a bare link. `{ "addresses": [...] }` pre-invites those people onto it.
    registry.register(.facetimeGenerateLink) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      // `values()` and not `try? jsonBody()`: an absent body is still an empty object, but
      // a body that is not JSON fails the request instead of minting a link with nobody
      // invited. Every sibling route reads its body this way.
      let values = try request.values()
      let invited = values["addresses"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let link = try await context.faceTimeInterface().mintLink(invitedAddresses: invited)
      return .data(.object(["link": payloadObject(link)]))
    }

    // Hang up the Mac's side of a call, by UUID in the body.
    registry.register(.facetimeLeaveCall) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let values = try request.values()
      guard let callUUID = values["callUUID"]?.stringValue ?? values["call_uuid"]?.stringValue,
        !callUUID.isEmpty
      else {
        throw BadRequest("`callUUID` is required")
      }
      try await context.faceTimeInterface().leave(callUUID: callUUID)
      return .data(.object(["left": .bool(true), "call_uuid": .string(callUUID)]))
    }

    // Invalidate active links: user-driven cleanup.
    registry.register(.facetimeInvalidateLinks) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      // No body means "every link the server minted"; a body that is not JSON is refused
      // rather than read as that, which would invalidate everything on a client typo.
      let values = try request.values()
      let urls = values["urls"]?.arrayValue?.compactMap(\.stringValue)
      let invalidated = try await context.faceTimeInterface().invalidateLinks(urls: urls)
      return .data(
        .object([
          "invalidated": .array(invalidated.map(JSONValue.string)),
          "count": .int(invalidated.count),
        ]))
    }

    // Flow B: place a call AND hand back a link.
    registry.register(.facetimeCall) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      // The narrower switch, checked separately. Dialling is the one FaceTime capability
      // that reaches OUT: it makes this Mac ring somebody else's phone on a client's
      // say-so, so it is refusable without giving up links and call control. Checked here
      // rather than by unmounting the route, so a client that asks gets a reason instead of
      // a 404 it cannot tell from an old server.
      try await requireFaceTimeSetting(Settings.faceTimeOutgoingCalls, context)
      let values = try request.values()
      let addresses =
        values["addresses"]?.arrayValue?.compactMap(\.stringValue)
        ?? values["address"]?.stringValue.map { [$0] } ?? []
      // Audio-only when false: reaches `TUDialRequest.setVideo:`, so the callee's device
      // rings as FaceTime Audio rather than video.
      let video = values["video"]?.boolValue ?? true

      let placed = try await context.faceTimeInterface().placeCall(
        addresses: addresses, video: video
      )
      guard let link = placed.link else {
        // The call IS up and ringing: say so, and hand back the call so a client can
        // retry the link or hang up deliberately, rather than a bare error that hides
        // a live call.
        throw IMessageError(
          "The call was placed, but FaceTime returned no join link. "
            + "The call is active; use POST facetime/leave to end it.",
          data: .object(["call": callObject(placed.call)])
        )
      }
      return .data(placedCallPayload(link: link, call: placed.call))
    }

    // Admit a knocker. `:group_uuid` is the conversation; the address is in the body.
    registry.register(.facetimeAdmit) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let group = try request.requirePathParameter("group_uuid")
      let address = try request.values().requireString("address")
      try await context.faceTimeInterface().admit(conversationUUID: group, address: address)
      return .data(admittedPayload(address: address))
    }

    // Read who is in a conversation, and who is knocking.
    registry.register(.facetimeMembers) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let members = try await context.faceTimeInterface().members(
        conversationUUID: try request.requirePathParameter("group_uuid")
      )
      return .data(.array(members.map(memberObject)))
    }

    registerDebugDiagnostics(into: &registry, context: context)

    // Recent calls. The ONLY FaceTime route that needs no helper and no injection: it
    // reads the macOS call log, which FaceTime writes whether or not we are hooked into
    // it. `?limit=`/`?offset=` page it; `?service=all` includes carrier phone calls,
    // which the log stores in the same table.
    registry.register(.facetimeRecents) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let limit = min(max(request.integer("limit") ?? 50, 1), 500)
      let offset = max(request.integer("offset") ?? 0, 0)
      let faceTimeOnly = request.queryParameters["service"]?.lowercased() != "all"

      // A Mac with no call log is not an error: it is a Mac that has never placed a
      // call. Answer with an empty page rather than a 500.
      guard let history = await context.callHistory() else {
        return .data(
          .array([]),
          metadata: .object([
            "limit": .int(limit), "offset": .int(offset), "total": .int(0),
          ]))
      }
      let calls = try await history.recents(
        limit: limit, offset: offset, faceTimeOnly: faceTimeOnly
      )
      return .data(
        .array(calls.map(callRecordObject)),
        metadata: .object([
          "limit": .int(limit),
          "offset": .int(offset),
          "count": .int(calls.count),
        ])
      )
    }

    // Clear up after ourselves: stray links, and calls the Mac is stuck in. Backs the
    // settings button as well as this route. Only ever touches links the SERVER minted.
    registry.register(.facetimeCleanup) { _ in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      return .data(cleanupPayload(try await context.faceTimeInterface().cleanUp()))
    }

    // Flow C: answer an incoming call, hand back a link, admit joiners, then drop. The
    // link goes back to the client NOW; the hand-off runs under the coordinator.
    registry.register(.facetimeHandoff) { request in
      try await requireFaceTimeSetting(Settings.faceTimeIncomingHandoff, context)
      let link = try await context.faceTimeInterface().handOff(
        callUUID: try request.requirePathParameter("call_uuid")
      )
      return .data(inheritedLinkPayload(link))
    }
  }

  // MARK: - Payloads

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
  static func inheritedLinkPayload(_ link: FaceTimeLink) -> JSONValue {
    guard case .object(var fields) = payloadObject(link) else {
      return .object(["link": .string(link.url)])
    }
    fields["link"] = .string(link.url)
    return .object(fields)
  }

  /// What `facetime/call` answers with: the call that is now ringing, and the link.
  ///
  /// Named rather than an object literal in the handler, for the reason `ResponseBodies`
  /// documents: a hand-written schema is testimony, and until something executes the
  /// serializer nothing cross-examines it. `FaceTimeResponseShapeTests` holds this against
  /// the declaration, including which fields survive when the optional halves are absent,
  /// which is the part a literal makes impossible to check.
  static func placedCallPayload(link: FaceTimeLink, call: FaceTimeCall) -> JSONValue {
    .object([
      "link": payloadObject(link),
      "call": callObject(call),
    ])
  }

  /// What `facetime/:group_uuid/admit` answers with.
  ///
  /// `admitted` is always true: a refusal is an error response, not a `false` here. Stated
  /// rather than omitted so a client has something positive to branch on.
  static func admittedPayload(address: String) -> JSONValue {
    .object(["admitted": .bool(true), "address": .string(address)])
  }

  private static func payloadObject(_ link: FaceTimeLink) -> JSONValue {
    var fields: [String: JSONValue] = ["url": .string(link.url)]
    if let group = link.groupUUID { fields["group_uuid"] = .string(group) }
    if let name = link.name { fields["name"] = .string(name) }
    if let expires = link.expiresAt {
      fields["expiration"] = .int(Int((expires.timeIntervalSince1970 * 1000).rounded()))
    }
    return .object(fields)
  }

  private static func callObject(_ call: FaceTimeCall) -> JSONValue {
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
  static func callRecordObject(_ call: CallRecord) -> JSONValue {
    var fields: [String: JSONValue] = [
      "call_uuid": .string(call.id),
      "date_created": .int(Int((call.date.timeIntervalSince1970 * 1000).rounded())),
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
  static func serviceName(_ provider: String) -> String {
    switch provider {
    case "com.apple.FaceTime": "FaceTime"
    case "com.apple.Telephony", "com.apple.telephony": "Phone"
    default: provider
    }
  }

  private static func memberObject(_ member: FaceTimeMember) -> JSONValue {
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

  // MARK: - Shared

  /// What `facetime/cleanup` answers with.
  ///
  /// `failure` is surfaced rather than swallowed: an empty result is otherwise
  /// indistinguishable from "there was nothing to clean up".
  static func cleanupPayload(_ result: FaceTimeCoordinator.CleanupResult) -> JSONValue {
    var fields: [String: JSONValue] = [
      "invalidated_links": .array(result.links.map(JSONValue.string)),
      "left_calls": .array(result.calls.map(JSONValue.string)),
      "dismissed_alerts": .int(result.alerts),
      "count": .int(result.links.count + result.calls.count),
    ]
    if let failure = result.failure { fields["failure"] = .string(failure) }
    return .object(fields)
  }

  /// Gate on a user-facing SETTING rather than a developer feature flag.
  ///
  /// FaceTime is a capability a user turns on, exactly like the Messages Private API, so it
  /// is a toggle in Settings, not a flag. The 403 names the setting so a client is told what
  /// to switch on rather than being told a route does not exist.
  private static func requireFaceTimeSetting(
    _ setting: Setting<Bool>,
    _ context: some SettingsProviding
  ) async throws {
    guard await context.settings.get(setting) else {
      throw Forbidden(
        "\(setting.presentation?.label ?? setting.key) is disabled on this server. "
          + "Enable `\(setting.key)` in the server settings to use it."
      )
    }
  }

  // MARK: - Debug-only diagnostics

  /// Registered ONLY in a development build, matching `AdditiveRoutes.debugDiagnostics`.
  ///
  /// A release build contains neither the routes nor these handlers, so there is no runtime
  /// switch (not a setting, not an environment variable) that can expose them on a
  /// production server. `debug` returns raw `TUConversation` internals; `windows` reports
  /// another app's UI state; `dismiss-alert` drives it.
  ///
  /// These exist because the FaceTime work could not be done without them: the lobby-state
  /// and stale-link findings both came from reading raw state on a live call. Keeping them
  /// costs nothing in production and saves rediscovering all of it next time.
  private static func registerDebugDiagnostics(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & SettingsProviding
  ) {
    #if DEBUG
      registry.register(.facetimeDebug) { request in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let state = try await context.faceTimeInterface().debugState(
          conversationUUID: try request.requirePathParameter("group_uuid")
        )
        return .data(.object(state.mapValues(JSONValue.string)))
      }

      registry.register(.facetimeWindows) { _ in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        return .data(
          .object([
            "windows": .array(
              try await context.faceTimeInterface().windows().map(JSONValue.string)
            )
          ]))
      }

      // Cancels rather than confirms: the alert's other buttons offer to call a DIFFERENT
      // address on the contact card. Production gets this automatically via FaceTimeCleanup.
      registry.register(.facetimeDismissAlert) { _ in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let dismissed = try await context.faceTimeInterface().dismissAlert()
        return .data(
          .object([
            "dismissed": .int(dismissed),
            "was_blocked": .bool(dismissed > 0),
          ]))
      }
    #endif
  }
}

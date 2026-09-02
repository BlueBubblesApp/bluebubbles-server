//  FaceTimeHandlers
//  Controllers for FaceTime — the three inherited routes and the additive flows.
//
//  Three flows (docs/headers/FACETIME.md), all gated behind `enable_ft_private_api`:
//    A. Mint a link, hand it back.                          → `link`, and `session` (inherited)
//    B. Dial the person, hand back a link.                  → `call`
//    C. Answer an incoming call, hand back a link, drop.    → `handoff`, and `answer` (inherited)
//
//  The hand-off — admit joiners, leave once a client has really joined — is
//  `FaceTimeHandOff`, owned by `FaceTimeCoordinator`. The handlers start it and answer.

import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSettings
import BBSystem
import Foundation
import Logging

public enum FaceTimeHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) {
    registerInherited(into: &registry, context: context)
    registerEnhanced(into: &registry, context: context)
  }

  // MARK: - Inherited routes (facetime/session, answer, leave)
  //
  // These sit in the DEFAULT route table for Node parity, so they are always mounted — but
  // they drive the same experimental FaceTime helper, so they are gated on the flag too and
  // answer 403 with the flag's reason until it is enabled. That is better than the 501
  // placeholder they replace: a client is told what to turn on.

  private static func registerInherited(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) {
    registry.register(.facetimeNewSession) { _ in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "creating a FaceTime link")
      let link = try await api.generateFaceTimeLink(invitedAddresses: [])
      await context.faceTime().links.record(url: link.url, groupUUID: link.groupUUID)
      return .data(inheritedLinkPayload(link))
    }

    registry.register(.facetimeAnswer) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "answering a FaceTime call")
      let callUUID = try pathCallUUID(request)
      try await api.answerFaceTimeCall(callUUID: callUUID)
      // Answering a 1:1 call and minting a link upgrades it to a joinable conversation.
      let link = try await api.generateFaceTimeLinkForCall(callUUID: callUUID)
      return .data(inheritedLinkPayload(link))
    }

    registry.register(.facetimeLeave) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "leaving a FaceTime call")
      try await api.leaveFaceTimeCall(callUUID: try pathCallUUID(request))
      // The inherited route replies 201 "No Data" — asserted by the parity harness.
      return .noData
    }
  }

  // MARK: - Additive routes

  private static func registerEnhanced(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) {

    // Flow A — a bare link.
    registry.register(.facetimeGenerateLink) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "creating a FaceTime link")
      // `{ "addresses": [...] }` pre-invites those people onto the link.
      //
      // NO MEDIA OPTION, deliberately. A `TUConversationLink` carries no media type —
      // whoever joins picks their own camera. macOS records a bare link in the call log
      // as a VIDEO call (`ZCALLTYPE = 8`), which is the sensible default for a link
      // anyone might join. Choosing audio vs video is a property of placing a CALL, so
      // it lives on `POST facetime/call` and its `video` flag.
      let body = (try? request.jsonBody()) ?? nil
      let invited = body?["addresses"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let link = try await api.generateFaceTimeLink(invitedAddresses: invited)
      await context.faceTime().links.record(url: link.url, groupUUID: link.groupUUID)
      return .data(.object(["link": payloadObject(link)]))
    }

    // Hang up the Mac's side of a call, by UUID in the body.
    registry.register(.facetimeLeaveCall) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "leaving a FaceTime call")
      let values = try request.values()
      guard let callUUID = values["callUUID"]?.stringValue ?? values["call_uuid"]?.stringValue,
        !callUUID.isEmpty
      else {
        throw BadRequest("`callUUID` is required")
      }
      try await api.leaveFaceTimeCall(callUUID: callUUID)
      return .data(.object(["left": .bool(true), "call_uuid": .string(callUUID)]))
    }

    // Invalidate active links — user-driven cleanup.
    registry.register(.facetimeInvalidateLinks) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "invalidating FaceTime links")
      let body = (try? request.jsonBody()) ?? nil
      let urls = body?["urls"]?.arrayValue?.compactMap(\.stringValue)
      let invalidated = try await api.invalidateFaceTimeLinks(urls: urls)
      return .data(
        .object([
          "invalidated": .array(invalidated.map(JSONValue.string)),
          "count": .int(invalidated.count),
        ]))
    }

    // Place a call AND hand back a link.
    //
    // ALWAYS dials — deliberately not switchable. Branching on a server-side mode whose
    // other value minted a bare link instead would mean the same request either rang
    // somebody or did not, depending on configuration the client cannot see. A client asking
    // to call someone should never silently get a link nobody was called for; if it wants a
    // bare link it asks for one, at `POST facetime/link`.
    registry.register(.facetimeCall) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "starting a FaceTime call")
      let values = try request.values()
      let addresses =
        values["addresses"]?.arrayValue?.compactMap(\.stringValue)
        ?? values["address"]?.stringValue.map { [$0] } ?? []
      // Audio-only when false: reaches `TUDialRequest.setVideo:`, so the callee's device
      // rings as FaceTime Audio rather than video.
      let video = values["video"]?.boolValue ?? true

      guard !addresses.isEmpty else {
        throw BadRequest("`address` is required to place a call")
      }

      // PRE-FLIGHT. Dialling an address that is not FaceTime-capable does not fail: a
      // `TUCall` is created and reports `outgoing`, so the API answered "the call was
      // placed" while FaceTime.app quietly put up "…is not available for FaceTime" and
      // no conversation ever formed. The client saw a confusing "placed but no link"
      // 500 for a call that never had a chance.
      //
      // Checked here so the honest error arrives BEFORE a phantom call exists.
      try await requireFaceTimeCapable(
        addresses,
        isAvailable: { try await api.checkFaceTimeAvailability(address: $0) },
        logger: context.logger
      )

      let call = try await api.dialFaceTime(
        FaceTimeStartRequest(addresses: addresses, video: video)
      )

      // Mint the link, but do NOT let a link failure strand the Mac.
      //
      // The moment the dial returns, the Mac is a live participant in a call it placed.
      // Arming the hand-off watcher only AFTER a successful link meant any failure in
      // between left the Mac sitting in the call indefinitely — observed on a live
      // call, where the callee answered and the Mac never left. So the watcher is armed
      // off the CALL, and the link is reported separately.
      let link = try? await api.generateFaceTimeLinkForCall(callUUID: call.callUUID)
      if let link {
        await context.faceTime().links.record(url: link.url, groupUUID: link.groupUUID)
      }

      if let group = link?.groupUUID ?? call.groupUUID {
        // Owned by the coordinator, which marks the call so cleanup never hangs up on a
        // hand-off that is still running, and cancels it if the Private API goes away.
        await context.faceTime().beginHandOff(
          api: api, callUUID: call.callUUID, conversationUUID: group,
          dialledAddresses: addresses
        )
      }

      guard let link else {
        // The call IS up and ringing — say so, and hand back the call so a client can
        // retry the link or hang up deliberately, rather than a bare error that hides
        // a live call.
        throw IMessageError(
          "The call was placed, but FaceTime returned no join link. "
            + "The call is active; use POST facetime/leave to end it.",
          data: .object(["call": callObject(call)])
        )
      }

      return .data(
        .object([
          "link": payloadObject(link),
          "call": callObject(call),
        ]))
    }

    // Admit a knocker. `:group_uuid` is the conversation; the address is in the body.
    registry.register(.facetimeAdmit) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "admitting a FaceTime participant")
      let group = try pathParameter(request, "group_uuid")
      let values = try request.values()
      let address = try values.requireString("address")
      try await api.admitFaceTimeParticipant(conversationUUID: group, handle: address)
      return .data(.object(["admitted": .bool(true), "address": .string(address)]))
    }

    // Read who is in a conversation, and who is knocking.
    registry.register(.facetimeMembers) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "reading FaceTime members")
      let members = try await api.faceTimeMembers(
        conversationUUID: try pathParameter(request, "group_uuid")
      )
      return .data(.array(members.map(memberObject)))
    }

    // Recent calls. The ONLY FaceTime route that needs no helper and no injection — it
    // reads the macOS call log, which FaceTime writes whether or not we are hooked into
    // it. `?limit=`/`?offset=` page it; `?service=all` includes carrier phone calls,
    // which the log stores in the same table.
    registerDebugDiagnostics(into: &registry, context: context)

    registry.register(.facetimeRecents) { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let limit = min(max(intQuery(request, "limit") ?? 50, 1), 500)
      let offset = max(intQuery(request, "offset") ?? 0, 0)
      let faceTimeOnly = request.queryParameters["service"]?.lowercased() != "all"

      // A Mac with no call log is not an error — it is a Mac that has never placed a
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

    // What FaceTime.app is showing — a diagnostic for a dial that went nowhere.
    // Clear up after ourselves: stray links, and calls the Mac is stuck in. Backs the
    // settings button as well as this route. Only ever touches links the SERVER minted.
    registry.register(.facetimeCleanup) { _ in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      _ = try await requirePrivateAPI(context, for: "cleaning up FaceTime state")
      // The route means "clear them now", not "clear the old ones".
      let result = await context.faceTime().cleanUp(clearAll: true)
      var fields: [String: JSONValue] = [
        "invalidated_links": .array(result.links.map(JSONValue.string)),
        "left_calls": .array(result.calls.map(JSONValue.string)),
        "dismissed_alerts": .int(result.alerts),
        "count": .int(result.links.count + result.calls.count),
      ]
      // Surfaced rather than swallowed: an empty result is otherwise indistinguishable
      // from "there was nothing to clean up".
      if let failure = result.failure { fields["failure"] = .string(failure) }
      return .data(.object(fields))
    }

    // Flow C — answer an incoming call, hand back a link, admit joiners, then drop.
    registry.register(.facetimeHandoff) { request in
      try await requireFaceTimeSetting(Settings.faceTimeIncomingHandoff, context)
      let api = try await requirePrivateAPI(context, for: "handing off a FaceTime call")
      let callUUID = try pathCallUUID(request)

      try await api.answerFaceTimeCall(callUUID: callUUID)
      let link = try await api.generateFaceTimeLinkForCall(callUUID: callUUID)

      // The link goes back to the client NOW. Admitting joiners and dropping the Mac
      // happens in the background so the client can join immediately — and the Mac only
      // drops once someone actually has, never on a timer alone.
      if let group = link.groupUUID {
        await context.faceTime().beginHandOff(
          api: api, callUUID: callUUID, conversationUUID: group
        )
      }
      return .data(inheritedLinkPayload(link))
    }
  }

  // MARK: - Payloads

  /// The inherited routes' shape, which is NOT the same as the additive routes'.
  ///
  /// Node answers `session` and `answer` with `data.link` — a bare URL STRING:
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

  /// Refuses addresses FaceTime cannot call, before a call object exists.
  ///
  /// An UNVERIFIABLE address is allowed through. The check runs through the Messages helper,
  /// so on a server with only the FaceTime helper injected it cannot answer — and refusing
  /// every call because the check is unavailable would be worse than the confusing error
  /// this exists to prevent. Only a definite "not available" blocks.
  /// Takes the availability CHECK rather than the whole API, so the rule — including the
  /// "unverifiable passes through" branch, which is the one that matters and the easiest to
  /// get wrong — is testable without stubbing sixty unrelated methods.
  static func requireFaceTimeCapable(
    _ addresses: [String],
    isAvailable: (String) async throws -> Bool,
    logger: Logger
  ) async throws {
    var unavailable: [String] = []
    for address in addresses {
      do {
        if try await isAvailable(address) == false {
          unavailable.append(address)
        }
      } catch {
        logger.debug(
          "Could not verify FaceTime availability; dialling anyway",
          metadata: [
            "address": .string(address),
            "error": .string(String(describing: error)),
          ])
      }
    }
    guard unavailable.isEmpty else {
      throw BadRequest(
        "Not reachable on FaceTime: \(unavailable.joined(separator: ", ")). "
          + "FaceTime rejects the call without ringing, so no call was placed."
      )
    }
  }

  private static func intQuery(_ request: APIRequestContext, _ name: String) -> Int? {
    request.queryParameters[name].flatMap(Int.init)
  }

  /// One call-log entry, in the shape the rest of the FaceTime API uses.
  ///
  /// The database's vocabulary is NOT the wire's, and the mapping is deliberate:
  ///
  ///   - `ZUNIQUE_ID` is the call's UUID — the same value `TUCall.callUUID` reports — so it
  ///     goes out as `call_uuid`, matching `callObject`. A client can correlate a recents
  ///     entry with a live call it already holds.
  ///   - `ZSERVICE_PROVIDER` is a bundle id (`com.apple.FaceTime`). Everywhere else in this
  ///     API `service` is a NAME a client displays — "iMessage", "SMS" — so it is mapped to
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
      // The authority on presence — roster membership is not presence, see
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

  private static func pathCallUUID(_ request: APIRequestContext) throws -> String {
    try pathParameter(request, "call_uuid")
  }

  private static func pathParameter(_ request: APIRequestContext, _ name: String) throws -> String {
    guard let value = request.pathParameters[name], !value.isEmpty else {
      throw BadRequest("`\(name)` is required in the path")
    }
    return value
  }

  /// Gate on a user-facing SETTING rather than a developer feature flag.
  ///
  /// FaceTime is a capability a user turns on, exactly like the Messages Private API — so it
  /// is a toggle in Settings, not a flag. The 403 names the setting so a client is told what
  /// to switch on rather than being told a route does not exist.
  private static func requireFaceTimeSetting(
    _ setting: Setting<Bool>,
    _ context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) async throws {
    guard await context.settings.get(setting) else {
      throw Forbidden(
        "\(setting.presentation?.label ?? setting.key) is disabled on this server. "
          + "Enable `\(setting.key)` in the server settings to use it."
      )
    }
  }

  private static func requireFeature(
    _ flag: FeatureFlag,
    _ context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) async throws {
    guard await context.settings.isEnabled(flag) else {
      throw Forbidden(
        "\(flag.summary) is disabled on this server. \(flag.rationale) "
          + "Enable `\(flag.key)` in the server settings to use it."
      )
    }
  }

  private static func requirePrivateAPI(
    _ context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding,
    for feature: String
  ) async throws -> any PrivateAPI {
    guard let api = await context.privateAPIClient() else {
      throw IMessageError(
        IMessageError.helperUnavailable().errorMessage,
        data: .object(["feature": .string(feature)])
      )
    }
    return api
  }

  // MARK: - Debug-only diagnostics

  /// Registered ONLY in a development build, matching `AdditiveRoutes.debugDiagnostics`.
  ///
  /// A release build contains neither the routes nor these handlers, so there is no runtime
  /// switch — not a setting, not an environment variable — that can expose them on a
  /// production server. `debug` returns raw `TUConversation` internals; `windows` reports
  /// another app's UI state; `dismiss-alert` drives it.
  ///
  /// These exist because the FaceTime work could not be done without them: the lobby-state
  /// and stale-link findings both came from reading raw state on a live call. Keeping them
  /// costs nothing in production and saves rediscovering all of it next time.
  private static func registerDebugDiagnostics(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding & LoggerProviding & PrivateAPIProviding & SettingsProviding
  ) {
    #if DEBUG
      registry.register(.facetimeDebug) { request in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let api = try await requirePrivateAPI(context, for: "reading FaceTime debug state")
        let state = try await api.faceTimeDebugState(
          conversationUUID: try pathParameter(request, "group_uuid")
        )
        return .data(.object(state.mapValues(JSONValue.string)))
      }

      registry.register(.facetimeWindows) { _ in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let api = try await requirePrivateAPI(context, for: "inspecting FaceTime windows")
        return .data(
          .object([
            "windows": .array(
              try await api.faceTimeWindows().map(JSONValue.string)
            )
          ]))
      }

      // Cancels rather than confirms: the alert's other buttons offer to call a DIFFERENT
      // address on the contact card. Production gets this automatically via FaceTimeCleanup.
      registry.register(.facetimeDismissAlert) { _ in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let api = try await requirePrivateAPI(context, for: "dismissing a FaceTime alert")
        let dismissed = try await api.dismissFaceTimeAlert()
        return .data(
          .object([
            "dismissed": .int(dismissed),
            "was_blocked": .bool(dismissed > 0),
          ]))
      }
    #endif
  }
}

//  FaceTimeHandlers
//  Controllers for FaceTime — the three inherited routes and the additive flows.
//
//  Three flows (docs/headers/FACETIME.md), all gated behind `enable_ft_private_api`:
//    A. Mint a link, hand it back.                          → `link`, and `session` (inherited)
//    B. Dial the person, hand back a link.                  → `call`
//    C. Answer an incoming call, hand back a link, drop.    → `handoff`, and `answer` (inherited)
//
//  WHY THE DROP IS A POLL, NOT A TIMER. Flows B and C must not leave the call until a real
//  participant has joined, or a 1:1 call collapses on the caller. The Node server reads the
//  macOS *notification database* and parses serialized join notifications to know this — the
//  "almost never works" hack. Here the helper exposes typed membership (`faceTimeMembers`), so
//  the drop is gated on an actual member appearing, polled, with a hard timeout. When the
//  helper's membership *event* proves reliable on-device, this poll can be replaced by it.

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
    registry.register("facetime.newSession") { _ in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "creating a FaceTime link")
      let link = try await api.generateFaceTimeLink(invitedAddresses: [])
      await context.faceTime().links.record(url: link.url, groupUUID: link.groupUUID)
      return .data(inheritedLinkPayload(link))
    }

    registry.register("facetime.answer") { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "answering a FaceTime call")
      let callUUID = try pathCallUUID(request)
      try await api.answerFaceTimeCall(callUUID: callUUID)
      // Answering a 1:1 call and minting a link upgrades it to a joinable conversation.
      let link = try await api.generateFaceTimeLinkForCall(callUUID: callUUID)
      return .data(inheritedLinkPayload(link))
    }

    registry.register("facetime.leave") { request in
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
    registry.register("facetime.generateLink") { request in
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
    registry.register("facetime.leaveCall") { request in
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
    registry.register("facetime.invalidateLinks") { request in
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

    // Flow A or B, chosen by `facetime_outgoing_mode`.
    // Place a call AND hand back a link (Flow B).
    //
    // ALWAYS dials. This used to branch on a `facetime_outgoing_mode` setting whose
    // other value quietly minted a bare link instead — so the same request either rang
    // somebody or did not, depending on server configuration the client cannot see. A
    // client asking to call someone should never silently get a link nobody was called
    // for; if it wants a bare link it asks for one, at `POST facetime/link`.
    registry.register("facetime.call") { request in
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
        Task.detached {
          // Marked so cleanup never hangs up on a hand-off that is still running.
          await context.faceTime().beginHandOff(callUUID: call.callUUID)
          await admitThenDrop(
            api: api, callUUID: call.callUUID, conversationUUID: group,
            dialledAddresses: addresses, logger: context.logger
          )
          await context.faceTime().endHandOff(callUUID: call.callUUID)
        }
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
    registry.register("facetime.admit") { request in
      try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
      let api = try await requirePrivateAPI(context, for: "admitting a FaceTime participant")
      let group = try pathParameter(request, "group_uuid")
      let values = try request.values()
      let address = try values.requireString("address")
      try await api.admitFaceTimeParticipant(conversationUUID: group, handle: address)
      return .data(.object(["admitted": .bool(true), "address": .string(address)]))
    }

    // Read who is in a conversation, and who is knocking.
    registry.register("facetime.members") { request in
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

    registry.register("facetime.recents") { request in
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
    registry.register("facetime.cleanup") { _ in
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
    registry.register("facetime.handoff") { request in
      try await requireFaceTimeSetting(Settings.faceTimeIncomingHandoff, context)
      let api = try await requirePrivateAPI(context, for: "handing off a FaceTime call")
      let callUUID = try pathCallUUID(request)

      try await api.answerFaceTimeCall(callUUID: callUUID)
      let link = try await api.generateFaceTimeLinkForCall(callUUID: callUUID)

      // The link goes back to the client NOW. Admitting joiners and dropping the Mac
      // happens in the background so the client can join immediately — and the Mac only
      // drops once someone actually has, never on a timer alone.
      if let group = link.groupUUID {
        Task.detached {
          await context.faceTime().beginHandOff(callUUID: callUUID)
          await admitThenDrop(
            api: api, callUUID: callUUID, conversationUUID: group,
            logger: context.logger
          )
          await context.faceTime().endHandOff(callUUID: callUUID)
        }
      }
      return .data(inheritedLinkPayload(link))
    }
  }

  // MARK: - Flow C orchestration

  /// Admits anyone knocking, waits for a real participant to join, then drops the Mac.
  ///
  /// Bounded at two minutes — the same ceiling the Node server uses — because a link nobody
  /// joins must not pin the Mac in a call forever. Reads typed membership rather than the
  /// notification database. Best-effort: every failure degrades to "the Mac stays in the
  /// call until the timeout drops it," never to a crash.
  /// Admits anyone knocking, waits until the Mac is genuinely SURPLUS, then drops it.
  ///
  /// THE COUNT IS THE WHOLE POINT, and getting it wrong hangs up on a real person.
  ///
  /// A FaceTime call does not survive dropping below two participants. On a 1:1 call the
  /// participants are the Mac and the callee — so "leave once a real participant has
  /// joined" (the previous condition) was satisfied the instant the callee ANSWERED, and
  /// leaving then collapses the call on them. Measured on a live call: the callee answered
  /// and the Mac was still the only thing holding the conversation open.
  ///
  /// The Mac may only leave once the client has ALSO joined — three participants: the Mac,
  /// the callee, and the client. Dropping to two then leaves a working call between the two
  /// people who actually want to talk.
  ///
  /// `remoteMembers` counts everyone in the conversation OTHER than the local (Mac)
  /// participant, so the threshold is two remotes: callee + client.
  /// The Mac may never leave a call with fewer than this many joined remotes behind it —
  /// FaceTime does not keep a call alive below two participants.
  private static let remotesRequiredBeforeLeaving = 2

  /// How long the Mac waits for the hand-off to complete before giving up and staying.
  ///
  /// Two humans have to act inside this window — the callee answers, and only then does the
  /// requesting client open the link and join. Two minutes (the Node server's ceiling) is
  /// not generous for that, and expiring early does not end the call: it just leaves the Mac
  /// parked in it. Five minutes covers a realistic answer-then-join without holding a
  /// forgotten link open for anything like as long as the call itself would run.
  private static let handOffTimeout: Duration = .seconds(300)

  /// Loose handle comparison. `remoteMembers` may report a number in a different format
  /// from the one dialled (`+12025550143` vs `2025550143`), and an email in any casing, so
  /// an exact string match would fail to recognise a person we called.
  private static func sameHandle(_ a: String, _ b: String) -> Bool {
    if a.caseInsensitiveCompare(b) == .orderedSame { return true }
    let digits = { (s: String) in s.filter(\.isNumber) }
    let (da, db) = (digits(a), digits(b))
    // Compare by the last 10 digits, which is what survives country-code differences.
    guard da.count >= 7, db.count >= 7 else { return false }
    return da.suffix(10) == db.suffix(10)
  }

  private static func admitThenDrop(
    api: any PrivateAPI,
    callUUID: String,
    conversationUUID: String,
    dialledAddresses: [String] = [],
    logger: Logger
  ) async {
    let deadline = ContinuousClock.now.advanced(by: handOffTimeout)
    var admitted = Set<String>()

    while ContinuousClock.now < deadline {
      // STOP IF THE CALL IS GONE. Someone cancelling from a client, or the callee
      // declining, ends the call — and there is nothing left to hand off. Polling on
      // regardless kept re-asserting mute and re-admitting members against a call that
      // no longer existed, for the full timeout, every time a call was cancelled.
      //
      // A failed status check is NOT treated as "gone": that would abandon the hand-off
      // on one dropped request and leave the Mac in a live call forever.
      if let status = try? await api.faceTimeCallStatus(callUUID: callUUID),
        status == .disconnected
      {
        logger.info(
          "FaceTime call ended before hand-off; the watcher is stopping",
          metadata: [
            "call": .string(callUUID)
          ])
        return
      }

      let members = (try? await api.faceTimeMembers(conversationUUID: conversationUUID)) ?? []

      // Re-assert mute every poll. It does not stick while the call is still ringing,
      // so applying it once at dial left the Mac's camera and microphone live for the
      // callee. Cheap, idempotent, and it catches the moment the call connects.
      _ = try? await api.silenceFaceTimeCall(callUUID: callUUID)

      // ADMIT anyone knocking. A link-joiner sits at "Waiting to be let in…" until the
      // host approves; nothing else in this system will do it, and the joiner is
      // invisible in `pendingMembers` (see FaceTimeMember.isPending). Retried every
      // poll rather than once, because an admit can land before the daemon has fully
      // registered the knock.
      for waiting in members where !waiting.isActive {
        try? await api.admitFaceTimeParticipant(
          conversationUUID: conversationUUID, handle: waiting.handle.value
        )
        admitted.insert(waiting.handle.value)
      }

      // ACTUALLY CONNECTED remotes only — `isActive`, not "on the roster". A browser
      // appears on the roster the moment it opens the link, while the person is still
      // staring at "Waiting to be let in…"; counting those let the Mac leave before
      // anyone had really joined, and the call died. See FaceTimeMember.isActive.
      let joined = members.filter(\.isActive)
      // The client is the participant we did NOT dial. Identifying it that way rather
      // than by a raw count is what makes GROUP calls correct: dialling three people
      // and waiting for "two remotes" would fire as soon as the second CALLEE answered,
      // dropping the Mac before the client ever arrived — and the person who tapped the
      // button would never be in their own call.
      //
      // It also handles someone not answering: dial A and B, only A picks up, client
      // joins → the client is still recognisably an outsider, so the hand-off completes
      // instead of waiting forever for B.
      // A guest who came in by link has no FaceTime address — their handle is a
      // throwaway `temp:<uuid>` — so `isLightweight` identifies the client directly.
      // Everyone we dialled has a real address we already know, which makes the
      // remaining test a simple "not one of ours".
      let clientJoined =
        joined.contains { member in
          member.isLightweight
            || !dialledAddresses.contains { sameHandle($0, member.handle.value) }
        } && (dialledAddresses.isEmpty ? joined.count >= remotesRequiredBeforeLeaving : true)

      // Both conditions. The outsider check says the hand-off happened; the count says
      // the call survives the Mac leaving.
      if clientJoined, joined.count >= remotesRequiredBeforeLeaving {
        // A short grace so the newest join is fully established before teardown.
        try? await Task.sleep(for: .seconds(3))
        try? await api.leaveFaceTimeCall(callUUID: callUUID)
        logger.info(
          "FaceTime hand-off complete; the Mac left the call",
          metadata: [
            "call": .string(callUUID),
            "remotes": .stringConvertible(joined.count),
          ])
        return
      }

      try? await Task.sleep(for: .seconds(1))
    }

    // TIMED OUT — and the Mac deliberately STAYS. Leaving here would hang up on whoever
    // did answer, which is the opposite of a safe default: the failure mode of staying is
    // an idle participant a human can hang up on, while the failure mode of leaving is
    // ending a live call between real people. The call is reported, not severed.
    logger.warning(
      "FaceTime hand-off timed out before the client joined; the Mac stays in the call rather than hanging up on the other party",
      metadata: ["call": .string(callUUID)]
    )
  }

  // MARK: - Payloads

  /// The inherited routes' shape, which is NOT the same as the additive routes'.
  ///
  /// Node answers `session` and `answer` with `data.link` — a bare URL STRING:
  ///
  ///     new Success(ctx, { data: { link } })      // link is session.url
  ///
  /// This returned `data.url` instead, so an existing client reading `data.link` got
  /// `undefined` on the two routes it already depended on. The comment here previously
  /// claimed the opposite ("the URL at the top level (Node's shape)"), which is how the
  /// divergence survived.
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
      registry.register("facetime.debug") { request in
        try await requireFaceTimeSetting(Settings.enableFaceTimePrivateAPI, context)
        let api = try await requirePrivateAPI(context, for: "reading FaceTime debug state")
        let state = try await api.faceTimeDebugState(
          conversationUUID: try pathParameter(request, "group_uuid")
        )
        return .data(.object(state.mapValues(JSONValue.string)))
      }

      registry.register("facetime.windows") { _ in
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
      registry.register("facetime.dismissAlert") { _ in
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

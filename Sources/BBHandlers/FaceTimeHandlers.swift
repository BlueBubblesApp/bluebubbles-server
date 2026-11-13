//  FaceTimeHandlers
//  Controllers for FaceTime: the three inherited routes and the additive flows.
//
//  Three flows (docs/headers/FACETIME.md), all behind the FaceTime Private API switch:
//    A. Mint a link, hand it back.                          → `link`, and `session` (inherited)
//    B. Dial the person, hand back a link.                  → `call`
//    C. Answer an incoming call, hand back a link, drop.    → `handoff`, and `answer` (inherited)
//
//  Every operation is `FaceTimeInterface` and every projection is
//  `FaceTimeInterface+Serialization`; these parse the request and serialize. The switches
//  are not checked here: each route declares its own in the route table (`requiring:`), and
//  `RouteGates` evaluates them before a handler runs. The one decision made HERE is how a call that was placed without a link is
//  reported (an error carrying the call) because that is an HTTP refusal, not a meaning.

import BBCore
import BBFaceTime
import BBHTTPAPI
import BBInterfaces
import BBPrivateAPIContract
import BBSerialization
import BBSystem
import Foundation

public enum FaceTimeHandlers {

  public static func register(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding
  ) {
    registerInherited(into: &registry, context: context)
    registerEnhanced(into: &registry, context: context)
  }

  // MARK: - Inherited routes (facetime/session, answer, leave)
  //
  // These sit in the DEFAULT route table for Node parity, so they are always mounted, but
  // they drive the same experimental FaceTime helper, so their group is gated on the switch
  // too and answers 403 with the switch's reason until it is enabled. That is better than the
  // 501 placeholder they replace: a client is told what to turn on.

  private static func registerInherited(
    into registry: inout HandlerRegistry,
    context: some FaceTimeProviding
  ) {
    registry.register(.facetimeNewSession) { _ in
      let link = try await context.faceTimeInterface().mintLink()
      return .data(FaceTimeInterface.inheritedLinkPayload(link))
    }

    registry.register(.facetimeAnswer) { request in
      let link = try await context.faceTimeInterface().answer(
        callUUID: try request.requirePathParameter("call_uuid")
      )
      return .data(FaceTimeInterface.inheritedLinkPayload(link))
    }

    registry.register(.facetimeLeave) { request in
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
    context: some FaceTimeProviding
  ) {

    // Flow A: a bare link. `{ "addresses": [...] }` pre-invites those people onto it.
    registry.register(.facetimeGenerateLink) { request in
      // `values()` and not `try? jsonBody()`: an absent body is still an empty object, but
      // a body that is not JSON fails the request instead of minting a link with nobody
      // invited. Every sibling route reads its body this way.
      let values = try request.values()
      let invited = try values.strings("addresses") ?? []
      let link = try await context.faceTimeInterface().mintLink(invitedAddresses: invited)
      return .data(.object(["link": FaceTimeInterface.linkObject(link)]))
    }

    // Hang up the Mac's side of a call, by UUID in the body.
    registry.register(.facetimeLeaveCall) { request in
      let callUUID = try request.values().requireString(
        "callUUID", or: "call_uuid", message: "`callUUID` is required")
      try await context.faceTimeInterface().leave(callUUID: callUUID)
      return .data(.object(["left": .bool(true), "call_uuid": .string(callUUID)]))
    }

    // Invalidate active links: user-driven cleanup.
    registry.register(.facetimeInvalidateLinks) { request in
      // No body means "every link the server minted"; a body that is not JSON is refused
      // rather than read as that, which would invalidate everything on a client typo.
      let values = try request.values()
      // `strings`, which REFUSES a value that is not a list: nil is "every link", so a
      // client sending one URL as a bare string must not be read as asking for all of them.
      let urls = try values.strings("urls")
      let invalidated = try await context.faceTimeInterface().invalidateLinks(urls: urls)
      return .data(
        .object([
          "invalidated": .array(invalidated.map(JSONValue.string)),
          "count": .int(invalidated.count),
        ]))
    }

    // Flow B: place a call AND hand back a link.
    // The route declares the narrower `.faceTimeOutgoingCalls` switch as well as `.faceTime`.
    registry.register(.facetimeCall) { request in
      let values = try request.values()
      let addresses =
        try values.strings("addresses")
        ?? values["address"]?.stringValue.map { [$0] } ?? []
      // Audio-only when false: reaches `TUDialRequest.setVideo:`, so the callee's device
      // rings as FaceTime Audio rather than video.
      let video = values.bool("video") ?? true

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
          data: .object(["call": FaceTimeInterface.callObject(placed.call)])
        )
      }
      return .data(FaceTimeInterface.placedCallPayload(link: link, call: placed.call))
    }

    // Admit a knocker. `:group_uuid` is the conversation; the address is in the body.
    registry.register(.facetimeAdmit) { request in
      let group = try request.requirePathParameter("group_uuid")
      let address = try request.values().requireString("address")
      try await context.faceTimeInterface().admit(conversationUUID: group, address: address)
      return .data(FaceTimeInterface.admittedPayload(address: address))
    }

    // Read who is in a conversation, and who is knocking.
    registry.register(.facetimeMembers) { request in
      let members = try await context.faceTimeInterface().members(
        conversationUUID: try request.requirePathParameter("group_uuid")
      )
      return .data(.array(members.map(FaceTimeInterface.memberObject)))
    }

    registerDebugDiagnostics(into: &registry, context: context)

    // Recent calls. The ONLY FaceTime route that needs no helper and no injection: it
    // reads the macOS call log, which FaceTime writes whether or not we are hooked into
    // it. `?limit=`/`?offset=` page it; `?service=all` includes carrier phone calls,
    // which the log stores in the same table.
    registry.register(.facetimeRecents) { request in
      // This route's own ceiling, 500, below the 1000 the chat.db listings take.
      let page = Page(
        limit: request.integer("limit"), offset: request.integer("offset"),
        defaultLimit: 50, maximumLimit: 500)
      let faceTimeOnly = request.queryParameters["service"]?.lowercased() != "all"

      // A Mac with no call log is not an error: it is a Mac that has never placed a
      // call. Answer with an empty page rather than a 500, in the SAME shape as a full one:
      // `count` and no `total`, because the call log is read a page at a time and never
      // counted.
      guard let history = await context.callHistory() else {
        return .page([], page)
      }
      let calls = try await history.recents(
        limit: page.limit, offset: page.offset, faceTimeOnly: faceTimeOnly
      )
      return .page(calls.map(FaceTimeInterface.callRecordObject), page)
    }

    // Clear up after ourselves: stray links, and calls the Mac is stuck in. Backs the
    // settings button as well as this route. Only ever touches links the SERVER minted.
    registry.register(.facetimeCleanup) { _ in
      return .data(
        FaceTimeInterface.cleanupPayload(try await context.faceTimeInterface().cleanUp()))
    }

    // Flow C: answer an incoming call, hand back a link, admit joiners, then drop. The
    // link goes back to the client NOW; the hand-off runs under the coordinator.
    registry.register(.facetimeHandoff) { request in
      let link = try await context.faceTimeInterface().handOff(
        callUUID: try request.requirePathParameter("call_uuid")
      )
      return .data(FaceTimeInterface.inheritedLinkPayload(link))
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
    context: some FaceTimeProviding
  ) {
    #if DEBUG
      registry.register(.facetimeDebug) { request in
        let state = try await context.faceTimeInterface().debugState(
          conversationUUID: try request.requirePathParameter("group_uuid")
        )
        return .data(.object(state.mapValues(JSONValue.string)))
      }

      registry.register(.facetimeWindows) { _ in
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

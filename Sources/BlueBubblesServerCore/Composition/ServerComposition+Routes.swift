//  ServerComposition+Routes
//  Which route groups are mounted, and the handler for every route.
//
//  A group left out of `routeGroups` is absent from the router and its paths 404, which
//  is how an unconfigured subsystem stays unregistered. A route with no handler yet is
//  mounted answering 501, so the gap is measurable rather than hidden behind a 404.

import BBDiagnostics
import BBEvents
import BBHTTPAPI
import BBHandlers
import BBSettings
import Logging

extension ServerComposition {

  // MARK: - Routes

  /// The additive route groups, chosen by configuration.
  ///
  /// This is where "not registered" is enforced. A group absent from this array is absent
  /// from the router, and its paths 404 exactly like any unknown path.
  static func routeGroups(
    authMode: AuthMode,
    codecs: CodecNegotiator,
    features: Set<String> = [],
    faceTime: Bool = false,
    faceTimeIncoming: Bool = false
  ) async -> [RouteGroup] {
    var groups: [RouteGroup] = []

    // ALWAYS MOUNTED. v2 is not opt-in.
    //
    // Gating it behind a setting would protect nobody. v1 is frozen and stays frozen, which
    // is what actually protects an existing client; v2 is a separate prefix that no v1
    // client asks for. A capability nobody can reach without first being told to flip a
    // hidden setting may as well not exist, and every one of these is a feature a client
    // wants: pinning, stickers, Send Later, polls, app balloons, wallpaper, the full alert
    // and contact-card shapes.
    //
    // The two groups that genuinely should not ship are gated where the gate belongs, in
    // `#if DEBUG` inside their own definitions rather than behind a runtime switch anyone
    // holding an admin token could flip: `AdditiveRoutes.security` (which edits who may talk
    // to this server) and the FaceTime debug diagnostics. Those stay compiled out.
    groups.append(AdditiveRoutes.security)
    // The richer alert shape. Additive because v1's is frozen at the reference's six
    // keys; this is where the full alert shape becomes reachable.
    groups.append(AdditiveRoutes.alerts)
    // Mounted unconditionally, like the alerts group above. A client asking what this server
    // is entitled to must get an answer whether or not a license exists: the unlicensed
    // answer is the one that lets a client hide a paid feature instead of offering it and
    // then refusing.
    groups.append(AdditiveRoutes.subscription)
    // A second way to get an avatar the contact payload already carries.
    groups.append(AdditiveRoutes.contactAvatar)
    // Pinning: a helper capability the Node server never had a route for.
    groups.append(AdditiveRoutes.chatPinning)
    // Stickers: likewise, a send the Node helper never had an action for.
    groups.append(AdditiveRoutes.stickers)
    // The sticker library. Reads need no helper: the store is a SQLite file.
    groups.append(AdditiveRoutes.stickerLibrary)
    // Send Later: Apple's scheduling, distinct from this server's own timer.
    groups.append(AdditiveRoutes.sendLater)
    // Polls, macOS 26.
    groups.append(AdditiveRoutes.polls)
    // Any iMessage app's balloon, Game Pigeon included.
    groups.append(AdditiveRoutes.appMessages)
    // Editing a webhook, which the Node server only ever exposed to its own UI.
    groups.append(AdditiveRoutes.webhookEditing)
    // Conversation controls: wallpaper today, mute and filtering next.
    groups.append(AdditiveRoutes.chatControls)
    // The shared contact card, with the handle and shared-state v1 cannot carry.
    groups.append(AdditiveRoutes.contactCard)

    // Feature flags, each independently off by default. Unlike v2 as a whole, these are
    // about a capability not being ready to be reachable at all, rather than about which
    // prefix it lives under.
    if features.contains(Features.findMy.id) {
      groups.append(AdditiveRoutes.findMy)

      // Nested rather than parallel: the sharing routes sit under the same prefix and
      // are meaningless without the status route to tell a client whether FindMy works
      // at all. Both flags have to be on.
      //
      // Registers NOTHING in a release build: `findMySharing` is `#if DEBUG` and answers
      // with an empty route list. Kept here so a development build still honours the flag.
      if features.contains(Features.findMyLocationSharing.id) {
        groups.append(AdditiveRoutes.findMySharing)
      }
    }

    // FaceTime, same structure: the incoming-call flow is nested under the enhanced flag
    // because it shares the prefix and is meaningless without the rest.
    // Settings, not feature flags: FaceTime is a capability a user turns on, the same
    // way they turn on the Messages Private API.
    if faceTime {
      groups.append(AdditiveRoutes.faceTime)
      // Nested: the incoming flow shares the prefix and is meaningless without the rest.
      if faceTimeIncoming {
        groups.append(AdditiveRoutes.faceTimeIncoming)
      }
    }

    if authMode != .password {
      groups.append(AdditiveRoutes.auth)
    }
    // Hydration is only meaningful to a client on reference-v2 or sealed-v2. On a
    // legacy-only server nobody can call it, so it does not exist.
    if codecs.serverPreference != .legacyV1 {
      groups.append(AdditiveRoutes.hydration)
    }
    return groups
  }

  static func buildHandlers(
    context: AppContext,
    authMode: AuthMode,
    codecs: CodecNegotiator,
    additionalGroups: [RouteGroup] = [],
    logSink: FileSink? = nil,
    logger: Logger? = nil
  ) async -> HandlerRegistry {
    var registry = HandlerRegistry()

    CoreHandlers.register(into: &registry, context: context)
    LandingHandlers.register(into: &registry, context: context)
    FindMyHandlers.register(into: &registry, context: context)
    FaceTimeHandlers.register(into: &registry, context: context)
    ReadHandlers.register(into: &registry, context: context)
    WriteHandlers.register(into: &registry, context: context)
    AdminHandlers.register(into: &registry, context: context)
    AdminHandlers.registerSubscription(into: &registry, context: context)
    ContactHandlers.register(into: &registry, context: context)
    ScheduleHandlers.register(into: &registry, context: context)
    SystemHandlers.register(into: &registry, context: context, logSink: logSink)
    MediaHandlers.register(into: &registry, context: context)
    StickerHandlers.register(into: &registry, context: context)
    PushHandlers.register(into: &registry, context: context)
    UploadHandlers.register(into: &registry, context: context)
    UpdateHandlers.register(into: &registry, context: context)
    SecurityHandlers.register(into: &registry, context: context)
    if authMode != .password {
      AuthHandlers.register(into: &registry, context: context)
    }
    if codecs.serverPreference != .legacyV1 {
      HydrationHandlers.register(into: &registry, context: context)
    }

    // Everything the interfaces layer has not reached yet is mounted and answers 501.
    //
    // The alternative (letting `buildRouter` refuse to start) would be defensible and
    // useless: the server could not run until all 107 controllers existed. Mounting them
    // with the truthful status keeps the gap measurable instead of hiding it behind a
    // 404 that looks like a missing route.
    let unimplemented = PlaceholderHandlers.fill(
      into: &registry, groups: RouteTable.alwaysMounted + additionalGroups
    )
    if !unimplemented.isEmpty {
      logger?.warning(
        "Endpoints not yet implemented",
        metadata: [
          "handlers": .string(unimplemented.map(\.rawValue).sorted().joined(separator: ",")),
          "count": .stringConvertible(unimplemented.count),
          "of": .stringConvertible(
            RouteTable.groups.flatMap(\.routes).count
              + additionalGroups.flatMap(\.routes).count),
        ])
    }
    return registry
  }
}

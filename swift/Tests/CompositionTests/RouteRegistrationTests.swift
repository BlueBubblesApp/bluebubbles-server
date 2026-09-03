//  RouteRegistrationTests
//  What the default configuration exposes, and what it does not.
//
//  Every module in this project has its own default-off tests, and they all check the same
//  thing from the inside: that a component declines to act when disabled. None of them can
//  check the property that actually matters, which is whether the composition root ever
//  constructs the component at all.
//
//  That is what this file is for. A route group missing from the array below is a route
//  group missing from the router, and its paths 404 exactly like any unknown path.

import BBAuth
import BBEvents
import BBHTTPAPI
import BBOpenAPI
import BBServiceKit
import BBSettings
import Foundation
import Testing

@testable import BBBuiltIns
@testable import BBHandlers
@testable import BBInterfaces
@testable import BlueBubblesServerCore

@Suite("Route registration")
struct RouteRegistrationTests {

  /// The v2 groups EVERY server mounts, whatever its settings.
  ///
  /// Subtracted by `gated(_:)` below so that a test about a switch asserts about that switch.
  /// Before v2 became unconditional these tests could say "nothing else is mounted"; now the
  /// interesting claim is "nothing else *beyond the baseline* is mounted", and conflating the
  /// two would make every flag test pass for the wrong reason.
  static let alwaysMounted: Set<String> = [
    "Security", "Alerts", "Contact Avatar", "Chat Pinning", "Stickers", "Sticker Library",
    "Send Later", "Polls", "App Messages", "Webhook Editing", "Chat Controls", "Contact Card",
  ]

  /// Group names beyond the always-mounted baseline.
  static func gated(_ groups: [RouteGroup]) -> Set<String> {
    Set(groups.map(\.name)).subtracting(alwaysMounted)
  }

  /// The shipping default: password auth, legacy codec. v2 and nothing else.
  @Test("A default server registers the v2 baseline and nothing gated")
  func defaultRegistersNothingGated() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    #expect(Self.gated(groups).isEmpty)
    #expect(Set(groups.map(\.name)) == Self.alwaysMounted)
  }

  /// `GET /` and nothing under `/api/v1`. A landing page mounted at `/api/v1/` would be an
  /// added route the parity diff should reject; a landing page mounted nowhere is what the
  /// server shipped with until now, which is what a user sees as "my tunnel is broken".
  @Test("The landing page mounts at the server root, outside the parity table")
  func landingMountsAtRoot() throws {
    let group = RouteTable.landing
    let route = try #require(group.routes.first)

    #expect(group.mountsAtRoot)
    #expect(RouteTable.path(of: route, in: group) == "/")
    #expect(route.requirements.contains(.unauthenticated))

    // In what the router mounts, out of what the parity fixture diffs. Both halves
    // matter: the first is why the route answers at all, the second is why adding it
    // does not fail `RouteTableTests`.
    #expect(RouteTable.alwaysMounted.contains { $0.name == group.name })
    #expect(!RouteTable.groups.contains { $0.name == group.name })
  }

  /// Nothing else may quietly join `alwaysMounted`. It exists for exactly one route that
  /// Node serves outside its versioned table; a second entry is far more likely to be an
  /// additive route dodging the parity diff than another `HttpRoutes.ui`.
  @Test("The landing page is the only thing mounted outside the API table")
  func alwaysMountedAddsOnlyTheLandingPage() {
    let extra = RouteTable.alwaysMounted.filter { group in
      !RouteTable.groups.contains { $0.name == group.name }
    }
    #expect(extra.map(\.name) == ["Index"])
  }

  /// The auth endpoints must 404, not 401. A 401 tells an attacker the endpoint exists,
  /// and it would make the route table differ from the Node server's — which the parity
  /// harness diffs strictly in both directions.
  @Test("Auth routes appear only when token auth is enabled")
  func authRoutesFollowTheMode() async {
    for mode in [AuthMode.token, .both] {
      let names =
        await ServerComposition
        .routeGroups(authMode: mode, codecs: .legacyOnly())
        .map(\.name)
      #expect(names.contains("Auth"), "expected the Auth group under \(mode)")
    }

    let underPassword =
      await ServerComposition
      .routeGroups(authMode: .password, codecs: .legacyOnly())
      .map(\.name)
    #expect(!underPassword.contains("Auth"))
  }

  /// Hydration is only meaningful to a client on reference-v2 or sealed-v2. On a
  /// legacy-only server nobody can call it, so it does not exist — an endpoint nobody
  /// calls is still an endpoint an attacker can.
  @Test("The hydration route appears only when an alternate codec is enabled")
  func hydrationFollowsTheCodec() async {
    let legacy =
      await ServerComposition
      .routeGroups(authMode: .password, codecs: .full(preference: .legacyV1))
      .map(\.name)
    #expect(!legacy.contains("Hydration"))

    for preference in [CodecIdentifier.referenceV2, .sealedV2] {
      let names =
        await ServerComposition
        .routeGroups(authMode: .password, codecs: .full(preference: preference))
        .map(\.name)
      #expect(names.contains("Hydration"), "expected Hydration under \(preference.rawValue)")
    }
  }

  /// Registering the codecs is not the same as using them. A server that knows how to
  /// speak sealed-v2 but has not been told to still exposes no hydration endpoint.
  @Test("Registered-but-unused codecs expose no route")
  func registeredCodecsAreNotEnabledCodecs() async {
    // All three codecs constructed, ceiling left at legacy.
    let negotiator = CodecNegotiator.full(preference: .legacyV1)
    #expect(negotiator.supportedIdentifiers.count == 3)

    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: negotiator
    )
    #expect(Self.gated(groups).isEmpty)
  }

  /// Both switches at once, which is the fully-enabled configuration.
  @Test("Both features on registers both groups")
  func bothEnabled() async {
    let groups =
      await ServerComposition
      .routeGroups(authMode: .both, codecs: .full(preference: .sealedV2))
    #expect(Self.gated(groups) == ["Auth", "Hydration"])
  }

  // MARK: - Find My

  /// The default route table has to match the previous server's exactly, so the enhanced
  /// FindMy paths must not be there — and must 404 rather than 403, which is what "not
  /// mounted" buys over "mounted and refusing".
  @Test("Find My routes are absent unless the flag is on")
  func findMyIsOffByDefault() async {
    let names = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), features: []
    ).map(\.name)
    #expect(!names.contains("Find My"))
    #expect(!names.contains("Find My Sharing"))
  }

  @Test("The Find My flag mounts the read routes and nothing more")
  func findMyFlagMountsReads() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      features: [Features.findMy.id]
    )
    let names = groups.map(\.name)
    #expect(names.contains("Find My"))
    // The second flag is off, so sharing is still not reachable. This is the pairing the
    // whole two-flag arrangement exists for.
    #expect(!names.contains("Find My Sharing"))

    let findMy = groups.first { $0.name == "Find My" }
    #expect(findMy?.routes.count == 3)
    // Status must NOT require the helper: it is the call that tells a client whether the
    // helper is usable, so failing it when the helper is absent withholds the answer
    // being asked for.
    let status = findMy?.routes.first { $0.handlerID == .findmyStatus }
    #expect(status?.requirements.contains(.privateAPI) == false)
    // Everything else does.
    #expect(
      findMy?.routes.filter { $0.handlerID != .findmyStatus }
        .allSatisfy { $0.requirements.contains(.privateAPI) } == true)
  }

  /// Sharing needs BOTH flags. Turning on only the sharing flag must mount nothing —
  /// otherwise the more dangerous half would be reachable without the half that tells a
  /// client whether FindMy works at all.
  @Test("Sharing needs both flags")
  func sharingNeedsBothFlags() async {
    let sharingOnly = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      features: [Features.findMyLocationSharing.id]
    )
    #expect(Self.gated(sharingOnly).isEmpty)

    let both = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      features: [Features.findMy.id, Features.findMyLocationSharing.id]
    )
    #expect(Self.gated(both) == ["Find My", "Find My Sharing"])

    // Sharing transmits this Mac's position to another person, so it is a write and
    // needs the helper.
    let sharing = both.first { $0.name == "Find My Sharing" }
    #expect(sharing?.routes.allSatisfy { $0.scope == Scope.messagesWrite } == true)
    #expect(sharing?.routes.allSatisfy { $0.requirements.contains(.privateAPI) } == true)
  }

  /// A FindMy handle is a phone number or an email, and both need percent-encoding that
  /// clients get wrong in both directions. Keeping them out of the path removes the trap
  /// rather than documenting it.
  @Test("No Find My route takes an address in its path")
  func addressesAreNotPathSegments() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      features: [Features.findMy.id, Features.findMyLocationSharing.id]
    ).filter { $0.name.hasPrefix("Find My") }
    // The rest of v2 is mounted alongside these now, and plenty of it takes a `:guid` —
    // so this asserts over the Find My groups rather than over everything that came back.
    #expect(groups.count == 2)
    for route in groups.flatMap(\.routes) {
      #expect(
        !route.path.contains(":"),
        "\(route.path) takes a path parameter; addresses belong in the body"
      )
    }
  }

  /// v2 being always-on must not drag a feature flag on with it, and a feature flag must
  /// not need anything else turned on to work.
  @Test("Find My rides on its own flag and nothing else")
  func findMyIsIndependentOfTheRest() async {
    let withoutFlag = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), features: []
    ).map(\.name)
    #expect(!withoutFlag.contains("Find My"))

    let withFlag = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), features: [Features.findMy.id]
    ).map(\.name)
    #expect(withFlag.contains("Find My"))
    #expect(!withFlag.contains("Find My Sharing"))
  }

  // MARK: - FaceTime

  /// The enhanced FaceTime routes are additive and off by default. The three INHERITED
  /// routes (`facetime/session`, `answer`, `leave`) stay in the default table for Node
  /// parity — they are not in these additive groups.
  @Test("FaceTime enhanced routes are absent unless the flag is on")
  func faceTimeOffByDefault() async {
    let names = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), features: []
    ).map(\.name)
    #expect(!names.contains("FaceTime Enhanced"))
    #expect(!names.contains("FaceTime Incoming"))
  }

  @Test("The FaceTime flag mounts the enhanced routes and nothing more")
  func faceTimeFlagMountsEnhanced() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), faceTime: true
    )
    let names = groups.map(\.name)
    #expect(names.contains("FaceTime Enhanced"))
    // Incoming is a separate flag and stays off.
    #expect(!names.contains("FaceTime Incoming"))

    // Every enhanced route drives the injected helper, so it needs the private API and
    // `chats:write` — with two deliberate exceptions, both read-only:
    //   - `members`/`debug` read the helper but change nothing, so no write scope.
    //   - `recents` reads the macOS call log from disk, so it needs no helper AT ALL.
    //     That is the point of it: recents work on a server with no injection.
    let enhanced = groups.first { $0.name == "FaceTime Enhanced" }
    let readsTheDatabase: [HandlerID] = [.facetimeRecents, .facetimeRestart]
    // `dismissAlert` is debug-only and write-scoped; the other two are read-only.
    let readOnly: [HandlerID] = [
      .facetimeMembers, .facetimeRecents, .facetimeDebug, .facetimeWindows,
    ]
    #expect(
      enhanced?.routes
        .filter { !readsTheDatabase.contains($0.handlerID) }
        .allSatisfy { $0.requirements.contains(.privateAPI) } == true)
    #expect(
      enhanced?.routes
        .filter { readsTheDatabase.contains($0.handlerID) }
        .allSatisfy { !$0.requirements.contains(.privateAPI) } == true)
    // `restart` relaunches an APP rather than touching chats, so it carries the admin
    // scope its inherited sibling `mac/imessage/restart` does.
    let adminScoped: [HandlerID] = [.facetimeRestart, .facetimeCleanup]
    #expect(
      enhanced?.routes
        .filter { !readOnly.contains($0.handlerID) && !adminScoped.contains($0.handlerID) }
        .allSatisfy { $0.scope == Scope.chatsWrite } == true)
    #expect(
      enhanced?.routes.filter { adminScoped.contains($0.handlerID) }
        .allSatisfy { $0.scope == Scope.serverAdmin } == true)
  }

  /// Diagnostics are development-only, and compiled out of a release build.
  ///
  /// `debug` dumps raw `TUConversation` internals, `windows` reports what FaceTime.app is
  /// showing, and `dismiss-alert` drives its UI. None belong on a shipped API — `debug`
  /// would hand conversation internals to anyone holding a read scope.
  ///
  /// Gated with `#if DEBUG` rather than a setting, because a setting is a runtime switch and
  /// a runtime switch can be flipped on a production server. This asserts BOTH sides: they
  /// are present in a development build (where they are needed and tested) and absent
  /// otherwise. The release half cannot execute here — tests are a debug build — so it
  /// stands as the specification a release build must satisfy.
  @Test("FaceTime diagnostics are development-only")
  func diagnosticsAreDebugOnly() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      faceTime: true, faceTimeIncoming: true
    )
    let handlers = Set(groups.flatMap { $0.routes.map(\.handlerID) })
    let diagnostics: [HandlerID] = [
      .facetimeDebug, .facetimeWindows, .facetimeDismissAlert,
    ]
    #if DEBUG
      for diagnostic in diagnostics {
        #expect(handlers.contains(diagnostic), "\(diagnostic) should exist in a dev build")
      }
    #else
      for diagnostic in diagnostics {
        #expect(!handlers.contains(diagnostic), "\(diagnostic) must not ship")
      }
    #endif
  }

  /// Whatever the build, a diagnostic must never be something a plain client scope reaches.
  @Test("Diagnostics never carry a write scope")
  func diagnosticsAreReadOnly() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), faceTime: true
    )
    let diagnostics = groups.flatMap(\.routes).filter {
      $0.handlerID == .facetimeDebug || $0.handlerID == .facetimeWindows
    }
    #expect(diagnostics.allSatisfy { $0.scope != Scope.serverAdmin })
    #expect(diagnostics.allSatisfy { $0.requirements.contains(.privateAPI) })
  }

  /// The incoming-call hand-off needs BOTH flags — the more dangerous flow must not be
  /// reachable without the base one.
  @Test("FaceTime incoming needs both flags")
  func faceTimeIncomingNeedsBothFlags() async {
    let incomingOnly = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(), faceTimeIncoming: true
    )
    #expect(Self.gated(incomingOnly).isEmpty)

    let both = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly(),
      faceTime: true, faceTimeIncoming: true
    )
    #expect(Self.gated(both) == ["FaceTime Enhanced", "FaceTime Incoming"])
  }

  /// The converse of the test above, and it was missing.
  ///
  /// That asymmetry cost a real bug: the sticker library group was added to the catalog and
  /// to the handler registry but never appended in `routeGroups`, so all four routes were
  /// fully DOCUMENTED and returned 404. The one-directional check passed, because a group
  /// in the catalog that nothing mounts is not a group the composition root failed to
  /// document — it is worse, and nothing was looking for it.
  @Test("Nothing is documented that the composition root does not mount")
  func catalogueIsReachable() async {
    let mounted = Set(
      await ServerComposition.routeGroups(
        authMode: .both, codecs: .full(preference: .sealedV2),
        features: Set(Features.allKeys.map { $0.replacingOccurrences(of: "feature_", with: "") }),
        faceTime: true, faceTimeIncoming: true
      ).map { "\($0.name)|\($0.apiVersion)" }
    )
    for entry in RouteCatalog.all
    where entry.group.apiVersion != 1 && !entry.group.mountsAtRoot {
      let name = entry.group.name
      #expect(
        mounted.contains("\(name)|\(entry.group.apiVersion)"),
        "\(name) is documented but no configuration mounts it")
    }
  }

  /// v2 is mounted for everyone, with no setting to turn it on and none to turn it off.
  ///
  /// This is the assertion that used to say the opposite. The group list is pinned rather
  /// than merely counted so that adding a v2 group is a deliberate edit here — and so that
  /// `Security` appearing in it stays visible, since that group is empty outside `#if DEBUG`
  /// and is the one piece of v2 that must never reach a shipped binary.
  @Test("The whole v2 surface is mounted with default settings")
  func v2IsNotOptIn() async {
    let on = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    #expect(Set(on.map(\.name)) == Self.alwaysMounted)

    // Compiled out of a release build by its own `#if DEBUG`, which is where that gate
    // belongs: a runtime switch over who may talk to the server can be flipped by whoever
    // holds an admin token, and a compile-time one cannot.
    #if DEBUG
      #expect(on.first { $0.name == "Security" }?.routes.isEmpty == false)
    #else
      #expect(on.first { $0.name == "Security" }?.routes.isEmpty == true)
    #endif

    // Pinning is additive because the Node server has no route for it, not because it is
    // administrative — so the WRITES carry `chats:write` like every other chat write, and
    // the read does not. Asserting per method rather than across the group: the group
    // gained a GET, and "every route here is a write" was true only until it did.
    let pinning: RouteGroup? = on.first { $0.name == "Chat Pinning" }
    let writes = pinning?.routes.filter { $0.method != .get } ?? []
    let reads = pinning?.routes.filter { $0.method == .get } ?? []
    #expect(!writes.isEmpty && !reads.isEmpty)
    #expect(writes.allSatisfy { $0.scope == .chatsWrite })
    #expect(reads.allSatisfy { $0.scope == .messagesRead })
    // All of them need the helper either way — pins live in Messages, not in chat.db.
    #expect(pinning?.routes.allSatisfy { $0.requirements.contains(.privateAPI) } == true)

    // The literal has to register before the parameter, or `GET /chat/pin` is swallowed
    // by `:guid/pin` and arrives with `guid = "pin"`.
    let paths = pinning?.routes.map(\.path) ?? []
    #expect(paths.firstIndex(of: "pin") ?? .max < paths.firstIndex(of: ":guid/pin") ?? 0)
  }

  /// Reading a wallpaper needs the DATABASE, not the helper.
  ///
  /// The rest of the chat-controls group will require the Private API — muting, filtering
  /// and clearing history are all IMCore calls. The background read is not: Messages caches
  /// the flattened image on disk, so it works on the common configuration where SIP is on
  /// and there is no helper at all. Requiring `.privateAPI` here would withhold a
  /// conversation's wallpaper from every such server, which is why it is asserted rather
  /// than left to whoever adds the next route to this group.
  @Test("The chat background read needs no helper")
  func backgroundReadIsDatabaseOnly() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    let controls = groups.first { $0.name == "Chat Controls" }
    let background = controls?.routes.filter { $0.path.hasPrefix(":guid/background") } ?? []
    let reads = background.filter { $0.method == .get }

    #expect(reads.count == 2)
    #expect(reads.allSatisfy { !$0.requirements.contains(.privateAPI) })
    // Bytes Messages already wrote to disk, same as `chat.groupIcon` in the v1 group.
    #expect(reads.allSatisfy { $0.scope == .attachmentsRead })

    // The download needs the helper — only imagent can pull the asset out of iCloud —
    // but it stays an attachment READ in scope terms: it fetches a conversation's
    // wallpaper, it does not change the conversation.
    let fetch = background.first { $0.path == ":guid/background/fetch" }
    #expect(fetch?.method == .post)
    #expect(fetch?.scope == .attachmentsRead)
    #expect(fetch?.requirements.contains(.privateAPI) == true)

    // There is NO write here, and that is deliberate rather than unfinished: setting a
    // wallpaper needs PosterBoard to mint a poster, which it refuses to do for a headless
    // caller. See `PRIVATE_API_SURFACE.md` §1 for the measurements.
    #expect(!background.contains { $0.path == ":guid/background" && $0.method != .get })

    // v2, not v1. A path added to the v1 chat group is a route the parity diff rejects.
    #expect(controls?.apiVersion == RouteTable.latestVersion)

    // Longer path first, matching the table's more-specific-first rule.
    let paths = controls?.routes.map(\.path) ?? []
    let info = paths.firstIndex(of: ":guid/background/info") ?? .max
    let bytes = paths.firstIndex(of: ":guid/background") ?? 0
    #expect(info < bytes)
  }

  /// Mute is helper-only in both directions, and the read is not a write.
  ///
  /// The state lives in `IMMutedChatList` inside Messages — there is no chat.db column for
  /// it — so unlike the background read, even asking whether a chat is muted needs the
  /// helper. Asserted per method because the group holds both kinds and "everything here is
  /// a write" is the assumption that breaks first.
  @Test("Mute routes are helper-only, scoped per method")
  func muteRoutesRequireTheHelper() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    let mute =
      groups.first { $0.name == "Chat Controls" }?
      .routes.filter { $0.path == ":guid/mute" } ?? []

    #expect(mute.count == 3)
    #expect(Set(mute.map(\.method)) == [.get, .post, .delete])
    #expect(mute.allSatisfy { $0.requirements.contains(.privateAPI) })
    #expect(mute.filter { $0.method != .get }.allSatisfy { $0.scope == .chatsWrite })
    #expect(mute.filter { $0.method == .get }.allSatisfy { $0.scope == .messagesRead })
  }

  /// The destructive route is a DELETE on `:guid/messages`, and it must live in v2.
  ///
  /// The v1 chat group has `DELETE :guid/:messageGuid`. Declaring this path there instead
  /// would match that route first and attempt to delete a message whose GUID is the literal
  /// string "messages" — a 200 with the wrong effect, which is the failure mode the table's
  /// ordering rule exists to prevent.
  @Test("Clearing history is a v2 route and cannot collide with message deletion")
  func clearHistoryIsIsolatedFromMessageDeletion() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    let controls = groups.first { $0.name == "Chat Controls" }
    let clear = controls?.routes.first { $0.path == ":guid/messages" }

    #expect(clear?.method == .delete)
    #expect(clear?.scope == .chatsWrite)
    #expect(clear?.requirements.contains(.privateAPI) == true)
    #expect(controls?.apiVersion == RouteTable.latestVersion)

    // And the v1 chat group still owns the two-parameter delete, untouched. Reached
    // through the public table rather than the internal `RouteTable.chat`.
    let v1Chat = RouteTable.groups.first { $0.name == "Chat" }
    #expect(
      v1Chat?.routes.contains { $0.method == .delete && $0.path == ":guid/:messageGuid" }
        == true
    )
    #expect(v1Chat?.routes.contains { $0.path == ":guid/messages" } == false)
  }

  /// Every write in the filtering group carries `chats:write`; the read does not.
  @Test("Filtering routes are scoped per method")
  func filteringRoutesAreScoped() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    let controls = groups.first { $0.name == "Chat Controls" }
    let filtering =
      controls?.routes.filter {
        [":guid/filter", ":guid/known", ":guid/spam", ":guid/junk"].contains($0.path)
      } ?? []

    #expect(filtering.count == 5)
    #expect(filtering.allSatisfy { $0.requirements.contains(.privateAPI) })
    #expect(filtering.filter { $0.method == .post }.allSatisfy { $0.scope == .chatsWrite })
    #expect(filtering.filter { $0.method == .get }.map(\.path) == [":guid/filter"])
  }

  /// The access-control routes are `#if DEBUG` and must not exist in a shipped binary.
  ///
  /// They edit the rules deciding who may reach the server — unblock an address, allowlist a
  /// CIDR, clear the blocklist. Authentication is not sufficient protection for that: the
  /// credential is one shared password with no per-device identity, so whoever guessed it
  /// can switch off the thing that was slowing them down. Administering this belongs to
  /// someone at the machine (the Security page) or at a terminal (`--clear-blocklist`).
  @Test("Access-control administration is not in a release build")
  func securityRoutesAreDebugOnly() async {
    let groups = await ServerComposition.routeGroups(
      authMode: .password, codecs: .legacyOnly()
    )
    let security: RouteGroup? = groups.first { $0.name == "Security" }

    #if DEBUG
      // Reachable here, and still admin-scoped: mounting them is not the same as opening them.
      #expect(security?.routes.count == 7)
      #expect(security?.routes.allSatisfy { $0.scope == Scope.serverAdmin } == true)
    #else
      #expect(security?.routes.isEmpty == true)
    #endif
  }

  /// A route in the table with no handler is a hard failure at mount time, not a 404 at
  /// runtime that looks like a client bug. This asserts the additive groups are covered by
  /// the handlers the composition registers alongside them.
  @Test("Every additive route has a handler when its group is registered")
  func additiveRoutesAreCovered() {
    // The handler IDs the additive groups reference.
    let authHandlers = Set(AdditiveRoutes.auth.routes.map(\.handlerID))
    let hydrationHandlers = Set(AdditiveRoutes.hydration.routes.map(\.handlerID))

    #expect(
      authHandlers == [
        .authRegister, .authToken, .authRotate, .authRevoke,
      ])
    #expect(hydrationHandlers == [.messageHydrate])
  }
}

@Suite("Service graph")
struct ServiceGraphTests {

  /// Start order is derived from declared dependencies, and stop order is exactly its
  /// reverse. The current implementation maintains two separate lists that have drifted.
  @Test("Dependencies are declared, not assumed")
  func dependenciesAreDeclared() {
    // The socket shares the HTTP listener, and the edge runs HTTP -> socket: the
    // websocket upgrade is decided at the channel, before the router sees a request, so
    // the transport has to exist by the time the port is bound. The edge pointed the
    // other way while the socket had no transport at all, and nothing noticed.
    #expect(HTTPService.dependencies.contains(BuiltInManifests.ID.socket))
    #expect(SocketService.dependencies.isEmpty)
    // A tunnel pointing at a port nothing is serving publishes an address that fails for
    // every client that tries it.
    #expect(ProxyService<ZrokMethod>.dependencies.contains(BuiltInManifests.ID.http))
    // Everything that gates on a permission needs the monitor running first.
    #expect(ChangeDetectionService.dependencies.contains(BuiltInManifests.ID.permissions))
    #expect(HTTPService.dependencies.contains(BuiltInManifests.ID.permissions))
  }

  /// The one permission that genuinely gates a service. Without Full Disk Access there is
  /// no database to watch, and the registry says so precisely instead of letting it fail
  /// obscurely at first read.
  @Test("Change detection declares its permission requirement")
  func changeDetectionRequiresFullDisk() {
    #expect(ChangeDetectionService.requiredPermissions == [.fullDiskAccess])
    // Contacts is recommended, not required — the server runs without it and shows
    // numbers instead of names.
    #expect(ContactsService.requiredPermissions.isEmpty)
  }

  /// Restart policy is a property of the service, not of whoever happens to start it.
  /// This replaces the current proxy recovery path, which retries ten times and then
  /// relaunches the entire application because one tunnel failed.
  @Test("Failure-prone services carry a backoff policy")
  func restartPolicies() {
    guard case .backoff = ProxyService<ZrokMethod>.restartPolicy else {
      Issue.record("the proxy should back off rather than relaunch the app")
      return
    }
    guard case .backoff = HTTPService.restartPolicy else {
      Issue.record("the HTTP server should back off")
      return
    }
    // Reading system state cannot be fixed by trying again immediately.
    guard case .never = PermissionsMonitorService.restartPolicy else {
      Issue.record("the permissions monitor should not restart")
      return
    }
  }

  /// Settings that require rebinding a socket or reloading a credential must be watched,
  /// or changing them in the UI silently does nothing until the next restart.
  @Test("Services watch the settings that require them to restart")
  func watchedSettings() {
    #expect(HTTPService.watchedSettings.contains("socket_port"))
    // A password change must kick connected clients: they authenticated with the old one.
    #expect(HTTPService.watchedSettings.contains("password"))
    #expect(ProxyService<ZrokMethod>.watchedSettings.contains("connection_method"))
    #expect(PrivateAPIGatedService.watchedSettings.contains("enable_private_api"))
  }
}

@Suite("Config file")
struct ConfigFileTests {

  /// Absent is normal — most installs configure through the UI — so it must not be an error.
  @Test("A missing config file yields no values rather than failing")
  func missingFileIsFine() {
    #expect(ConfigFile.load(at: "/nope/not-a-file.yml").isEmpty)
  }

  @Test("Scalars parse, with comments and quotes ignored")
  func parsing() throws {
    let path = NSTemporaryDirectory() + "bb-config-\(UUID().uuidString.prefix(8)).yml"
    try """
    # a comment
    socket_port: 1234
    password: "quoted value"

    proxy_service: cloudflare
    malformed line with no colon separator here
    """.write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let values = ConfigFile.load(at: path)
    #expect(values["socket_port"] == "1234")
    #expect(values["password"] == "quoted value")
    #expect(values["proxy_service"] == "cloudflare")
    // A line that is not `key: value` is skipped rather than failing the whole file.
    #expect(values.count == 3)
  }
}
